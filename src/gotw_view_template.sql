-- Reference copy of the view actually deployed to production on 2026-08-05.
-- Not read or executed by any job -- this is a record of what's live, kept in
-- sync by hand whenever the production view changes (rare: the window is now
-- self-computing, so there should be no reason to touch this regularly).
--
-- The anchor (2026-08-03T02:00:00 UTC) matches the window that was already
-- live at cutover time, so switching to this formula caused zero disruption
-- to the then-current period. It must stay identical to the anchor in
-- lems2.0/server.js's getCurrentPeriod() -- both sides compute the same
-- rolling 7-day window independently, with no coordination step between them.
--
-- "Final Six" 2x points rule (permanent as of 2026-08-21, per Nina): the
-- last 6 hours of every period are worth double points. This started as a
-- one-off promo for the 2026-08-17 boundary only (see
-- ../promotions/2026-08-17_weekly_showdown_2x.sql), then was made a
-- standing recurring rule -- it now applies to every period until Nina
-- says otherwise, computed off period_end so it needs no per-week edits.
-- Because period_end is a fixed UTC instant, this window is fixed in UTC,
-- not NZT: it lands at 8am-2pm NZT under NZST but shifts to 9am-3pm NZT
-- once NZDT starts (same DST consideration as the archive job schedule --
-- see AGENTS.md). Keep gotw_weekly_export/export_and_archive.py's inline
-- SQL in sync with this -- see the comment there.

CREATE OR REPLACE VIEW ruby_sweeps._logs.lems_gotw_ongoing_leaderboard AS
WITH period AS (
  SELECT TIMESTAMP_SECONDS(
    UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')
    + FLOOR((UNIX_TIMESTAMP(CURRENT_TIMESTAMP()) - UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')) / 604800) * 604800
  ) AS period_start
),
period_bounds AS (
  SELECT period_start, period_start + INTERVAL 7 DAYS AS period_end
  FROM period
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
  ROW_NUMBER() OVER (ORDER BY FLOOR(SUM(b.bet_amount) / 500) DESC) AS rn,
  u.user_id, u.email, u.nickname,
  FLOOR(SUM(b.bet_amount) / 500) AS score
FROM verified_users u
INNER JOIN filtered_bets b USING (user_id)
GROUP BY u.user_id, u.email, u.nickname
ORDER BY score DESC
