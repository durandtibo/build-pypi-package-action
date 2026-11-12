# Target state for `build-pypi-package-action`

Review of `main` at `088d6fc`. It replaces the earlier review (written against `fb41eaf`), most of
whose proposals are now implemented. Breaking changes are accepted: the last release is `v0.0.2`
and `v1.0.0` has not been tagged, so everything below can ship in `v1.0.0` at no cost to users.

Nothing in this document has been implemented. The action can only be exercised end to end on
GitHub Actions. Claims marked **(verified locally)** were checked with `uv 0.13.7` on macOS;
claims marked **(confirm in CI)** need a GitHub run.

## 1. Properties of the action

The target state must satisfy all of these. Section 6 checks each one against the proposal.

| #   | Property           | Definition                                                                                                                                                                                                             |
| --- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Single purpose** | Build one package (sdist + wheel) from the repo root with `uv`, prove it is safe to publish, and hand `dist/` to a later publish job as an artifact. It never publishes, signs, or runs the package's own tests.       |
| P2  | **Fail closed**    | A check that cannot positively conclude "safe" fails the job. A network error or 5xx from PyPI fails; an ambiguous import name fails; nothing is guessed.                                                              |
| P3  | **Ground truth**   | Name and version come from the built wheel, never from a second parser of `pyproject.toml`. Guards check what will be uploaded.                                                                                        |
| P4  | **Reproducible**   | Every tool the action installs is pinned: `uv`, `twine` and, as far as `uv` allows, twine's dependencies. No cache is read or written. Only `setup-uv` and `upload-artifact` are third-party actions, pinned to SHAs.  |
| P5  | **Fast**           | Local checks run before network checks; nothing is built, installed or parsed twice. The slow work (build, dependency install) happens once.                                                                           |
| P6  | **Simple**         | All logic is inline in `action.yml`. Three inputs, two outputs plus one diagnostic. Each step is readable alone.                                                                                                       |
| P7  | **Portable**       | Same behaviour on Linux, macOS and Windows (Git Bash). Only `bash`, `curl`, `uv` and what `uv` installs are assumed.                                                                                                   |
| P8  | **Safe to chain**  | `dist/` holds exactly one wheel and one sdist, so a publish job can upload the directory as is.                                                                                                                        |
| P9  | **Secure**         | Inputs and step outputs reach scripts through `env:` only. `contents: read` is enough. No `id-token`, no attestation, no secret in the build job.                                                                      |
| P10 | **Tested**         | Every guard has a fixture proving it fails for the expected `failed-check` id, or is listed as an explicit review-only exception. A check that no fixture can fail does not exist. Tests are written once, not twice.  |
| P11 | **Fail loudly**    | A failure says what failed, why, the values involved, and how to fix it, in an annotation and in the job summary. The `failed-check` output names the check; it is `unexpected` when something outside a check failed. |
| P12 | **Small steps**    | One purpose and one failure id per step, named `N.x` by topic (`0.x` setup, `1.x` build and package checks, `2.x` release guards, `3.x` smoke tests, `4.x` report and upload). Adding a check touches one place.       |

## 2. What is good and stays

- **Wheel-derived metadata** (name, version, canonical name). No extra parser, no extra action.
- **Isolated smoke test**: `uv run --isolated --no-project --with <wheel>` plus `python -I`, so the
  source tree cannot mask a broken artifact.
- **`uv build --clear --no-sources`** and the default `uv build` behaviour (see F2: the wheel is built
  _from_ the sdist).
- **Fail-closed PyPI duplicate check** (only 404 passes, retries, timeout, PEP 503 name).
- **Whitelist for manual runs** (pre-release only) and the strict `v` + version tag rule.
- **`fail` helper**: annotation + job summary + exit, one line per check.
- **Pinned `twine`**, SHA-pinned actions, `permissions: {}` plus per-job least privilege, `timeout-minutes`
  everywhere, `env:` for every input.
