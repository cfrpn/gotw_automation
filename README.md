# gotw_automation

Automation for the weekly GOTW (Game of the Week) leaderboard rollover and
archiving. Originally scoped (see design doc below) as two chained Databricks
Jobs plus a Railway API integration to push new start/end times every week.

**That's no longer necessary.** Both `ruby_sweeps._logs.lems_gotw_ongoing_leaderboard`
(the Databricks view) and `lems2.0/server.js` (the Railway-hosted
frontend/API) independently compute the current period, so the leaderboard
window rolls over automatically with no weekly deploy and no Railway API
credentials. Since 2026-11-11 the period runs **Monday 15:00 to Monday 15:00
New Zealand local time, fixed year-round** (02:00 UTC under NZDT, 03:00 UTC
under NZST). Before that it was a fixed 02:00 UTC Monday boundary anchored at
`2026-08-03T02:00:00 UTC`. See `AGENTS.md` for the exact rule (kept identical
on all sides).

What's left is much smaller than the original design: a single Databricks Job
that archives the just-concluded week's leaderboard to Google Sheets, for
record-keeping. It's read-only and non-destructive, so it needs no human
review step. It runs Monday 15:05 NZ local time, 5 minutes after the period
boundary; because both are in NZ local time the margin stays constant across
daylight saving. Don't shrink it without checking Databricks' trigger jitter.
The job queries the underlying bets/users tables directly for that
just-concluded window rather than reading the live view, since by run time
the view has already rolled over to the new week.

Design doc (background/history; the Railway/control-table/review-gate parts
are superseded by the above): [GOTW Weekly Automation Design](https://docs.google.com/document/d/1zeJvdvnk9XJ5lrsUqyprPD7TvjeBUpekmw0B5GWixFk)

## "Final Six" 2x points rule

Permanent as of 2026-08-21 (per Nina): the last 6 hours of every 7-day period
are worth double points. It started as a one-off promo for the 2026-08-17
boundary only (`promotions/2026-08-17_weekly_showdown_2x.sql`), then became a
standing rule applied every week until Nina says otherwise. Both
`src/gotw_view_template.sql` and `export_and_archive.py` derive the window
from `period_end`, so it needs no per-week edits -- unlike the one-off promo,
there's nothing to remember to revert.

Because `period_end` is Monday 15:00 NZ local time (since 2026-11-11), Final
Six is always Monday 09:00-15:00 NZ local time year-round; its US Central
time shifts with both countries' daylight saving.

## Layout

* `src/gotw_weekly_export/export_and_archive.py` -- the single task behind `gotw_weekly_export` (scheduled Monday 15:05 NZ local time): compute the just-concluded period, query it directly, write it to a new Google Sheet tab.
* `src/gotw_view_template.sql` -- reference copy of the production view (for history/documentation only; not read by any job).
* `resources/gotw_jobs.yml` -- the job definition.

## Prerequisites

All done:

1. Databricks CLI authenticated.
2. Google Sheets credential: reuses the org's existing `google-cloud` / `service-account-creds` secret (already used by other reporting notebooks). The target sheet (`13VmFv9ZthCAVzblg0J1Vi5UalgLimme_t7c60h9uAdY`) is already shared with that service account.
3. ~~Railway API token~~ -- not needed anymore.

No new secret scope is required for this project.

## Deploy

```
databricks bundle validate --strict
databricks bundle deploy --target dev   # schedule stays paused in dev mode
databricks bundle deploy --target prod  # activates the real Monday 15:05 NZ schedule
```

## If the leaderboard window logic ever needs to change

All three must be updated together and compute the identical boundary, or
the SQL view, the frontend countdown, and the archive will disagree about
what "this week" means:

* `ruby_sweeps._logs.lems_gotw_ongoing_leaderboard` -- `CREATE OR REPLACE VIEW`, see `src/gotw_view_template.sql`.
* `lems2.0/server.js` -- `getCurrentPeriod()` (`GOTW_TZ`, `GOTW_BOUNDARY_HOUR`).
* `src/gotw_weekly_export/export_and_archive.py` -- `last_completed_period()`, plus the job schedule in `resources/gotw_jobs.yml` / `databricks.yml`.

Before replacing the production view, query both the current view output
and the new formula's output side by side (row count / sum / max score) to
confirm they match -- that's what caught the Monday-vs-Tuesday discrepancy
during the original cutover.
