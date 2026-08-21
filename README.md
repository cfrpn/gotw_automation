# gotw_automation

Automation for the weekly GOTW (Game of the Week) leaderboard rollover and
archiving. Originally scoped (see design doc below) as two chained Databricks
Jobs plus a Railway API integration to push new start/end times every week.

**That's no longer necessary.** As of 2026-08-05, both
`ruby_sweeps._logs.lems_gotw_ongoing_leaderboard` (the Databricks view) and
`lems2.0/server.js` (the Railway-hosted frontend/API) independently compute
the current 7-day period from the same fixed anchor
(`2026-08-03T02:00:00 UTC`). The leaderboard window now rolls over
automatically, forever, with no weekly deploy, no Railway variable updates,
and no Railway API credentials needed at all. See `AGENTS.md` for the exact
formula (kept identical on both sides).

What's left is much smaller than the original design: a single Databricks Job
that archives the just-concluded week's leaderboard to Google Sheets, for
record-keeping. It's read-only and non-destructive, so it needs no human
review step. It runs Monday 16:00 NZT, safely after the period boundary in
both NZ daylight-saving states (the boundary is a fixed 02:00 UTC Monday,
which lands at 14:00 NZT under NZST but 15:00 NZT under NZDT -- an earlier
draft used 15:00 NZT, which collapses to zero margin during NZDT, so don't
move this earlier without re-checking both states) -- and queries the
underlying bets/users tables directly for that just-concluded window rather
than reading the live view, since by run time the view has already rolled
over to the new week.

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

Because `period_end` is a fixed UTC instant, the window is fixed in UTC, not
NZT: 8am-2pm NZT under NZST, shifting to 9am-3pm NZT once NZDT starts (same
DST consideration as the archive job schedule above).

## Layout

* `src/gotw_weekly_export/export_and_archive.py` -- the single task behind `gotw_weekly_export` (scheduled Monday 16:00 Pacific/Auckland): compute the just-concluded period, query it directly, write it to a new Google Sheet tab.
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
databricks bundle deploy --target prod  # activates the real Tuesday schedule
```

## If the leaderboard window logic ever needs to change

Both sides must be updated together and stay byte-identical on the anchor
timestamp, or the SQL view and the frontend countdown will disagree about
what "this week" means:

* `ruby_sweeps._logs.lems_gotw_ongoing_leaderboard` -- `CREATE OR REPLACE VIEW`, see `src/gotw_view_template.sql`.
* `lems2.0/server.js` -- `getCurrentPeriod()` and `GOTW_EPOCH_START`.

When changing the anchor or period length, first query both the current view
output and the new formula's output side by side (row count / sum / max score)
to confirm they match before replacing the production view -- that's what
caught the Monday-vs-Tuesday discrepancy during the original cutover.
