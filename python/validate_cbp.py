#!/usr/bin/env python3
"""
CBP Project — Step 3: Independent validation in pandas
======================================================
Purpose: re-implement the ENTIRE CBP measure from the SAME raw Synthea CSVs that
were loaded into BigQuery, completely independently, and ASSERT that the pandas
results match the BigQuery results. This is the QA / reconciliation layer: two
independent engines agreeing is strong evidence the logic is implemented correctly.

IMPORTANT: This mirrors the SAME documented modeling decisions as the SQL
(encounter-date interpretation of "two diagnoses on different dates"; simplified
continuous enrollment; pregnancy restricted to episodes overlapping the MY). The
goal is implementation fidelity between engines, NOT to re-define the measure.

Measurement Year (MY) = 2025
  Dx identification window: 2024-01-01 .. 2025-06-30
  Numerator BP window:      2025-01-01 .. 2025-12-31
  Age 18-85 as of 2025-12-31
  Control: systolic <= 139 AND diastolic <= 89

Run:
  cd ~/cbp_project
  python3 validate_cbp.py
"""

import sys
import pandas as pd

# ----------------------------------------------------------------------
# 0. CONFIG — paths and parameters (single source of truth)
# ----------------------------------------------------------------------
CSV_DIR = "/Users/gabrielmd/cbp_project/synthea/output/csv"

MY_END          = pd.Timestamp("2025-12-31")
MY_START        = pd.Timestamp("2025-01-01")
DX_WINDOW_START = pd.Timestamp("2024-01-01")
DX_WINDOW_END   = pd.Timestamp("2025-06-30")

HTN_CODE   = "59621000"
SYS_CODE   = "8480-6"
DIA_CODE   = "8462-4"
ESRD_TX_CODES   = {"46177005", "698306007", "161665007", "213150003"}
PREG_CODES      = {"72892002", "198992004", "79586000", "609496007"}

# Expected BigQuery results to assert against
EXPECTED = {
    "eligible_denominator": 465,
    "excluded_members":     57,
    "measured_population":  408,
    "numerator_controlled": 266,
    "cbp_rate_pct":         65.2,
    "ageband": {  # measured, controlled, rate
        "18-44": (65, 38, 58.5),
        "45-64": (234, 146, 62.4),
        "65-85": (109, 82, 75.2),
    },
}


def load(name):
    """Load a Synthea CSV; everything as string first, parse dates explicitly."""
    return pd.read_csv(f"{CSV_DIR}/{name}", dtype=str, low_memory=False)


def whole_year_age(birthdate, anchor):
    """Whole-year age as of anchor date."""
    age = anchor.year - birthdate.year
    if (birthdate.month, birthdate.day) > (anchor.month, anchor.day):
        age -= 1
    return age