- **Case-table tests** with `assert_failed_check` on ids, never on message text.
- **No `working-directory`, no publishing, no attestation, no project test run.** See section 7.

## 3. Findings

Ordered by value. "Verified" means checked, not assumed.

### F1. `uv` itself is not pinned (violates P4)

`astral-sh/setup-uv` is called without `version:`, so every release build runs whatever `uv` is
newest that day. The action pins `twine` and the actions but not the tool that does the build, the
resolution and every smoke test. A `uv` regression or behaviour change lands in a release build
unannounced. `twine@7.0.0` is pinned but its dependencies (`requests`, `readme-renderer`,
`urllib3`, ...) float, so pinning twine does not make `twine check` reproducible.

**Fix:** set `version: "<x.y.z>"` on `setup-uv` and bump it in the same quarterly PR as `twine`.
Resolve twine with `uvx --exclude-newer <date> twine@<x.y.z>`; **(verified locally)** `uvx` accepts
the flag and resolves twine's dependencies as of that date. Scope it to twine only: applying it
globally would block the user's own build requirements.

### F2. The sdist smoke test (3.3) and the wheel/sdist comparison (1.6) cannot fail independently (violates P5, P10)

`uv build` builds the sdist and then builds the wheel _from that sdist_ **(verified locally: the log
says `Building wheel from source distribution...`)**. Consequences:

- Step 3.3 rebuilds the sdist from scratch in a clean environment, which is the most expensive step
  of the action for packages with heavy build dependencies. It proves nothing that 1.1 plus 3.2
  have not proven: if the wheel built from the sdist imports, the sdist is complete.
- Step 1.6 compares name and version of two artifacts where one was derived from the other.
- Neither `smoke-sdist` nor `artifact-mismatch` has a row in the `reject` table today. No fixture
  can exist for them, which breaks P10.

**Fix:** delete 3.3 and 1.6; drop `smoke-sdist` and `artifact-mismatch` from `failed-check`. Keep the
sdist content checks (unwanted files, size), which read the sdist without building it. State the
reason in the README so the removal reads as a design choice, not a loss.

### F3. Import-name detection guesses (violates P2)

Step 1.4 concatenates `top_level.txt`, packages and modules, then takes `found[0]`. Wheels from
hatchling, flit and `uv_build` have no `top_level.txt`, so the pick is the alphabetically first
top-level directory with an `__init__.py`. A wheel that also ships `docs/`, `examples/` or `tests/`
packages (a common packaging slip) is smoke-tested on the wrong module, and passes. `pyyaml` ships
`_yaml` and `yaml`; the first one listed wins. The check passes while testing the wrong thing, which
is the fail-open case P2 forbids.

**Fix:** resolve in one place (3.1 today, moved into `1.x` because it is a cheap local check):

1. `import-name` input, if set.
2. Candidates = top-level packages and modules of the wheel. Drop names starting with `_` if any
   other remains.
3. If the normalized distribution name (`-`/`.` to `_`, lowercase) is a candidate, use it.
4. Else if there is exactly one candidate, use it.
5. Else fail `import` and list the candidates: `Candidates: docs, mypkg. Set import-name.`

### F4. `failed-check` is maintained in two places and misses unexpected failures (violates P12, P11)

Each check needs a step `id` equal to its failure id **and** a term in a 15-term `||` expression in
`outputs.failed-check`. Forgetting the second part makes the check fail with an empty
`failed-check`, which the tests read as "no check failed". A failure outside the checks (`setup-uv`
download, `uv` crash, `upload-artifact`) also leaves it empty, indistinguishable from success.

**Fix:** `fail` writes the id to `${RUNNER_TEMP}/failed-check`; a last step with `if: failure()`
publishes it. The output expression becomes one term.

```yaml
outputs:
  failed-check:
    description: Id of the failed check, "unexpected" if another step failed, empty on success
    value: ${{ steps.report.outputs.failed-check }}
# ...
- name: 4.3 Report failed check
  id: report
  if: failure()
  shell: bash
  run: echo "failed-check=$(cat "${RUNNER_TEMP}/failed-check" 2>/dev/null || echo unexpected)" >> "$GITHUB_OUTPUT"
```

