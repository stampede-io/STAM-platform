# Load-test results

k6 reports live here, one file per run, named `flash-sale-<utc-date>-<git-sha>.{json,txt}`:

- `.json` — `--summary-export` output from k6 (machine-readable metrics)
- `.txt` — captured stdout (human-readable summary + threshold pass/fail)

For a companion narrative + numbers table for each run, see the sibling `.md` file
following the same base name (populated by hand from the JSON — see
`../k6/REPORT_TEMPLATE.md`).

See `../k6/flash-sale.js` for the scenario and `../k6/run-flash-sale.sh` for the
runner (which discovers the show + seat IDs, invokes k6, and runs the DB-level
oversell check as a hard gate).