def main():
    # ------------------------------------------------------------------
    # 1. LOAD
    # ------------------------------------------------------------------
    patients   = load("patients.csv")
    conditions = load("conditions.csv")
    encounters = load("encounters.csv")
    observations = load("observations_bp.csv")   # BP-filtered file used for BigQuery
    payers     = load("payer_transitions.csv")

    # ------------------------------------------------------------------
    # 2. MEMBERS + age
    # ------------------------------------------------------------------
    patients["BIRTHDATE"] = pd.to_datetime(patients["BIRTHDATE"], errors="coerce")
    patients["age_eoy"] = patients["BIRTHDATE"].apply(lambda b: whole_year_age(b, MY_END))

    def age_band(a):
        if 18 <= a <= 44: return "18-44"
        if 45 <= a <= 64: return "45-64"
        if 65 <= a <= 85: return "65-85"
        return None
    patients["age_band"] = patients["age_eoy"].apply(age_band)

    aged = patients[(patients["age_eoy"] >= 18) & (patients["age_eoy"] <= 85)].copy()

    # ------------------------------------------------------------------
    # 3. HTN members (onset on/before window end) + encounter-date events
    #    (mirrors the documented Synthea adaptation)
    # ------------------------------------------------------------------
    conditions["START"] = pd.to_datetime(conditions["START"], errors="coerce")
    htn = conditions[conditions["CODE"].astype(str) == HTN_CODE].copy()
    htn_onset = htn.groupby("PATIENT")["START"].min().rename("htn_onset")
    htn_members = htn_onset[htn_onset <= DX_WINDOW_END].index   # had HTN by window end

    encounters["START"] = pd.to_datetime(encounters["START"], errors="coerce")
    enc = encounters[["PATIENT", "START"]].copy()
    enc["service_date"] = enc["START"].dt.normalize()
    enc = enc[(enc["service_date"] >= DX_WINDOW_START) & (enc["service_date"] <= DX_WINDOW_END)]
    enc = enc[enc["PATIENT"].isin(htn_members)]

    # distinct encounter dates per member
    events = enc[["PATIENT", "service_date"]].drop_duplicates()

    # two-different-dates rule + anchor = 2nd distinct date
    counts = events.groupby("PATIENT")["service_date"].agg(["count", "min"])
    second_date = (events.sort_values(["PATIENT", "service_date"])
                         .groupby("PATIENT")["service_date"]
                         .nth(1)               # 2nd distinct date (0-indexed -> 1)
                         .rename("anchor_date"))
    qualified = counts[counts["count"] >= 2].join(second_date)
    qualified_members = set(qualified.index)

    # ------------------------------------------------------------------
    # 4. ENROLLMENT (simplified: a payer span covering MY end)
    # ------------------------------------------------------------------
    payers["START_DATE"] = pd.to_datetime(payers["START_DATE"], errors="coerce")
    payers["END_DATE"]   = pd.to_datetime(payers["END_DATE"], errors="coerce")
    enr = payers[(payers["START_DATE"] <= MY_END) &
                 (payers["END_DATE"].fillna(pd.Timestamp("2262-01-01")) >= MY_END)]
    enrolled_members = set(enr["PATIENT"].unique())

    # ------------------------------------------------------------------
    # 5. DENOMINATOR
    # ------------------------------------------------------------------
    denom = aged[aged["Id"].isin(qualified_members) & aged["Id"].isin(enrolled_members)].copy()
    denom = denom.merge(qualified["anchor_date"], left_on="Id", right_index=True, how="left")
    eligible_denominator = len(denom)

    # ------------------------------------------------------------------
    # 6. BP READINGS pivot (systolic/diastolic to one row per member/date)
    # ------------------------------------------------------------------
    observations["DATE"] = pd.to_datetime(observations["DATE"], errors="coerce")
    obs = observations[observations["CODE"].isin([SYS_CODE, DIA_CODE])].copy()
    obs["reading_date"] = obs["DATE"].dt.normalize()
    obs["val"] = pd.to_numeric(obs["VALUE"], errors="coerce")
    obs = obs[(obs["reading_date"] >= MY_START) & (obs["reading_date"] <= MY_END)]

    # same-day tiebreaker = lowest reading -> min per (patient,date,component)
    sys_bp = (obs[obs["CODE"] == SYS_CODE]
              .groupby(["PATIENT", "reading_date"])["val"].min().rename("systolic"))
    dia_bp = (obs[obs["CODE"] == DIA_CODE]
              .groupby(["PATIENT", "reading_date"])["val"].min().rename("diastolic"))
    bp = pd.concat([sys_bp, dia_bp], axis=1).dropna().reset_index()

    # ------------------------------------------------------------------
    # 7. REPRESENTATIVE reading = most recent on/after anchor
    # ------------------------------------------------------------------
    bp = bp.merge(denom[["Id", "anchor_date"]], left_on="PATIENT", right_on="Id", how="inner")
    bp = bp[bp["reading_date"] >= bp["anchor_date"]]
    bp = bp.sort_values(["PATIENT", "reading_date"])
    rep = bp.groupby("PATIENT").tail(1).set_index("PATIENT")   # most recent

    # ------------------------------------------------------------------
    # 8. EXCLUSIONS
    # ------------------------------------------------------------------
    esrd_tx_members = set(conditions[conditions["CODE"].astype(str).isin(ESRD_TX_CODES)]["PATIENT"].unique())

    cond2 = conditions.copy()
    cond2["STOP"] = pd.to_datetime(cond2["STOP"], errors="coerce")
    preg = cond2[cond2["CODE"].astype(str).isin(PREG_CODES)].copy()
    preg = preg.merge(patients[["Id", "GENDER"]], left_on="PATIENT", right_on="Id")
    preg = preg[preg["GENDER"] == "F"]
    # episode overlaps MY: START <= MY_END AND (STOP is null or STOP >= MY_START)
    preg = preg[(preg["START"] <= MY_END) &
                (preg["STOP"].fillna(pd.Timestamp("2262-01-01")) >= MY_START)]
    preg_members = set(preg["PATIENT"].unique())

    # ------------------------------------------------------------------
    # 9. ASSEMBLE member-level results + metrics
    # ------------------------------------------------------------------
    denom["excl_esrd_tx"] = denom["Id"].isin(esrd_tx_members)
    denom["excl_preg"]    = denom["Id"].isin(preg_members)
    denom["excluded"]     = denom["excl_esrd_tx"] | denom["excl_preg"]

    denom = denom.merge(rep[["systolic", "diastolic"]], left_on="Id", right_index=True, how="left")
    denom["has_reading"] = denom["systolic"].notna() & denom["diastolic"].notna()
    denom["bp_controlled"] = denom["has_reading"] & (denom["systolic"] <= 139) & (denom["diastolic"] <= 89)

    measured = denom[~denom["excluded"]]
    excluded_members    = int(denom["excluded"].sum())
    measured_population = int(len(measured))
    numerator_controlled = int(measured["bp_controlled"].sum())
    cbp_rate_pct = round(numerator_controlled / measured_population * 100, 1)

    # by age band
    ageband_results = {}
    for band, g in measured.groupby("age_band"):
        m = len(g); c = int(g["bp_controlled"].sum())
        ageband_results[band] = (m, c, round(c / m * 100, 1) if m else 0.0)

    # ------------------------------------------------------------------
    # 10. RECONCILE vs BigQuery
    # ------------------------------------------------------------------
    print("\n" + "=" * 64)
    print("CBP VALIDATION — pandas vs BigQuery")
    print("=" * 64)
    rows = [
        ("eligible_denominator", eligible_denominator, EXPECTED["eligible_denominator"]),
        ("excluded_members",     excluded_members,     EXPECTED["excluded_members"]),
        ("measured_population",  measured_population,   EXPECTED["measured_population"]),
        ("numerator_controlled", numerator_controlled, EXPECTED["numerator_controlled"]),
        ("cbp_rate_pct",         cbp_rate_pct,          EXPECTED["cbp_rate_pct"]),
    ]
    all_pass = True
    print(f"{'metric':<24}{'pandas':>10}{'bigquery':>12}{'match':>8}")
    print("-" * 64)
    for name, got, exp in rows:
        ok = (got == exp)
        all_pass &= ok
        print(f"{name:<24}{got:>10}{exp:>12}{('OK' if ok else 'FAIL'):>8}")

    print("\nBy age band (measured / controlled / rate):")
    print(f"{'band':<10}{'pandas':>22}{'bigquery':>22}{'match':>8}")
    print("-" * 64)
    for band in ["18-44", "45-64", "65-85"]:
        got = ageband_results.get(band, (0, 0, 0.0))
        exp = EXPECTED["ageband"][band]
        ok = (got == exp)
        all_pass &= ok
        print(f"{band:<10}{str(got):>22}{str(exp):>22}{('OK' if ok else 'FAIL'):>8}")

    print("=" * 64)
    if all_pass:
        print("RESULT: ALL CHECKS PASSED — pandas reproduces BigQuery exactly.")
    else:
        print("RESULT: MISMATCH(ES) FOUND — investigate the FAIL rows above.")
        print("First place to look: same-day reading tie-breaks or anchor edge cases.")
    print("=" * 64 + "\n")

    sys.exit(0 if all_pass else 1)


if __name__ == "__main__":
    main()
