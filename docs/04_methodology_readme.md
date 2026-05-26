# CBP Project — Measure Logic & Methodology Notes (README excerpt)

## Measure: Controlling High Blood Pressure (CBP), HEDIS MY 2025

**Plain-English definition.** The percentage of members 18–85 years of age who had a
diagnosis of hypertension (HTN) and whose most recent blood pressure reading in the
measurement year was adequately controlled (<140/90 mm Hg, i.e. systolic ≤139 AND
diastolic ≤89).

**Windows used (MY 2025):**
- Diagnosis identification window: 2024-01-01 → 2025-06-30
- Numerator BP window: 2025-01-01 → 2025-12-31
- Age evaluated as of: 2025-12-31

---

## Data source

Synthetic data generated with **Synthea** (MITRE), ~3,280 patients, Texas demographics,
seeded (`-s 12345 -cs 6789`) for reproducibility, anchored to MY 2025 (`-r 20251231`).
Synthea emits SNOMED/LOINC codes (not the ICD-10/CPT + NCQA value sets used in production
HEDIS). Clinically-equivalent codes were mapped:
- Hypertension: SNOMED **59621000** (Essential hypertension)
- Systolic BP: LOINC **8480-6**
- Diastolic BP: LOINC **8462-4**

---

## IMPORTANT METHODOLOGY ADAPTATION (disclosed)

**The two-diagnoses-on-different-dates requirement.** HEDIS CBP requires the member to
have hypertension documented on **two different dates of service** in the identification
window. In real claims data, the HTN diagnosis code is repeated on every qualifying visit,
so this is literally "two dx-coded claims on two dates."

**Synthea behaves differently:** it records each condition only ONCE, at onset, and does
not re-emit the diagnosis code at subsequent encounters. A literal implementation
(`condition row JOINed to its single recording encounter`) therefore yielded ~0 qualifying
members — not because the population lacks hypertension, but because the data model doesn't
repeat the code.

**Adaptation applied:** A member who HAS hypertension (onset on or before the window end)
is credited with a "diagnosis date of service" on each DISTINCT encounter date that falls
within the identification window. Two or more distinct in-window encounter dates satisfy
the "two different dates" rule. The 2nd distinct date is used as the anchor date for the
numerator (the controlling BP reading must occur on or after it).

**Why this is defensible:** It preserves the *intent* of the measure (the member has
hypertension and was seen on multiple dates while having it) and adapts faithfully to the
synthetic data's structure. **Trade-off, stated honestly:** it is a slightly looser reading
than "two dx-coded claims," and would be re-tightened against real claims data where the
diagnosis recurs per visit. This is a synthetic-data modeling decision, not a production
HEDIS engine.

## Other documented simplifications
- **Continuous enrollment:** real CBP allows at most one enrollment gap of up to 45 days
  during the MY. Here, simplified to "had a coverage span (payer_transitions) covering the
  MY end date (2025-12-31)." Reasonable for synthetic data; flagged as a simplification.
- **Exclusions** (ESRD, kidney transplant, pregnancy, advanced illness/frailty for 66+):
  applied in Step 2 as anti-joins. [To be completed in Step 2.]

---

## Step 1 result — DENOMINATOR (eligible population, before exclusions)

Funnel:
| Stage | Count |
|---|---|
| Total synthetic patients | 3,280 |
| Distinct patients with hypertension (SNOMED 59621000) | 620 |
| Eligible denominator (age 18–85 + two-different-dates + enrolled) | **465** |

Age-band distribution of the denominator (clinically plausible — prevalence rises with age):
| Age band | Members |
|---|---|
| 18–44 | 73 |
| 45–64 | 256 |
| 65–85 | 136 |

Data-quality check: members with a missing anchor (2nd dx date) = **0** (every denominator
member has a valid numerator anchor date).

## SQL dialect notes (BigQuery) — lessons logged
- Age computed with `DATE_DIFF` + `DATE_ADD` birthday adjustment. An earlier tuple
  comparison `(month,day) > (month,day)` failed in BigQuery (treated as STRUCT compare);
  rewritten with date math.
- BigQuery validates every column reference at parse time, including inside OR branches
  that never execute, so a "defensive" branch referencing non-existent year-based
  enrollment columns errored and was removed to match the actual schema.
- CODE matched via `CAST(CODE AS STRING) = '59621000'` to be robust to autodetected type.

---

## Step 2 result — NUMERATOR, EXCLUSIONS & RATE

**Numerator logic.** For each eligible member, the representative BP reading is the MOST
RECENT reading in the MY (2025) occurring ON OR AFTER the anchor date (2nd HTN dx date).
Systolic (LOINC 8480-6) and diastolic (8462-4) are stored as separate observation rows in
Synthea; they are pivoted into one reading per (member, date). Same-day tiebreaker uses the
lowest reading (HEDIS rule). Control = systolic <=139 AND diastolic <=89 (i.e. <140/90).
Members with no qualifying reading count as not controlled.

**Exclusions (anti-joins).**
- ESRD / kidney transplant, any time in history (SNOMED 46177005, 698306007, 161665007,
  213150003).
