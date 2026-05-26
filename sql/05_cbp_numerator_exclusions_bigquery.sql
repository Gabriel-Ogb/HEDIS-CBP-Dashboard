-- ============================================================
-- CBP Project — Step 2 (BigQuery): NUMERATOR + EXCLUSIONS + FUNNEL + TABLEAU EXTRACT
-- Dialect: BigQuery Standard SQL
-- Run AFTER 02_cbp_denominator_bigquery.sql (depends on hedis_cbp.cbp_denominator).
-- Measurement Year (MY) = 2025
--   Numerator BP window: 2025-01-01 .. 2025-12-31
--   Control threshold: systolic < 140 (<=139) AND diastolic < 90 (<=89)
--
-- Replace `cbp-2025.hedis_cbp` / `hedis_cbp` with your project.dataset if different.
-- ============================================================

-- ------------------------------------------------------------
-- 1. STAGING: pivot BP observations into one row per member per reading-date
--    Synthea stores systolic (LOINC 8480-6) and diastolic (8462-4) as SEPARATE
--    rows. We pivot them together by (patient, date). VALUE may be autodetected
--    as STRING, so SAFE_CAST to FLOAT64. Restrict to the MY (2025).
--    Same-day tiebreaker: if multiple readings exist on one date, HEDIS uses the
--    LOWEST reading -> we take MIN systolic and MIN diastolic for that date.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_bp_readings AS
SELECT
  o.PATIENT                                   AS member_id,
  DATE(o.DATE)                                AS reading_date,
  MIN(IF(o.CODE = '8480-6', SAFE_CAST(o.VALUE AS FLOAT64), NULL)) AS systolic,
  MIN(IF(o.CODE = '8462-4', SAFE_CAST(o.VALUE AS FLOAT64), NULL)) AS diastolic
FROM hedis_cbp.observations o
WHERE o.CODE IN ('8480-6','8462-4')
  AND DATE(o.DATE) BETWEEN DATE '2025-01-01' AND DATE '2025-12-31'
GROUP BY member_id, reading_date
HAVING systolic IS NOT NULL AND diastolic IS NOT NULL;   -- keep complete readings only

-- ------------------------------------------------------------
-- 2. STAGING: the REPRESENTATIVE reading = most recent in MY, on/after anchor date
--    Join readings to the denominator (which carries second_htn_dx_date = anchor).
--    Keep readings on/after the anchor, then rank by date DESC -> rn=1 is the
--    representative (most recent) reading used for the numerator test.
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_representative_bp AS
WITH eligible_readings AS (
  SELECT
    d.member_id,
    r.reading_date,
    r.systolic,
    r.diastolic,
    ROW_NUMBER() OVER (
      PARTITION BY d.member_id
      ORDER BY r.reading_date DESC
    ) AS rn
  FROM hedis_cbp.cbp_denominator d
  JOIN hedis_cbp.stg_bp_readings r
    ON r.member_id = d.member_id
   AND r.reading_date >= d.second_htn_dx_date    -- on/after the anchor date
)
SELECT member_id, reading_date, systolic, diastolic
FROM eligible_readings
WHERE rn = 1;

-- ------------------------------------------------------------
-- 3. STAGING: EXCLUSIONS (anti-join sources), matched to codes confirmed in data
--    a) ESRD / kidney transplant — ANY time in history (no date restriction)
--    b) Pregnancy — FEMALE members with a pregnancy episode OVERLAPPING the MY
--       (START <= MY end AND (STOP IS NULL OR STOP >= MY start)); excludes stale
--       historical pregnancies. "Past history of miscarriage" code intentionally
--       NOT included (it is a history finding, not an active pregnancy).
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW hedis_cbp.stg_excl_esrd_transplant AS
SELECT DISTINCT PATIENT AS member_id
FROM hedis_cbp.conditions
WHERE CAST(CODE AS STRING) IN (
  '46177005',    -- End-stage renal disease
  '698306007',   -- Awaiting kidney transplantation
  '161665007',   -- History of renal transplant
  '213150003'    -- Kidney transplant failure and rejection
);

CREATE OR REPLACE VIEW hedis_cbp.stg_excl_pregnancy AS
SELECT DISTINCT c.PATIENT AS member_id
FROM hedis_cbp.conditions c
JOIN hedis_cbp.patients p ON p.Id = c.PATIENT
WHERE p.GENDER = 'F'
  AND CAST(c.CODE AS STRING) IN (
    '72892002',   -- Normal pregnancy
    '198992004',  -- Eclampsia in pregnancy
    '79586000',   -- Tubal pregnancy
    '609496007'   -- Complication occurring during pregnancy
  )
  AND DATE(c.START) <= DATE '2025-12-31'
  AND COALESCE(DATE(c.STOP), DATE '9999-12-31') >= DATE '2025-01-01';

