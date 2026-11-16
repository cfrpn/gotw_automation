-- Weekly Showdown results for Regan: one row per player per week.
-- Points/placing from manual.temporary.weekly_showdown_leaderboard_history (as-of Sheet snapshots),
-- Emeralds paid from BULK_ADD_POINTS / ACCOUNT_ADJUSTMENT credits tagged 'Promotional Points' + Showdown notes.
-- Adjustments join transactions on action_id ONLY (one adjustment row per bulk action).
-- When the prize table changes, update the prize CTE.
CREATE OR REPLACE VIEW manual.temporary.weekly_showdown_results
COMMENT 'Weekly Showdown: points, placing, expected vs paid Emeralds per player per week. Source SQL: gotw_automation/src/weekly_showdown_results_view.sql'
AS
WITH lb AS (
  SELECT period_start, period_end, rn, user_id, nickname, score
  FROM manual.temporary.weekly_showdown_leaderboard_history
),
periods AS (
  SELECT DISTINCT period_start, period_end FROM lb
),
-- Prize schedule by rank. Top 10 for periods ending before 2026-11-16;
-- PRIZE_RULES changed to top 15 on 2026-11-11, first paid for the period ending 2026-11-16.
prize AS (
  SELECT p.period_end, x.i + 1 AS rn, x.emeralds
  FROM periods p
  CROSS JOIN (SELECT posexplode(array(1000,750,500,400,350,300,250,200,150,100,90,80,70,60,50)) AS (i, emeralds)) x
  WHERE x.i + 1 <= CASE WHEN p.period_end < TIMESTAMP'2026-11-16' THEN 10 ELSE 15 END
),
-- One adjustment row per bulk action; join transactions on action_id ONLY.
adj AS (
  SELECT action_id, max(trim(additional_notes)) AS notes
  FROM ruby_sweeps.bronze.accounts_adjustments
  WHERE accounts_adjustment_type = 'Promotional Points'
    AND created_at >= TIMESTAMP'2026-08-10'
    AND ( lower(additional_notes) LIKE '%showdown%'
       OR lower(additional_notes) LIKE '%gotw%'
       OR lower(additional_notes) LIKE '%game of the week%'
       -- 2026-10-05 prizes were entered one by one as 'Tournament Winner'
       OR (lower(additional_notes) LIKE 'tournament winner%' AND CAST(created_at AS DATE) = DATE'2026-10-05'))
  GROUP BY action_id
),
paid_raw AS (
  SELECT t.user_id, t.created_at, t.amount / 100.0 AS emeralds, a.notes,
         lower(a.notes) LIKE '%spot%' AS is_spot
  FROM ruby_sweeps.bronze.sweep_tickets_transactions t
  JOIN adj a ON t.action_id = a.action_id
  WHERE t.amount > 0 AND t.created_at >= TIMESTAMP'2026-08-10'
),
-- A payout belongs to the most recent period that ended before it was made.
paid AS (
  SELECT p.period_end, r.user_id,
         SUM(CASE WHEN NOT r.is_spot THEN r.emeralds ELSE 0 END) AS prize_paid,
         SUM(CASE WHEN r.is_spot THEN r.emeralds ELSE 0 END)     AS spot_paid,
         concat_ws(' | ', collect_set(r.notes)) AS payout_notes,
         MIN(r.created_at) AS first_paid_at
  FROM paid_raw r
  JOIN periods p ON r.created_at >= p.period_end AND r.created_at < p.period_end + INTERVAL 7 DAYS
  GROUP BY p.period_end, r.user_id
)
SELECT
  COALESCE(l.period_start, pp.period_end - INTERVAL 7 DAYS) AS period_start,
  COALESCE(l.period_end, pp.period_end)                     AS period_end,
  l.rn, COALESCE(l.user_id, pp.user_id) AS user_id, l.nickname, l.score,
  COALESCE(z.emeralds, 0)     AS prize_expected,
  COALESCE(pp.prize_paid, 0)  AS prize_paid,
  COALESCE(pp.spot_paid, 0)   AS spot_paid,
  pp.payout_notes, pp.first_paid_at,
  CASE
    WHEN COALESCE(z.emeralds,0) = 0 AND COALESCE(pp.prize_paid,0) = 0 THEN 'no prize'
    WHEN COALESCE(z.emeralds,0) = COALESCE(pp.prize_paid,0)            THEN 'paid OK'
    WHEN COALESCE(pp.prize_paid,0) = 0 AND l.period_end + INTERVAL 7 DAYS > current_timestamp() THEN 'not paid yet'
    WHEN COALESCE(pp.prize_paid,0) = 0                                  THEN 'MISSING payout'
    WHEN COALESCE(z.emeralds,0) = 0                                     THEN 'PAID but not in prize ranks'
    ELSE 'AMOUNT mismatch'
  END AS payout_status
FROM lb l
LEFT JOIN prize z ON z.period_end = l.period_end AND z.rn = l.rn
FULL OUTER JOIN paid pp ON pp.period_end = l.period_end AND pp.user_id = l.user_id
