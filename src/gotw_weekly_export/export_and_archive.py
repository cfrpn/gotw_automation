# Databricks notebook source
import ast
from datetime import datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import gspread
from google.oauth2.service_account import Credentials

# COMMAND ----------

# Same period as ruby_sweeps._logs.lems_gotw_ongoing_leaderboard's view and
# lems2.0/server.js's getCurrentPeriod() -- see AGENTS.md: Monday 15:00 to the
# following Monday 15:00 New Zealand local time, fixed year-round (changed
# 2026-11-11 from a fixed-UTC 2026-08-03T02:00 + 7-day window). That's 02:00
# UTC under NZDT, 03:00 UTC under NZST. This job is scheduled for 15:05 NZ
# local on Mondays, so by the time it runs the live view has already rolled
# over to the *new* week. To archive the week that just concluded, this
# queries the underlying tables directly for the previous period rather than
# reading the (already-rolled-over) view.
GOTW_TZ = ZoneInfo("Pacific/Auckland")
GOTW_BOUNDARY = time(15, 0)  # Monday 15:00 NZ local
FINAL_SIX = timedelta(hours=6)

def _nz_boundary(day):
    return datetime.combine(day, GOTW_BOUNDARY, GOTW_TZ)

def last_completed_period(now):
    local = now.astimezone(GOTW_TZ)
    monday = local.date() - timedelta(days=local.weekday())
    current_start = _nz_boundary(monday)
    if current_start > now:  # Monday before 15:00 NZ: still last week's period
        current_start = _nz_boundary(monday - timedelta(days=7))
    previous_start = _nz_boundary(current_start.date() - timedelta(days=7))
    # Return UTC: the SQL literals below are interpreted in the session
    # timezone (UTC), and the tab label keeps its historical UTC dates.
    return previous_start.astimezone(timezone.utc), current_start.astimezone(timezone.utc)

period_start, period_end = last_completed_period(datetime.now(timezone.utc))
final_six_start = period_end - FINAL_SIX
week_label = f"{period_start:%Y-%m-%d}_to_{period_end:%Y-%m-%d}"

# COMMAND ----------

# Mirrors the scoring logic in ruby_sweeps._logs.lems_gotw_ongoing_leaderboard
# (src/gotw_view_template.sql) for a fixed, already-concluded window instead of
# "current". Keep the filter/scoring logic in sync with that view by hand, or
# the archive will silently disagree with what the live leaderboard actually
# showed that week. Includes the same rn tiebreak (u.user_id as secondary
# sort) added to the view on 2026-08-25 -- keeps ties deterministic.
#
# "Final Six" 2x points rule (permanent as of 2026-08-21, per Nina): the last
# 6 hours of every period are worth double points. Started as a one-off promo
# for the 2026-08-17 boundary only (see
# ../../promotions/2026-08-17_weekly_showdown_2x.sql), then made a standing
# recurring rule -- derived from final_six_start/period_end above, so it
# applies to every future week with no per-week edits needed.
pdf = spark.sql(f"""
    WITH filtered_bets AS (
        SELECT
            user_id,
            CASE
                WHEN created_at >= TIMESTAMP'{final_six_start:%Y-%m-%d %H:%M:%S}'
                 AND created_at <  TIMESTAMP'{period_end:%Y-%m-%d %H:%M:%S}'
                THEN bet_amount * 2
                ELSE bet_amount
            END AS bet_amount
        FROM ruby_sweeps.bronze.bets
        WHERE created_at >= TIMESTAMP'{period_start:%Y-%m-%d %H:%M:%S}'
          AND created_at < TIMESTAMP'{period_end:%Y-%m-%d %H:%M:%S}'
          AND currency = 'SWEEP_TICKETS'
    ),
    verified_users AS (
        SELECT user_id, email, nickname
        FROM ruby_sweeps.bronze.users
        WHERE sumsub_purchase_verified = 'true'
          AND nickname IS NOT NULL
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY FLOOR(SUM(b.bet_amount) / 500) DESC, u.user_id ASC) AS rn,
        u.user_id, u.email, u.nickname,
        FLOOR(SUM(b.bet_amount) / 500) AS score
    FROM verified_users u
    INNER JOIN filtered_bets b USING (user_id)
    GROUP BY u.user_id, u.email, u.nickname
    ORDER BY score DESC
""").toPandas()

print(f"Exporting {len(pdf)} rows for the period {week_label} (just concluded)")

# COMMAND ----------

# Reuses the org's existing Sheets service account (already used by other
# reporting notebooks, e.g. "Bingo Addict weekly report") instead of
# provisioning a new GCP service account for GOTW. Stored as a Python dict
# literal, not JSON -- literal_eval, not json.loads.
sa_info = ast.literal_eval(dbutils.secrets.get("google-cloud", "service-account-creds"))
creds = Credentials.from_service_account_info(
    sa_info, scopes=["https://www.googleapis.com/auth/spreadsheets"]
)
gc = gspread.authorize(creds)

# GOTW weekly leaderboard archive -- shared with the service account above.
SHEET_ID = "13VmFv9ZthCAVzblg0J1Vi5UalgLimme_t7c60h9uAdY"

sh = gc.open_by_key(SHEET_ID)
ws = sh.add_worksheet(title=week_label, rows=len(pdf) + 10, cols=len(pdf.columns) + 2)
ws.update([pdf.columns.tolist()] + pdf.astype(str).values.tolist())

print(f"Wrote {len(pdf)} rows to tab '{week_label}'")
print(f"https://docs.google.com/spreadsheets/d/{SHEET_ID}#gid={ws.id}")