- Pregnancy, FEMALE members only, restricted to episodes OVERLAPPING the MY via START/STOP
  span (SNOMED 72892002, 198992004, 79586000, 609496007). Stale historical pregnancies are
  correctly NOT excluded. "Past history of miscarriage" (161744009) intentionally excluded
  from the exclusion set (history finding, not active pregnancy). Bone-marrow/stem-cell
  transplant codes intentionally NOT used (CBP excludes kidney transplant only).

**Results (MY 2025, synthetic population):**
| Metric | Value |
|---|---|
| Eligible denominator | 465 |
| Excluded (ESRD/transplant 50; pregnancy 8) | 57 |
| Measured population | 408 |
| Numerator (controlled) | 266 |
| **CBP rate** | **65.2%** |

Rate by age band (control improves with age — a real-world pattern):
| Age band | Measured | Controlled | Rate |
|---|---|---|---|
| 18–44 | 65 | 38 | 58.5% |
| 45–64 | 234 | 146 | 62.4% |
| 65–85 | 109 | 82 | 75.2% |

Data-quality: only 4 of 465 members had no qualifying BP reading on/after their anchor
date — confirms the anchor logic is not over-disqualifying. The 65.2% overall rate is
consistent with real-world CBP performance (typically low-60s to low-70s), supporting the
credibility of the synthetic model.

---

## Step 3 result — INDEPENDENT VALIDATION (pandas vs BigQuery)

To verify the measure logic, the entire CBP calculation was re-implemented independently
in Python/pandas (`validate_cbp.py`), reading the SAME raw Synthea CSVs and reproducing
every stage: age, hypertension identification, two-distinct-encounter-dates rule + anchor,
enrollment, BP pivot, most-recent-on/after-anchor representative reading, the <140/90
control test, and both exclusion sets. The script ASSERTS each result against BigQuery.

**Reconciliation: ALL CHECKS PASSED — pandas reproduces BigQuery exactly.**

| Metric | BigQuery | pandas | Match |
|---|---|---|---|
| Eligible denominator | 465 | 465 | OK |
| Excluded | 57 | 57 | OK |
| Measured population | 408 | 408 | OK |
| Numerator (controlled) | 266 | 266 | OK |
| CBP rate | 65.2% | 65.2% | OK |
| 18–44 (meas/ctrl/rate) | 65/38/58.5 | 65/38/58.5 | OK |
| 45–64 | 234/146/62.4 | 234/146/62.4 | OK |
| 65–85 | 109/82/75.2 | 109/82/75.2 | OK |

**Debugging note (worth describing in interviews).** Initial pandas runs returned a
numerator of exactly 0 while all upstream counts matched. Staged diagnostics isolated the
cause to `pandas.groupby().nth(1)`: in pandas 2.x it returns a Series keyed by the original
row index rather than the group key, so anchor dates could not be merged back to members and
the numerator silently collapsed. Refactored to a deterministic per-member date ranking
(`rank(method="first")`, filter to rank == 2), after which both engines agreed exactly. A
second issue — comparing tz-aware Synthea timestamps against tz-naive comparison dates — was
fixed with a uniform timezone-stripping date parser. Both are realistic healthcare-data
engineering issues; the SQL-vs-pandas reconciliation is what surfaced them.

---

## Dashboard — stratification & small-cell suppression (Tableau)

The dashboard stratifies the CBP rate by age band, gender, race, and ethnicity (a
parameter-driven dimension switcher in Tableau lets the viewer toggle the demographic
breakout).

**Small-cell suppression.** Rates for demographic groups with fewer than 20 measured
members are suppressed (shown as Not Reportable / no bar), because rates on tiny
denominators are statistically unreliable. Example: the "Native Hawaiian/Other" race cell
had only 6 measured members and showed a spurious 100% — suppressed. NCQA production
reporting typically suppresses at n<30; the threshold was set to n<20 here to suit the
synthetic sample size, and this adjustment is disclosed.

Groups suppressed in this population (measured n): other (1), Native American (3),
Native Hawaiian (5). Reportable race groups: Asian (36), Black (76), White (344).

**Findings (synthetic population):**
- Age: clear gradient, control improves with age (58.5% → 62.4% → 75.2%).
- Ethnicity: Hispanic 61% vs non-Hispanic 68% — a ~7-point disparity worth flagging.
- Gender: 64.8% (M) vs 65.7% (F) — no meaningful disparity.
- Race: reportable groups cluster in the low-to-mid 60s after suppression.

---

## Dashboard — exclusions breakdown & improvement opportunity

**Exclusions breakdown.** Excluded members shown by reason: ESRD/Kidney transplant (50),
Pregnancy (7) = 57, tying to the funnel's unique excluded count. Note: exclusions can
overlap — one member qualified for BOTH ESRD and pregnancy. The breakdown's IF/ELSEIF
cascade assigns each member a single primary reason (ESRD/transplant takes precedence), so
categories sum to the unique total of 57 rather than the raw flag counts (50 + 8 = 58).
This is disclosed; real HEDIS exclusions are non-mutually-exclusive.

**Improvement opportunity.** The 142 measured-uncontrolled members are split by failure
reason (systolic high / diastolic high / both / no reading) and ranked by potential
rate-lift (members in category ÷ 408 measured). This reframes the worklist as a
prioritization tool: closing the largest category yields the biggest rate gain. Validated
that the four categories sum to 142 after applying the Excluded=False filter (an off-by-13
overcount was traced to excluded members leaking into the count and corrected).
