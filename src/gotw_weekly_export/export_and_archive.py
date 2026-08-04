# Databricks notebook source
import ast
from datetime import datetime, timedelta, timezone

import gspread
from google.oauth2.service_account import Credentials

# COMMAND ----------

# Same anchor as ruby_sweeps._logs.lems_gotw_ongoing_leaderboard's view and
# lems2.0/server.js's getCurrentPeriod() -- see AGENTS.md. This job is
# scheduled for shortly after a period boundary (Monday, NZT), so by the time
# it runs the live view has already rolled over to the *new* week. To archive
# the week that just concluded, this queries the underlying tables directly
# for the previous period rather than reading the (already-rolled-over) view.
GOTW_EPOCH_START = datetime(2026, 8, 3, 2, 0, 0, tzinfo=timezone.utc)
GOTW_PERIOD = timedelta(days=7)

def last_completed_period(now):
    weeks_elapsed = (now - GOTW_EPOCH_START) // GOTW_PERIOD
    current_start = GOTW_EPOCH_START + weeks_elapsed * GOTW_PERIOD
    return current_start - GOTW_PERIOD, current_start

period_start, period_end = last_completed_period(datetime.now(timezone.utc))
week_label = f"{period_start:%Y-%m-%d}_to_{period_end:%Y-%m-%d}"

# COMMAND ----------

# Mirrors the scoring logic in ruby_sweeps._logs.lems_gotw_ongoing_leaderboard
# (src/gotw_view_template.sql) for a fixed, already-concluded window instead of
# "current". Keep the filter/scoring logic in sync with that view by hand.
pdf = spark.sql(f"""
    WITH filtered_bets AS (
        SELECT user_id, bet_amount
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
        ROW_NUMBER() OVER (ORDER BY FLOOR(SUM(b.bet_amount) / 500) DESC) AS rn,
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
