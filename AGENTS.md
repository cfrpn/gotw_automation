# Declarative Automation Bundles Project

This project uses Declarative Automation Bundles (DABs) for deployment. Add project-specific instructions below.

## For AI Agents: Use Databricks AI Tools

**BEFORE any other action, read the `databricks-core` skill.**

It sets you up to work with this project reliably: CLI authentication, profile
selection, data discovery, and the bundle deployment workflow. Without it,
results are often slower and less accurate.

If this skill is not available (Databricks AI Tools are not installed), you can install them for your coding agent in seconds:

```bash
databricks aitools install
```

If the CLI is not installed, see: https://docs.databricks.com/dev-tools/cli/install

---

## Project Instructions

GOTW weekly leaderboard rollover + archiving. Background/history is the design
doc linked in README.md, but its core mechanism (Job A generates a SQL/Railway
variable draft, a human reviews it, Job B applies it via the Railway API) is
superseded: the leaderboard window is now self-computing, not
generated-and-applied. Read README.md's "That's no longer necessary" section
before assuming the doc's Job A/B/control-table architecture is what's
deployed -- it isn't.

**The one invariant that matters most**: `ruby_sweeps._logs.lems_gotw_ongoing_leaderboard`
(Databricks view), `lems2.0/server.js`'s `getCurrentPeriod()`, and
`export_and_archive.py`'s `last_completed_period()` must always compute the
identical period: **Monday 15:00 to the following Monday 15:00, New Zealand
local time (`Pacific/Auckland`), fixed year-round** (decided 2026-11-11 --
"keep NZ time 3pm"). It is NOT a fixed UTC instant: 02:00 UTC under NZDT,
03:00 UTC under NZST, and the weeks containing an NZ DST change are 169h
(April) / 167h (September). The US-facing time therefore moves (8pm CST,
9pm CDT, 10pm CDT depending on both countries' DST), so player-facing copy
written in CT needs updating when DST changes. Final Six is always the last
6 hours before `period_end` (Monday 09:00-15:00 NZ).

These are independent implementations with no shared code and no runtime
coordination -- if one changes without the others, the displayed countdown,
the live leaderboard window, and the archive silently disagree. If you
change the boundary, change all three, and verify with a side-by-side query
(old view's row count/sum/max score vs. the new formula's) before replacing
the production view. From 2026-08-05 to 2026-11-11 the period was a fixed
`2026-08-03T02:00:00 UTC` + n x 7 days window; under NZDT that is identical
to the NZ-local formula, which is what made each cutover zero-disruption.

**Re-grant after replacing the production view.** `CREATE OR REPLACE VIEW`
drops grants made directly on the view. The live leaderboard (lems2.0 on
Railway) queries it as the service principal **Ruby Loyalty Features**
(`c1ca55d1-a2b9-487a-a45c-73e1d0238dc4`), which has only a direct SELECT on
the view -- not inherited from the catalog/schema. Replacing the view on
2026-11-11 without re-granting took `/leaderboard` down (HTTP 500,
INSUFFICIENT_PERMISSIONS) for ~15 minutes. Before replacing, record
`databricks grants get table ruby_sweeps._logs.lems_gotw_ongoing_leaderboard`;
right after, re-apply it:

    GRANT SELECT ON TABLE ruby_sweeps._logs.lems_gotw_ongoing_leaderboard
      TO `c1ca55d1-a2b9-487a-a45c-73e1d0238dc4`;

This project's only remaining job (`gotw_weekly_export`) is an archive with
no review gate: it appends the concluded week to a Google Sheet tab and, since
2026-11-16, also writes it to the Delta table
`manual.temporary.weekly_showdown_leaderboard_history` (one row per player per
week, no email, idempotent per `period_start` via `replaceWhere`). No review
gate is appropriate because it can't affect production data or the live
leaderboard, unlike the doc's original Job B. Both outputs come from the same
`leaderboard_df`, so the Delta table's scoring must stay in sync with the view
exactly like the Sheet's does. It
runs Monday 15:20 NZ local time, after the period boundary has already rolled the live
view to the new week, so `export_and_archive.py` re-implements the same
bets/users join and scoring formula for a fixed, already-concluded window
instead of reading the (already-rolled-over) view. If the view's filter or
scoring logic changes, update this job's inline SQL to match, or the archive
and the live leaderboard will silently disagree.

The schedule is anchored in NZ local time (15:20 `Pacific/Auckland`, 20
minutes after the 15:00 NZ boundary) because the boundary itself is in NZ
local time -- the two move together across DST, so the margin is constant.
It was 15:05 until 2026-11-16, when Nina decided the archive must include
every bet in the week: bets reach `bronze.bets` about 10 minutes after
they're placed, so a 5-minute margin dropped late Final Six bets (double
points) and could change prize places. The script also waits until bets
placed after `period_end` have landed before writing anything (polls for up
to 40 minutes, then fails and emails Nina rather than archive an incomplete
week). Marketing pays prizes from the Sheet, so they pay after this has run.
Never schedule it before the boundary: `last_completed_period()` would
silently archive the wrong (one-week-stale) period.
