-- Reference copy of the production view (first deployed 2026-08-05).
-- Not read or executed by any job -- this is a record of what's live, kept in
-- sync by hand whenever the production view changes (rare: the window is now
-- self-computing, so there should be no reason to touch this regularly).
--
-- History: 2026-08-05 to 2026-11-11 the period was a fixed-UTC rolling
-- window (anchor 2026-08-03T02:00:00 UTC + n*7 days). Replaced by the
-- NZ-local boundary described below. The period must stay identical to
-- lems2.0/server.js's getCurrentPeriod() -- both sides compute it
-- independently, with no coordination step between them.
--
-- "Final Six" 2x points rule (permanent as of 2026-08-21, per Nina): the
-- last 6 hours of every period are worth double points. This started as a
-- one-off promo for the 2026-08-17 boundary only (see
-- ../promotions/2026-08-17_weekly_showdown_2x.sql), then was made a
-- standing recurring rule -- it now applies to every period until Nina
-- says otherwise, computed off period_end so it needs no per-week edits.
-- Since 2026-11-11 period_end is Monday 15:00 NZ local time, so Final Six is
-- Monday 09:00-15:00 NZ local year-round (see AGENTS.md). Keep gotw_weekly_export/export_and_archive.py's inline
-- SQL in sync with this -- see the comment there.
--
-- rn tiebreak (added 2026-08-25): ROW_NUMBER() alone doesn't guarantee a
-- stable order for tied scores, so two players with an unchanged, identical
-- score could swap rn between two executions -- which reads as a false
-- rank-change once lems2.0 starts showing up/down arrows. u.user_id as a
-- secondary sort key makes ties deterministic without touching scoring.

-- NZ-local boundary (changed 2026-11-11, per Nina/marketing): the period now
-- runs Monday 15:00 to the following Monday 15:00 New Zealand local time,
-- fixed year-round -- NOT a fixed UTC instant. That's 02:00 UTC under NZDT
-- and 03:00 UTC under NZST; the weeks containing an NZ DST change are
-- 169h (April) / 167h (September). Under NZDT this is identical to the old
-- fixed 2026-08-03T02:00 UTC + 7-day formula, which is what made the cutover
-- zero-disruption. lems2.0/server.js getCurrentPeriod() and
-- export_and_archive.py compute the same boundary independently -- keep all
-- three in sync. Final Six is still "last 6 hours before period_end", i.e.
-- Monday 09:00-15:00 NZ local. Assumes the SQL session timezone is UTC
-- (Databricks SQL default; the old formula's TIMESTAMP literal relied on
-- the same thing).
--
-- After running this, re-grant (CREATE OR REPLACE drops direct grants):
--   GRANT SELECT ON TABLE ruby_sweeps._logs.lems_gotw_ongoing_leaderboard
--     TO `c1ca55d1-a2b9-487a-a45c-73e1d0238dc4`;  -- Ruby Loyalty Features (lems2.0 on Railway)
CREATE OR REPLACE VIEW ruby_sweeps._logs.lems_gotw_ongoing_leaderboard AS
WITH nz_now AS (
  SELECT from_utc_timestamp(CURRENT_TIMESTAMP(), 'Pacific/Auckland') AS nz_now
),
local_start AS (
  -- date_trunc('WEEK') = Monday 00:00 (NZ wall clock here); +15h = Monday 15:00 NZ.
  -- Before Monday 15:00 NZ we're still in last week's period.
  SELECT CASE
    WHEN nz_now >= date_trunc('WEEK', nz_now) + INTERVAL 15 HOURS
    THEN date_trunc('WEEK', nz_now) + INTERVAL 15 HOURS
    ELSE date_trunc('WEEK', nz_now) - INTERVAL 7 DAYS + INTERVAL 15 HOURS
  END AS local_start
  FROM nz_now
),
period_bounds AS (
  -- Convert both NZ wall-clock boundaries back to UTC separately, so a week
  -- spanning an NZ DST change correctly comes out 167h / 169h long.
  SELECT
    to_utc_timestamp(local_start, 'Pacific/Auckland')                    AS period_start,
    to_utc_timestamp(local_start + INTERVAL 7 DAYS, 'Pacific/Auckland') AS period_end
  FROM local_start
),
filtered_bets AS (
  SELECT
    b.user_id,
    CASE
      WHEN b.created_at >= pb.period_end - INTERVAL 6 HOURS
       AND b.created_at <  pb.period_end
      THEN b.bet_amount * 2   -- Final Six: last 6h of every period, 2x points
      ELSE b.bet_amount
    END AS bet_amount
  FROM ruby_sweeps.bronze.bets b
  CROSS JOIN period_bounds pb
  WHERE b.created_at >= pb.period_start
    AND b.created_at < pb.period_end
    AND b.currency = 'SWEEP_TICKETS'
  -- no game_name filter: this activity covers all games
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
ORDER BY score DESC, u.user_id ASC