Step 0.2 also runs `rm -f "${RUNNER_TEMP}/failed-check"` so a second use of the action in the same
job cannot read a stale id. Step `id`s are then only needed where a later step reads an output
(`inspect`). **(confirm in CI)** that a composite step with `if: failure()` runs after a failed
`run:` step and that the caller's `steps.<id>.outputs.failed-check` is set under
`continue-on-error: true`. The current design already relies on the second part.

### F5. The wheel is opened and parsed four times (violates P5, P12)

Steps 1.4, 1.5, 1.6 and 1.7 each start `uv run --no-project python -I -` and repeat the same
`zipfile` + `email.parser` boilerplate. That is four `uv` starts and four interpreter starts on the
success path (the slowest on Windows), and the same code copied four times.

**Fix:** one step, `1.3 Inspect distributions`, that only extracts facts and passes no verdict.
It prints `key=value` lines to `$GITHUB_OUTPUT`. Small bash steps then decide and call `fail`:

| Output           | Used by               |
| ---------------- | --------------------- |
| `name`           | outputs, 3.2, summary |
| `version`        | outputs, 2.x, summary |
| `canonical-name` | 2.4                   |
| `missing`        | 1.4 `metadata-fields` |
| `candidates`     | 1.5 `import`          |
| `unwanted`       | 1.6 `unwanted-files`  |

Step 1.3 is the one allowed exception to "about 15 lines" (about 25 lines of Python: data
extraction only, no policy). All policy stays in the small bash steps, so each check can still be
read and changed alone.

### F6. Tool order: network checks come before local ones (P5)

`twine` (needs a `uvx` download) runs before the cheap local checks. Success-path time is the same;
failure latency is not: a package with a secret file waits for the twine download first. Move
`twine` to the end of `1.x`, after the local checks.

### F7. Smaller points

- **Dead Dependabot config.** `.github/dependabot.yml` has `pip` and `uv` ecosystems at `/`, but
  the repo has no root `pyproject.toml`, `uv.lock` or requirements file. Only `github-actions`
  does anything. Remove the other two.
- **`bot-sync-shared-makefile.yaml` interpolates `${{ secrets.CI_BOT_EMAIL }}` in a `run:`.** Same
  rule as the action's: pass it through `env:`.
- **`bot-pin-action.yaml`** has a comment ("Version pinned so a `prettier` release...") that
  describes nothing in that step. Fix or delete.
- **Upload compression.** Wheels and sdists are already compressed; `compression-level: 0` on
  `upload-artifact` saves CPU for nothing lost.
- **`fail` does not escape annotations.** `%`, `\r` and `\n` in `::error::` text need `%25`, `%0D`,
  `%0A`. Values come from file names, so use `${msg//%/%25}` style escaping in the helper (3 lines).
- **`build` failure text blames the backend only.** `uv build` also fails when the default
  `python-version` is outside the package's `requires-python`. Add that to the "how to fix" text:
  "or set python-version to one the package supports".
- **README and CLAUDE.md** mention `smoke-sdist`, `artifact-mismatch` and the 15 ids; both change
  with F2 and F4.

### F8. The test suite is two 400-line copies (violates P10 "written once")

`ci-action.yaml` (428 lines) and `nightly-test-released.yaml` (405 lines) differ only by the
`uses:` line, the `legacy-invoke/` staging, and which rows exist. Every new case is a copy-paste
into two files, and the release procedure says "add the missing rows" by hand. The `uses:` value
cannot be an expression, which is why the files were split.

**Fix, in two stages:**

1. **Now:** move the case tables to `test/cases.json` (one list per job: `accept`, `reject`,
   `reject-manual`, `reject-tag-mismatch`), each row with `"released": true|false`. A first job
   (`cases`, `ubuntu-slim`) reads the file with `jq` and outputs the matrices; the nightly job
   filters on `released`. A new case is one row in one file. At release time, the step "add the
   rows" becomes "flip `released` to `true`".
