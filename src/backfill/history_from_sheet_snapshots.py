# Databricks notebook source
# One-off (2026-11-16): reload manual.temporary.weekly_showdown_leaderboard_history
# for 2026-08-03..2026-11-09 from the weekly Google Sheet snapshots.
#
# Why: the 2026-11-15 backfill recomputed those weeks from bronze.bets as of
# that day. Bets that settled late changed some scores after the fact, so the
# recompute did not always match the leaderboard players saw (and that prizes
# were paid from) -- e.g. ranks 6-8 for the week ending 2026-10-19. The Sheet
# tab written by gotw_weekly_export at period close is the as-of record.
#
# Read-only on the Sheet (readonly scope). Email column is dropped on read.
# The recomputed version is kept in ..._recomputed_20261115 for comparison.
import ast
import re
from datetime import datetime, timezone

import gspread
from google.oauth2.service_account import Credentials
from pyspark.sql import functions as F

HISTORY_TABLE = "manual.temporary.weekly_showdown_leaderboard_history"
BACKUP_TABLE = "manual.temporary.weekly_showdown_leaderboard_history_recomputed_20261115"
SHEET_ID = "13VmFv9ZthCAVzblg0J1Vi5UalgLimme_t7c60h9uAdY"
LAST_PERIOD_END = "2026-11-09"  # periods after this are written by the job itself

# COMMAND ----------

if not spark.catalog.tableExists(BACKUP_TABLE):
    spark.sql(f"CREATE TABLE {BACKUP_TABLE} AS SELECT * FROM {HISTORY_TABLE}")
print("backup rows:", spark.table(BACKUP_TABLE).count())

# COMMAND ----------

sa_info = ast.literal_eval(dbutils.secrets.get("google-cloud", "service-account-creds"))
creds = Credentials.from_service_account_info(
    sa_info, scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"]
)
sh = gspread.authorize(creds).open_by_key(SHEET_ID)

TAB = re.compile(r"^(\d{4}-\d{2}-\d{2})_to_(\d{4}-\d{2}-\d{2})$")
summary = []
for ws in sh.worksheets():
    m = TAB.match(ws.title)
    if not m or m.group(2) > LAST_PERIOD_END:
        continue
    values = ws.get_all_values()
    header = values[0]
    missing = {"rn", "user_id", "nickname", "score"} - set(header)
    if missing:
        raise ValueError(f"{ws.title}: missing columns {missing}; header={header}")
    idx = {c: header.index(c) for c in ("rn", "user_id", "nickname", "score")}
    rows = [
        (int(r[idx["rn"]]), r[idx["user_id"]], r[idx["nickname"]], int(float(r[idx["score"]])))
        for r in values[1:]
        if len(r) > idx["rn"] and r[idx["rn"]].strip()
    ]
    # Pre-2026-11-11 periods were a fixed 02:00 UTC Monday boundary.
    p_start = f"{m.group(1)} 02:00:00"
    p_end = f"{m.group(2)} 02:00:00"
    df = (
        spark.createDataFrame(rows, "rn INT, user_id STRING, nickname STRING, score BIGINT")
        .select(
            F.to_timestamp(F.lit(p_start)).alias("period_start"),
            F.to_timestamp(F.lit(p_end)).alias("period_end"),
            "rn", "user_id", "nickname", "score",
            F.current_timestamp().alias("loaded_at"),
        )
    )
    (df.write.format("delta").mode("overwrite")
        .option("replaceWhere", f"period_start = TIMESTAMP'{p_start}'")
        .saveAsTable(HISTORY_TABLE))
    summary.append((ws.title, len(rows), max(r[3] for r in rows)))
    print(ws.title, len(rows))

assert len(summary) == 14, f"expected 14 weeks, got {len(summary)}"
spark.sql(f"""
    COMMENT ON TABLE {HISTORY_TABLE} IS
    'Weekly Showdown (formerly GOTW) final leaderboard per concluded period. 2026-08-03..2026-11-09 loaded 2026-11-16 from the as-of Google Sheet snapshots (the earlier bets recompute is in {BACKUP_TABLE}); later weeks written by job gotw-weekly-export.'
""")
dbutils.notebook.exit(str(summary))
