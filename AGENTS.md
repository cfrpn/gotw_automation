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
(Databricks view) and `lems2.0/server.js`'s `getCurrentPeriod()` must always
compute the identical rolling window from the identical anchor
(`2026-08-03T02:00:00 UTC`, 7-day period). They're two independent
implementations of the same formula with no shared code and no coordination
at runtime -- if one changes without the other, the displayed countdown and
the actual leaderboard data window silently disagree. If you're asked to
change the period length or anchor, change both, and verify with a
side-by-side query (old view's row count/sum/max score vs. the new formula's)
before replacing the production view -- that comparison is what confirmed the
original 2026-08-05 cutover caused zero disruption.

This project's only remaining job (`gotw_weekly_export`) is a read-only
Sheets archive with no review gate -- appropriate because it can't affect
production data or the live leaderboard, unlike the doc's original Job B. It
runs Monday 15:00 NZT, after the period boundary has already rolled the live
view to the new week, so `export_and_archive.py` re-implements the same
bets/users join and scoring formula for a fixed, already-concluded window
instead of reading the (already-rolled-over) view. If the view's filter or
scoring logic changes, update this job's inline SQL to match, or the archive
and the live leaderboard will silently disagree.