-- ------------------------------------------------------------
-- 4. FINAL MEMBER-LEVEL RESULT TABLE (feeds Tableau)
--    One row per denominator member with: exclusion flag, numerator components,
--    controlled flag, and a gap-in-care flag (eligible, not excluded, not controlled).
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE hedis_cbp.cbp_member_results AS
SELECT
  d.member_id,
  d.age_eoy,
  d.age_band,
  d.gender,
  d.race,
  d.ethnicity,
  d.second_htn_dx_date                         AS anchor_date,
  rep.reading_date                             AS last_bp_date,
  rep.systolic                                 AS last_systolic,
  rep.diastolic                                AS last_diastolic,
  -- exclusion flags
  (ex_esrd.member_id IS NOT NULL)              AS excl_esrd_transplant,
  (ex_preg.member_id IS NOT NULL)              AS excl_pregnancy,
  (ex_esrd.member_id IS NOT NULL OR ex_preg.member_id IS NOT NULL) AS excluded,
  -- numerator: controlled = has a representative reading AND <140/90
  ( rep.member_id IS NOT NULL
    AND rep.systolic <= 139
    AND rep.diastolic <= 89 )                  AS bp_controlled,
  -- gap in care: in the measured population (not excluded) but not controlled
  ( ex_esrd.member_id IS NULL
    AND ex_preg.member_id IS NULL
    AND NOT ( rep.member_id IS NOT NULL AND rep.systolic <= 139 AND rep.diastolic <= 89 )
  )                                            AS gap_in_care
FROM hedis_cbp.cbp_denominator d
LEFT JOIN hedis_cbp.stg_representative_bp     rep      ON rep.member_id     = d.member_id
LEFT JOIN hedis_cbp.stg_excl_esrd_transplant  ex_esrd ON ex_esrd.member_id = d.member_id
LEFT JOIN hedis_cbp.stg_excl_pregnancy        ex_preg ON ex_preg.member_id = d.member_id;

-- ------------------------------------------------------------
-- 5. FUNNEL + RATE (the headline numbers for the dashboard)
--    Measured population = denominator MINUS exclusions.
--    Rate = controlled / measured population.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE hedis_cbp.cbp_summary AS
SELECT
  COUNT(*)                                                   AS eligible_denominator,
  COUNTIF(excluded)                                          AS excluded_members,
  COUNTIF(NOT excluded)                                      AS measured_population,
  COUNTIF(NOT excluded AND bp_controlled)                    AS numerator_controlled,
  ROUND(SAFE_DIVIDE(
    COUNTIF(NOT excluded AND bp_controlled),
    COUNTIF(NOT excluded)) * 100, 1)                         AS cbp_rate_pct
FROM hedis_cbp.cbp_member_results;

-- ------------------------------------------------------------
-- 6. RATE BY STRATUM (for dashboard breakouts)
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE hedis_cbp.cbp_rate_by_ageband AS
SELECT
  age_band,
  COUNTIF(NOT excluded)                                      AS measured_population,
  COUNTIF(NOT excluded AND bp_controlled)                    AS numerator_controlled,
  ROUND(SAFE_DIVIDE(
    COUNTIF(NOT excluded AND bp_controlled),
    COUNTIF(NOT excluded)) * 100, 1)                         AS cbp_rate_pct
FROM hedis_cbp.cbp_member_results
GROUP BY age_band
ORDER BY age_band;

-- ------------------------------------------------------------
-- 7. SANITY CHECKS — run after the script completes
-- ------------------------------------------------------------
-- SELECT * FROM hedis_cbp.cbp_summary;
-- SELECT * FROM hedis_cbp.cbp_rate_by_ageband;
-- How many members have NO qualifying BP reading at all (counted as not controlled)?
--   SELECT COUNTIF(last_bp_date IS NULL) AS no_reading, COUNT(*) AS total
--   FROM hedis_cbp.cbp_member_results;
-- Exclusion counts:
--   SELECT COUNTIF(excl_esrd_transplant) AS esrd_tx, COUNTIF(excl_pregnancy) AS preg,
--          COUNTIF(excluded) AS any_excl FROM hedis_cbp.cbp_member_results;
-- Spot-check a few controlled vs uncontrolled members:
--   SELECT member_id, age_band, last_bp_date, last_systolic, last_diastolic,
--          bp_controlled, excluded, gap_in_care
--   FROM hedis_cbp.cbp_member_results ORDER BY last_bp_date DESC LIMIT 20;
