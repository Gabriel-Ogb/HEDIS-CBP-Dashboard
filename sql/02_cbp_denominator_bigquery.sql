-- ============================================================
-- CBP Project — Step 1 (BigQuery): build the DENOMINATOR
-- Dialect: BigQuery Standard SQL
-- Measurement Year (MY) = 2025  (current HEDIS MY; report year 2026)
--   Dx identification window: 2024-01-01 .. 2025-06-30
--   Numerator BP window:      2025-01-01 .. 2025-12-31  (used in Step 2)
--   Age 18-85 as of 2025-12-31
--
-- BEFORE RUNNING: replace `hedis_cbp` everywhere with your dataset name if different.
-- This script assumes you loaded the five Synthea CSVs with "Auto detect" schema ON,
-- which makes Synthea ISO date strings load as native DATE / TIMESTAMP types.
-- ============================================================

-- ------------------------------------------------------------
-- HOW TO LOAD (Console UI, recommended):
--   BigQuery Console > your dataset > Create Table
--   Source: Upload > choose file from ~/cbp_project/synthea/output/csv/
--   File format: CSV
--   Table name: patients / conditions / encounters / observations / payer_transitions
--   Schema: check "Auto detect"
--   Advanced > Header rows to skip: 1
--   Repeat for all five files.
--
-- HOW TO LOAD (bq CLI alternative — run in Terminal from output/csv/):
--   bq mk --dataset hedis_cbp
--   bq load --autodetect --skip_leading_rows=1 --source_format=CSV hedis_cbp.patients        ./patients.csv
--   bq load --autodetect --skip_leading_rows=1 --source_format=CSV hedis_cbp.conditions      ./conditions.csv
--   bq load --autodetect --skip_leading_rows=1 --source_format=CSV hedis_cbp.encounters      ./encounters.csv
--   bq load --autodetect --skip_leading_rows=1 --source_format=CSV hedis_cbp.observations    ./observations.csv
--   bq load --autodetect --skip_leading_rows=1 --source_format=CSV hedis_cbp.payer_transitions ./payer_transitions.csv
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 1. PARAMETERS  (declared as scripting variables — single source of truth)
--    BigQuery runs DECLARE/SET at the top of a multi-statement script.
-- ------------------------------------------------------------
DECLARE my_end          DATE DEFAULT DATE '2025-12-31';
DECLARE dx_window_start DATE DEFAULT DATE '2024-01-01';   -- Jan 1 of year PRIOR to MY
DECLARE dx_window_end   DATE DEFAULT DATE '2025-06-30';   -- Jun 30 of MY

-- ------------------------------------------------------------
-- 2. STAGING: members with computed age as of MY end
--    Synthea BIRTHDATE autodetects as DATE. Whole-year age:
--    year diff, minus 1 if the birthday hasn't occurred by my_end.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_members AS
SELECT
  p.Id        AS member_id,
  p.BIRTHDATE AS birthdate,
  p.DEATHDATE AS deathdate,
  p.GENDER    AS gender,
  p.RACE      AS race,
  p.ETHNICITY AS ethnicity,
  DATE_DIFF(DATE '2025-12-31', p.BIRTHDATE, YEAR)
    - IF( (EXTRACT(MONTH FROM p.BIRTHDATE), EXTRACT(DAY FROM p.BIRTHDATE))
          > (EXTRACT(MONTH FROM DATE '2025-12-31'), EXTRACT(DAY FROM DATE '2025-12-31')),
          1, 0)                                  AS age_eoy
FROM hedis_cbp.patients p;
-- NOTE: Dec 31 is year-end so the birthday adjustment will essentially never subtract,
-- but it's kept for correctness/portability if you ever move the anchor date.

-- ------------------------------------------------------------
-- 3. STAGING: hypertension diagnosis EVENTS tied to encounter service dates
--    CBP "two diagnoses on different dates of service" is modeled by joining
--    HTN conditions to their encounters and counting DISTINCT encounter dates
--    within the identification window. (conditions.csv stores onset once;
--    the diagnosis recurs across encounters — confirmed ENCOUNTER is populated.)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_htn_dx_events AS
SELECT DISTINCT
  c.PATIENT          AS member_id,
  DATE(e.START)      AS service_date     -- e.START is TIMESTAMP; DATE() drops the time
FROM hedis_cbp.conditions c
JOIN hedis_cbp.encounters e
  ON e.Id = c.ENCOUNTER
