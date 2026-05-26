# CBP Project — Environment Setup & Data Generation Log (macOS)

A step-by-step record of everything done in the Terminal to get from a fresh
MacBook Air to a verified synthetic dataset ready for BigQuery. For each step:
**what** was run, **why**, and **how we confirmed** it worked.

Platform: MacBook Air (Apple Silicon), macOS, zsh shell.
Goal of this phase: install the toolchain and generate verified Synthea CSV data.

---

## Summary table

| # | Step | Command (essence) | Why | How we confirmed it worked |
|---|------|-------------------|-----|----------------------------|
| 1 | Install Homebrew | `/bin/bash -c "$(curl -fsSL .../install.sh)"` | Package manager; makes installing Java/SQLite one-liners on macOS | Installer ended with success; later `brew --version` returned a version |
| 2 | Put Homebrew on PATH | `eval "$(/opt/homebrew/bin/brew shellenv)"` + append to `~/.zprofile` | On Apple Silicon, brew lives in `/opt/homebrew`; this makes the `brew` command resolve now and in future sessions | `brew --version` printed `Homebrew 4.x` |
| 3 | Install Java 17 (JDK) | `brew install openjdk@17` | Synthea is a Java program; NCQA-style work needs a stable LTS Java (11 or 17) | `brew list openjdk@17` showed it was installed |
| 4 | Link Java so macOS finds it | `sudo ln -sfn /opt/homebrew/opt/openjdk@17/.../openjdk.jdk /Library/Java/JavaVirtualMachines/openjdk-17.jdk` + PATH export | Homebrew installs openjdk "keg-only" (not auto-wired into the system), so macOS couldn't locate a runtime until linked | `java -version` returned `openjdk version "17.0.19"` |
| 5 | Create project folder | `mkdir -p ~/cbp_project/synthea && cd ~/cbp_project/synthea` | Keep all project assets in one predictable location | `pwd` / folder created without error |
| 6 | Download Synthea | `curl -L -o synthea-with-dependencies.jar <github release>` | The single JAR *is* Synthea — no install needed once Java is present | `ls -lh` showed a 188 MB file (full JAR, correct size) |
| 7 | Generate synthetic data | `java -jar synthea-with-dependencies.jar -s 12345 -cs 6789 -p 3000 -r 20251231 --exporter.csv.export=true ... Texas` | Produce reproducible, MY-2025-anchored synthetic patients in CSV for the measure engine | Synthea printed "You've just generated 3280 patients!" |
| 8 | Confirm CSV outputs | `ls -la output/csv/` | Verify the files the SQL will consume actually exist | Saw `patients.csv`, `conditions.csv`, `encounters.csv`, `observations.csv`, `payer_transitions.csv` |
| 9 | Verify hypertension code | `grep -i "hypertens" conditions.csv \| head -5` | The denominator filter depends on the exact diagnosis code; never trust an assumed code | All rows showed SNOMED `59621000` "Essential hypertension" — matches the script |
| 10 | Inspect encounters schema | `head -1 encounters.csv` | The denominator joins conditions→encounters; need exact column names (`Id`, `START`, `PATIENT`) | Header confirmed `Id,START,STOP,PATIENT,...` |
| 11 | Confirm dx→encounter linkage | `grep "59621000" conditions.csv \| awk -F',' '{print $4}'` | The two-different-dates rule only works if each HTN condition carries a valid ENCOUNTER id | All five rows returned populated encounter UUIDs (no blanks) |

---

## The reasoning, expanded

**Why Homebrew (steps 1–2).** macOS doesn't ship a package manager. Homebrew lets us
install Java with one command instead of hunting installers. On Apple Silicon it installs
to `/opt/homebrew`, which isn't on the default PATH, so step 2 wires it in — both for the
current session (`eval ...`) and permanently (appending to `~/.zprofile`).

**Why Java, and why the linking step (steps 3–4).** Synthea runs on the Java Virtual
Machine. We used the LTS release (Java 17) because Synthea's maintainers warn that
non-LTS Java versions can cause issues. The subtlety: Homebrew installs `openjdk@17`
"keg-only," meaning it deliberately does *not* register it as the system Java. That's why
`java -version` first reported "Unable to locate a Java Runtime" even though the JDK was
installed — the fix was the symlink in step 4, which tells macOS where the JDK lives.

**Why these Synthea flags (step 7).** `-s` and `-cs` fix the random seeds so the dataset
is **reproducible** — anyone re-running gets the same patients, which matters for a
defensible portfolio piece. `-p 3000` sizes the population so the hypertensive 18–85
subset is large enough for a credible rate. `-r 20251231` anchors the simulation to the
end of **Measurement Year 2025**, the current HEDIS MY, so ages and date windows align
with the spec we're building to. The `--exporter` flags switch output to CSV (off by
default) and disable FHIR/C-CDA, which we don't need.

**Why the three verification checks (steps 9–11).** These are the difference between
"hoping the code works" and "knowing the data supports the code." The denominator logic
hinges on three facts: the hypertension diagnosis code, the encounters table structure,
and whether diagnoses actually link to encounters. We confirmed all three directly against
the generated data *before* writing the warehouse logic, so the SQL rests on verified
assumptions rather than guesses.

---

## Things that went wrong (and how we handled them) — worth being able to describe

- **Homebrew install first failed** with `Unrecognized option: 'We'`. Cause: stray
  surrounding text got copied into the command. Fix: pasted only the exact command.
  *Lesson worth stating: read the error — it named the offending token, which pinpointed
  a paste problem, not a system problem.*
- **Password prompt looked frozen.** Terminal hides password input entirely (no dots/
  cursor). It was working; we just typed blind and pressed Return.
- **`java -version` couldn't find Java** despite a successful install. Root cause was the
  keg-only linking issue above; resolved with the symlink + PATH export.

---

## State at end of this phase

- Toolchain installed and verified: Homebrew, Java 17.
- Reproducible synthetic dataset generated: ~3,280 patients, CSV format, MY-2025 anchored.
- Data assumptions verified: HTN code `59621000`, encounters schema, condition→encounter linkage.

## Next phase (not yet done — happens in BigQuery, not Terminal)
1. Create Google Cloud project + `hedis_cbp` dataset.
2. Load the five CSVs (Console UI upload, Auto-detect schema).
3. Run `02_cbp_denominator_bigquery.sql` to build the denominator.
4. Run sanity-check queries to confirm the eligible population count.
5. (Then) Step 2 — numerator + exclusions + funnel output for Tableau.
