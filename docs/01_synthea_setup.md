# Synthea setup for the CBP project

Measurement Year (MY) chosen: **2025**  (the current HEDIS MY; report year 2026)
- Diagnosis identification window: 2024-01-01 → 2025-06-30
- Numerator BP window: 2025-01-01 → 2025-12-31
- Age check: 18–85 as of 2025-12-31

MY 2025 is fully elapsed (ended Dec 31, 2025), so the data is complete and the rate is
stable. It matches the current NCQA HEDIS MY 2025 specifications you are building to, and
the report year (2026) matches "now" — no spec-vs-period mismatch.

---

## Step 1 — Edit `src/main/resources/synthea.properties`

Change/confirm these lines (search for each key; Synthea ships them set to other values):

```properties
# Turn ON csv output (default is FHIR only)
exporter.csv.export = true

# Keep the output to a single consolidated set of CSVs (one row per record,
# not one folder per patient)
exporter.csv.folder_per_run = false

# Turn OFF the formats you don't need, to keep the run fast and the output small
exporter.fhir.export = false
exporter.ccda.export = false
exporter.text.export = false
exporter.hospital.fhir.export = false
exporter.practitioner.fhir.export = false

# Only export the living/relevant population data we need; keep dead patients
# because HEDIS denominators can include members who died during the year.
exporter.years_of_history = 0          # 0 = full lifetime history (we want full dx history)

# Anchor the simulation so "end of simulation" = end of MY 2025.
# This makes ages and the measurement window line up with MY2025.
generate.reference_date = 20251231
```

Notes:
- `exporter.years_of_history = 0` means "keep full history" — important, because the
  denominator look-back and the ESRD/transplant "any time in history" exclusions need
  the full record.
- If your Synthea version doesn't recognize `generate.reference_date` in the properties
  file, use the `-r` command-line flag instead (shown below) — it does the same thing.

---

## Step 2 — Run command

From the synthea repo root. Generates 3,000 Texas patients with a fixed seed (reproducible),
reference date end-of-MY2025, CSV export on:

```bash
./run_synthea -s 12345 -cs 6789 -p 3000 -r 20251231 \
  --exporter.csv.export=true \
  --exporter.csv.folder_per_run=false \
  --exporter.fhir.export=false \
  --exporter.ccda.export=false \
  Texas
```

Flag meanings (per official usage):
- `-s 12345`   patient seed (reproducibility)
- `-cs 6789`   clinician seed (reproducibility)
- `-p 3000`    population size — sized so the hypertensive 18–85 subset is big enough
               for a credible CBP rate (random prevalence means only a fraction qualify)
- `-r 20251231` reference date = end of measurement year
- `Texas`      state (drives demographics)

CSV output lands in: `./output/csv/`

Windows: use `run_synthea.bat` with the same flags.

---

## Step 3 — Files you'll use

From `./output/csv/`:
- `patients.csv`     → members (Id, BIRTHDATE, DEATHDATE, GENDER, RACE, ETHNICITY)
- `conditions.csv`   → diagnoses (PATIENT, ENCOUNTER, START, STOP, CODE, DESCRIPTION) — SNOMED
- `encounters.csv`   → visits (Id, PATIENT, START, STOP, ENCOUNTERCLASS, CODE)
- `observations.csv` → BP readings (PATIENT, ENCOUNTER, DATE, CODE, VALUE, UNITS) — LOINC
- `payer_transitions.csv` → enrollment spans (PATIENT, START_YEAR/START_DATE, END_YEAR/END_DATE)

## Code reference values (Synthea uses SNOMED/LOINC, NOT ICD-10/CPT)
- Hypertension condition (SNOMED): **59621000** "Essential hypertension"
  (Synthea's hypertension module primarily uses this; verify against your conditions.csv
  with: `SELECT DISTINCT CODE, DESCRIPTION FROM conditions WHERE DESCRIPTION LIKE '%ypertens%'`)
- Systolic BP (LOINC): **8480-6**
- Diastolic BP (LOINC): **8462-4**

>> README CALLOUT: Real HEDIS runs on claims (ICD-10/CPT) and NCQA value sets.
   Synthea emits SNOMED/LOINC. We map clinically-equivalent codes for this demo and
   document the mapping. This is a deliberate, disclosed simplification.