WHERE c.CODE = 59621000                  -- Essential hypertension (SNOMED), confirmed in data
  AND DATE(e.START) BETWEEN DATE '2024-01-01' AND DATE '2025-06-30';
-- If autodetect typed CODE as STRING instead of INT, use:  c.CODE = '59621000'

-- ------------------------------------------------------------
-- 4. STAGING: members meeting the TWO-DIFFERENT-DATES rule + anchor date
--    second_htn_dx_date = the 2nd distinct service date; the numerator BP
--    reading (Step 2) must fall on or after this anchor.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_htn_qualified AS
WITH ranked AS (
  SELECT
    member_id,
    service_date,
    ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY service_date) AS rn
  FROM hedis_cbp.stg_htn_dx_events
)
SELECT
  member_id,
  COUNT(*)                                          AS htn_dx_date_count,
  MIN(service_date)                                 AS first_htn_dx_date,
  MIN(IF(rn = 2, service_date, NULL))               AS second_htn_dx_date
FROM ranked
GROUP BY member_id
HAVING COUNT(*) >= 2;

-- ------------------------------------------------------------
-- 5. STAGING: continuous enrollment (simplified, documented)
--    HEDIS CBP requires MY enrollment with no more than one gap up to 45 days.
--    Synthea payer_transitions schema varies by version; this handles both the
--    year-based and date-based variants. Simplified rule: coverage straddles MY end.
--    >> Document this simplification in the README.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_enrolled AS
SELECT DISTINCT pt.PATIENT AS member_id
FROM hedis_cbp.payer_transitions pt
WHERE
  -- date-based columns (newer Synthea): START_DATE / END_DATE
  ( SAFE_CAST(pt.START_DATE AS DATE) <= DATE '2025-12-31'
    AND COALESCE(SAFE_CAST(pt.END_DATE AS DATE), DATE '9999-12-31') >= DATE '2025-12-31' )
  OR
  -- year-based columns (older Synthea): START_YEAR / END_YEAR
  ( SAFE_CAST(pt.START_YEAR AS INT64) <= 2025
    AND COALESCE(SAFE_CAST(pt.END_YEAR AS INT64), 9999) >= 2025 );
-- If your payer_transitions has neither pair of columns (run: check the header),
-- tell me the actual column names and I'll adjust. As a fallback you may treat all
-- members as enrolled and state that assumption in the README.

-- ------------------------------------------------------------
-- 6. DENOMINATOR (eligible population, BEFORE exclusions)
--    Exclusions (ESRD, transplant, pregnancy, frailty/advanced-illness 81+)
--    are applied in Step 2 as anti-joins, kept separate so you can report the
--    funnel: eligible -> after exclusions -> numerator-compliant.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE hedis_cbp.cbp_denominator AS
SELECT
  m.member_id,
  m.age_eoy,
  m.gender,
  m.race,
  m.ethnicity,
  q.htn_dx_date_count,
  q.first_htn_dx_date,
  q.second_htn_dx_date,          -- anchor date for the numerator
  CASE
    WHEN m.age_eoy BETWEEN 18 AND 44 THEN '18-44'
    WHEN m.age_eoy BETWEEN 45 AND 64 THEN '45-64'
    WHEN m.age_eoy BETWEEN 65 AND 85 THEN '65-85'
  END AS age_band
FROM hedis_cbp.stg_members      m
JOIN hedis_cbp.stg_htn_qualified q  ON q.member_id  = m.member_id
JOIN hedis_cbp.stg_enrolled      en ON en.member_id = m.member_id
WHERE m.age_eoy BETWEEN 18 AND 85;

-- ------------------------------------------------------------
-- 7. SANITY CHECKS — run each after the script completes
-- ------------------------------------------------------------
-- SELECT COUNT(*) AS total_patients          FROM hedis_cbp.patients;
-- SELECT COUNT(DISTINCT member_id) AS any_htn FROM hedis_cbp.stg_htn_dx_events;
-- SELECT COUNT(*) AS two_dx_members           FROM hedis_cbp.stg_htn_qualified;
-- SELECT COUNT(*) AS eligible_denominator     FROM hedis_cbp.cbp_denominator;
-- SELECT age_band, COUNT(*) FROM hedis_cbp.cbp_denominator GROUP BY age_band ORDER BY age_band;
-- Confirm every denominator member has an anchor date (expect 0):
-- SELECT COUNT(*) AS missing_anchor FROM hedis_cbp.cbp_denominator WHERE second_htn_dx_date IS NULL;
