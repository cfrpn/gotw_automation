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

CREATE OR REPLACE VIEW ruby_sweeps._logs.lems_gotw_ongoing_leaderboard AS
WITH period AS (
  SELECT TIMESTAMP_SECONDS(
    UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')
    + FLOOR((UNIX_TIMESTAMP(CURRENT_TIMESTAMP()) - UNIX_TIMESTAMP(TIMESTAMP'2026-08-03T02:00:00.000')) / 604800) * 604800
  ) AS period_start
),
filtered_bets AS (
  SELECT b.user_id, b.bet_amount
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