2. **After the next release** (which no longer needs `legacy-invoke/` or `SHA256SUMS`): collapse
   both files into one reusable `ci-action.yaml` with an input `released: boolean`. Each job holds
   two action steps, `uses: ./` with `if: !inputs.released` and `uses: durandtibo/...@<sha>` with
   `if: inputs.released`, read through `steps.local.outputs.x || steps.released.outputs.x`.
   `nightly-test-released.yaml`, `legacy-invoke/` and the `assert_released_*` helpers are deleted.
   The release bump becomes one `uses:` line per job in one file.

## 4. Target design

### 4.1 Interface

| Kind   | Name              | Notes                                                                                  |
| ------ | ----------------- | -------------------------------------------------------------------------------------- |
| input  | `python-version`  | Default `3.14`. Used for build and smoke tests. Unchanged.                             |
| input  | `artifact-name`   | Default `dist`. Unchanged.                                                             |
| input  | `import-name`     | Default: resolved by the rule in F3. Unchanged name, stricter default.                 |
| output | `package-name`    | `Name` of the wheel. Unchanged.                                                        |
| output | `package-version` | Normalized version of the wheel. Unchanged.                                            |
| output | `failed-check`    | Id of the failed check, `unexpected` for any other failure, empty on success. Changed. |

No input or output is added or renamed. `failed-check` gains the value `unexpected` and loses the
ids `smoke-sdist` and `artifact-mismatch`. This is the only breaking interface change; the other
breaking changes are behavioural (F2, F3).

### 4.2 Steps (20 steps, was 21)

| Step | Name                               | Id / failure id           | Change vs. today                                  |
| ---- | ---------------------------------- | ------------------------- | ------------------------------------------------- |
| 0.1  | Install uv                         |                           | `version:` pinned (F1)                            |
| 0.2  | Define failure helper              |                           | writes `failed-check` file, escapes, `rm -f` (F4) |
| 1.1  | Build package                      | `build`                   | message mentions `python-version` (F7)            |
| 1.2  | Check dist contents                | `dist-contents`           | unchanged                                         |
| 1.3  | Inspect distributions              | `inspect`                 | **new**, replaces 1.4-1.7's Python (F5)           |
| 1.4  | Check required metadata fields     | `metadata-fields`         | bash only, reads `missing`                        |
| 1.5  | Resolve import name                | `import`                  | moved from 3.1, new rule (F3)                     |
| 1.6  | Check no unwanted files            | `unwanted-files`          | bash only, reads `unwanted`                       |
| 1.7  | Check file sizes                   | `size`                    | unchanged                                         |
| 1.8  | Warn on platform-specific wheel    |                           | unchanged                                         |
| 1.9  | Check package metadata (twine)     | `twine`                   | moved last in `1.x`, `--exclude-newer` (F1, F6)   |
| 2.1  | Check version has no local segment | `local-version`           | unchanged                                         |
| 2.2  | Check manual run is a pre-release  | `manual-version`          | unchanged                                         |
| 2.3  | Check tag matches version          | `tag`                     | unchanged                                         |
| 2.4  | Check version not on PyPI          | `published`               | unchanged                                         |
| 3.1  | Smoke test wheel                   | `smoke-wheel`             | renumbered                                        |
| 3.2  | Smoke test entry points            | `entry-points`            | renumbered                                        |
| 4.1  | Write job summary                  |                           | unchanged                                         |
| 4.2  | Upload distributions               |                           | `compression-level: 0` (F7)                       |
| 4.3  | Report failed check                | `report`, `if: failure()` | **new** (F4)                                      |

Removed: old 1.6 `artifact-mismatch`, old 3.3 `smoke-sdist` (F2).

Python invocations on the success path: 1 inspect + 2 smoke tests, down from 4 + 3.

