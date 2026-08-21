-- ONE-OFF PROMOTION: "Weekly Showdown Tournament" -- 2x leaderboard points.
--
-- Window: 8am-2pm NZT, Monday 17 August 2026 (NZST, UTC+12)
--       = 2026-08-16T20:00:00 UTC to 2026-08-17T02:00:00 UTC
-- Note: the window ends exactly at the 2026-08-17T02:00:00 UTC period
-- rollover boundary, so it sits entirely inside the last 6 hours of the
-- period that started 2026-08-10T02:00:00 UTC. No cross-period complication.
--
-- Effect: bet_amount is doubled before it feeds the score formula
-- (score = FLOOR(SUM(bet_amount) / 500)) for activity inside the window
-- only; everything else in the period counts at the normal 1x rate.
--
-- Manual process (per Nina, 2026-08-05):
--   1. Apply this CREATE OR REPLACE VIEW before 2026-08-16T20:00:00 UTC.
--   2. After 2026-08-17T02:00:00 UTC (promo over), manually switch back to
--      the plain view in ../src/gotw_view_template.sql. This file is not
--      applied automatically by any job -- Nina will be reminded to revert
--      by hand, and there's no cleanup job watching for this.
--
-- UPDATE 2026-08-21 (per Nina): this "last 6 hours = 2x" window turned into
-- a permanent recurring rule ("Final Six"), not a one-off. The production
-- view and the archive job now compute it every period from period_end --
-- see ../src/gotw_view_template.sql and
-- ../src/gotw_weekly_export/export_and_archive.py. This file is kept only
-- as a historical record of the first (one-off, hardcoded-dates) instance.

CREATE OR REPLACE VIEW ruby_sweeps._logs.lems_gotw_ongoing_leaderboard AS
WITH period AS (
  SELECT TIMESTAMP_SECONDS(
    UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')
    + FLOOR((UNIX_TIMESTAMP(CURRENT_TIMESTAMP()) - UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')) / 604800) * 604800
  ) AS period_start
),
filtered_bets AS (
  SELECT
    b.user_id,
    CASE
      WHEN b.created_at >= TIMESTAMP'2026-08-16T20:00:00.000'
       AND b.created_at <  TIMESTAMP'2026-08-17T02:00:00.000'
      THEN b.bet_amount * 2   -- Weekly Showdown Tournament: 2x points
      ELSE b.bet_amount
    END AS bet_amount
  FROM ruby_sweeps.bronze.bets b
  CROSS JOIN period p
  WHERE b.created_at >= p.period_start
    AND b.created_at < p.period_start + INTERVAL 7 DAYS
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
  ROW_NUMBER() OVER (ORDER BY FLOOR(SUM(b.bet_amount) / 500) DESC) AS rn,
  u.user_id, u.email, u.nickname,
  FLOOR(SUM(b.bet_amount) / 500) AS score
FROM verified_users u
INNER JOIN filtered_bets b USING (user_id)
GROUP BY u.user_id, u.email, u.nickname
ORDER BY score DESC