### 4.3 Reference sketches

Untested; written to show the shape, not to paste. Confirm in CI.

`0.1`:

```yaml
- uses: astral-sh/setup-uv@<sha> # ratchet:astral-sh/setup-uv@<tag>
  with:
    version: "0.13.7" # bump with twine, quarterly, in its own PR
    python-version: ${{ inputs.python-version }}
    enable-cache: false
```

`0.2` (the helper):

```bash
rm -f "${RUNNER_TEMP}/failed-check"
cat > "${RUNNER_TEMP}/fail.sh" <<'EOF'
fail() {
  echo "$1" > "${RUNNER_TEMP}/failed-check"
  local msg="$3 How to fix: $4"
  msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/'%0D'}"; msg="${msg//$'\n'/'%0A'}"
  echo "::error title=$2::${msg}"
  printf '### :x: %s\n\n%s\n\n**How to fix:** %s\n' "$2" "$3" "$4" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}
EOF
```

`1.3` (facts only):

```bash
uv run --no-project python -I - dist/*.whl dist/*.tar.gz >> "$GITHUB_OUTPUT" <<'PY'
import re, sys, tarfile, zipfile
from email.parser import Parser
BAD = re.compile(r"(^|/)(\.env(\.(?!example$|sample$|template$)[^/]*)?|\.git|\.pypirc|id_(rsa|ed25519)|[^/]*\.pem|__pycache__|\.DS_Store)(/|$)|\.pyc$")
with zipfile.ZipFile(sys.argv[1]) as z:
    names = z.namelist()
    meta = Parser().parsestr(z.read(next(n for n in names if n.endswith(".dist-info/METADATA"))).decode())
sdist = tarfile.open(sys.argv[2]).getnames()
tops = {n.split("/")[0] for n in names if n.count("/") == 1 and n.endswith("/__init__.py")}
tops |= {n[:-3] for n in names if "/" not in n and n.endswith(".py")}
print(f"name={meta['Name']}\nversion={meta['Version']}")
print(f"canonical-name={re.sub(r'[-_.]+', '-', meta['Name']).lower()}")
print("missing=" + ",".join(k for k in ("Summary", "Requires-Python") if not meta[k]))
print("candidates=" + ",".join(sorted(tops)))
print("unwanted=" + ",".join(sorted({n for n in names + sdist if BAD.search(n)})))
PY
```

On Windows, add `| tr -d '\r'` as today (`uv`'s Python prints `\r\n` under Git Bash).
`top_level.txt` is no longer read: it is a setuptools artifact, and the directory scan agrees with
it for every layout that imports.

`1.5` (resolution; ambiguity fails closed):

```bash
source "${RUNNER_TEMP}/fail.sh"
IFS=, read -ra c <<< "${CANDIDATES}"
pick="${IMPORT_NAME}"
if [[ -z "${pick}" ]]; then
  public=(); for m in "${c[@]}"; do [[ "${m}" == _* ]] || public+=("${m}"); done
  (( ${#public[@]} )) && c=("${public[@]}")
  own="${CANONICAL_NAME//-/_}"
  for m in "${c[@]}"; do [[ "${m}" == "${own}" ]] && pick="${m}"; done
  [[ -n "${pick}" || ${#c[@]} -ne 1 ]] || pick="${c[0]}"
fi
[[ -n "${pick}" ]] || fail import "Import name is ambiguous" \
  "Top-level modules in the wheel: ${CANDIDATES:-none}; none matches ${CANONICAL_NAME}." \
  "Set the import-name input."
echo "module=${pick}" >> "$GITHUB_OUTPUT"
```

`1.9` (twine, pinned with its dependency snapshot):

```bash
uvx --exclude-newer 2026-10-01 twine@7.0.0 check --strict dist/* || fail twine ...
```

## 5. Tests and repository

### 5.1 Cases

| Change                                     | Test                                                                                                                                                                                                                                                                                                                                            |
| ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Import rule (F3)                           | `accept`: distribution-name match among several modules (`pkg-multi-module`, which ships a `tests/` package too); `accept`: `_`-prefixed plus public module (`yaml`-like). `reject`: `import`, two unrelated modules, no `import-name`.                                                                                                         |
| Removed `smoke-sdist`, `artifact-mismatch` | Delete from the README id list and `CLAUDE.md`; no rows existed.                                                                                                                                                                                                                                                                                |
| `failed-check` report (F4)                 | Existing `reject` rows keep passing (ids unchanged). Add one row `unexpected`: a fixture whose `[project.entry-points]`... is not needed; instead **(confirm in CI)** manually that `python-version: "9.9"` yields `unexpected`. Keep as a documented manual check, not a row (an invalid input is the only trigger and it is not worth a row). |
| `size`                                     | New row: staging hook `stage: oversized` writes 101 MiB of `/dev/urandom` into the fixture before the action runs (a helper in `scripts/test-helper.sh`); expect `size`.                                                                                                                                                                        |
| `dist-contents`                            | **Review-only exception**, like the PyPI outage: no sane backend writes a second wheel.                                                                                                                                                                                                                                                         |
| `published` outage (non-404)               | Review-only exception, unchanged.                                                                                                                                                                                                                                                                                                               |

Every other id keeps its row. The exceptions list lives in `CLAUDE.md` under "Tests", so the
rule "every guard has a fixture" has a closed list of exceptions instead of silent gaps.

### 5.2 Workflow structure

See F8. Target tree after both stages:

```text
.github/workflows/
  ci.yaml                     entry point (unchanged)
  ci-format.yaml              unchanged
  ci-action.yaml              one test suite, input `released: boolean`, matrices from test/cases.json
  ci-verify-workflows.yaml    unchanged
  lib-get-test-matrix.yaml    unchanged
  nightly.yaml                calls ci-action.yaml with released: true
  security-*.yaml, bot-*.yaml minor fixes in F7
test/cases.json               all case rows
test/fixtures/                fixtures (legacy-invoke/ removed)
scripts/test-helper.sh        shared assertions (assert_released_* removed)
```

### 5.3 Documentation

- **README:** update "How it works" (steps, ids), the `failed-check` list and the `unexpected`
  value, the import rule, the sdist rationale ("the wheel is built from the sdist, so importing the
  wheel proves the sdist builds"), the pinned `uv`. Replace "Upgrading from v0.0.x" with the final
  list of breaking changes of `v1.0.0`.
- **CLAUDE.md:** replace the rule "a step that can fail has an `id:` equal to its `failed-check` id
  and is listed in the `failed-check` output expression" with "calls `fail <id> ...`; the report
  step publishes the id". Add `uv` to the quarterly pin review. Add the closed list of review-only
  exceptions. Replace the nightly description with the `released` flag procedure.

## 6. Properties check

| #   | Met by                                                                                                               |
| --- | -------------------------------------------------------------------------------------------------------------------- |
| P1  | No new capability. Two checks removed; none added that exceeds build + prove safe.                                   |
| P2  | Import rule fails on ambiguity (F3). `unexpected` makes non-check failures visible (F4). PyPI check unchanged.       |
| P3  | `inspect` reads the wheel only; the sdist is read for file names. Nothing parses `pyproject.toml`.                   |
| P4  | `uv` pinned, `twine` and its dependencies pinned by date (F1). Caches stay off.                                      |
| P5  | One Python start for facts instead of four; no sdist rebuild; local checks before the `twine` download (F2, F5, F6). |
| P6  | 20 steps, no new input or output, one 25-line data step. No helper script.                                           |
| P7  | `bash`, `curl`, `uv` only. The `\r` strip is kept. `RUNNER_TEMP` files as today.                                     |
| P8  | `1.2` and `4.2` unchanged.                                                                                           |
| P9  | `env:` for every input and output. Permissions unchanged. `bot-sync-shared-makefile.yaml` fixed (F7).                |
| P10 | Closed exception list; `size` and `import` get rows; untestable checks removed (F2); case tables written once (F8).  |
| P11 | `unexpected`; escaped annotations; build message names `python-version` (F4, F7).                                    |
| P12 | Adding a check = one step + one `fail` call. No second place to edit (F4).                                           |

## 7. Considered and rejected

- **Replace `twine check` with `uv publish --dry-run`.** One fewer tool. **(verified locally)**
  `uv publish --dry-run` accepted the `pkg-invalid-metadata` fixture that `twine check --strict`
  rejects (broken reStructuredText in the readme). Keep twine.
- **Merge the wheel import and the entry-point smoke tests into one environment.** Saves one
  `uv run --isolated` start, but they would share one failure id and lose the one-id-per-step rule.
  Dependencies are downloaded once and reused from `uv`'s in-job cache, so the second install only
  links files.
- **Validate trove classifiers before upload.** Would need a pinned `trove-classifiers`
  dependency and a new step. PyPI rejects bad classifiers at upload with a clear 400 on both files,
  so nothing is half-published. Add on request.
- **Build attestations / provenance in this action.** Needs `id-token: write` and
  `attestations: write` in the build job, which breaks P9. `pypa/gh-action-pypi-publish` creates
  attestations in the publish job, where the OIDC token belongs.
- **A `working-directory` input** (monorepos). Every step would need it. Callers can use a job per
  package with `defaults.run.working-directory`. Revisit if requested by more than one user.
- **Configurable tag prefix, retention days or size limit.** No demonstrated need; each is an
  input to document and test.
- **`python-version` default taken from `requires-python`.** Makes the build depend on the runner's
  preinstalled Pythons. An explicit, bumped default is reproducible (P4).
- **Moving the inline Python to a script file in the action.** Adds a second language file and
  makes the action depend on its own checkout path. Revisit only if `action.yml` grows past about
  400 lines (it is 358 today, 330 after this review).
- **Cheap-checks-first across the whole action.** The version, which the guards need, only exists
  after the build, and the build dominates the run. Only the `twine` move (F6) is worth doing.
- **Publishing, signing, `SHA256SUMS`, running the package's tests.** Unchanged from the earlier
  review: outside P1.

## 8. Migration order

One branch and one PR per item, from an up-to-date `main`. The order puts behaviour-preserving
changes first, so a regression is easy to attribute.

1. **Toolchain pins (F1).** `setup-uv` `version`, `twine --exclude-newer`; add `uv` to the
   quarterly review in `CLAUDE.md`. No behaviour change.
2. **`inspect` step (F5) and `twine` last in `1.x` (F6).** Refactor only; all ids and tests
   unchanged. Run the full `ci-action.yaml` on three OSes.
3. **Drop `smoke-sdist` and `artifact-mismatch` (F2).** README, `CLAUDE.md`, `failed-check` docs.
4. **Import rule (F3)** with its fixtures. Breaking for packages that relied on the guess.
5. **`failed-check` report step and `fail` escaping (F4, F7).** **(confirm in CI)** the
   `if: failure()` behaviour first on a throwaway branch.
6. **Small fixes (F7):** dependabot, `compression-level`, `bot-sync-shared-makefile.yaml`,
   `bot-pin-action.yaml` comment, `size` row.
7. **`test/cases.json` (F8 stage 1).**
8. **Release `v1.0.0`** with the README upgrade section; move `v1`; bump the nightly refs.
9. **Collapse the two test workflows (F8 stage 2)**, delete `legacy-invoke/` and `assert_released_*`.

## 9. What was not done

- No change was made to `action.yml`, the workflows or the tests.
- Only these claims were run: the `uv publish --dry-run` comparison, `uvx --exclude-newer`, and the
  `uv build` log line (all on macOS, `uv 0.13.7`). The Python sketches in 4.3 were not executed.
- Nothing was run on Linux or Windows, and nothing was run in GitHub Actions.
