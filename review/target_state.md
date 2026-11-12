# Target state for `build-pypi-package-action`

Review of the repository at `fb41eaf`, with a proposed target state. Breaking changes are accepted
where they improve the end state. Nothing in this document has been implemented or run; the action
can only be exercised on GitHub Actions.

## 1. Properties of the action

These are the properties the target state must satisfy. Each one is checked against the proposal in
section 5.

| #   | Property              | Definition                                                                                                                                                                                                              |
| --- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Single purpose**    | Build one Python package (sdist + wheel) from the repo root with `uv`, prove it is safe to publish, and hand `dist/` to a later publish job as an artifact. It never publishes, signs, or tests the package's own code. |
| P2  | **Fail closed**       | Any check that cannot positively conclude "safe" fails the job with a clear `::error::` message. This includes a network error or a 5xx while querying PyPI, not only a definite "already published".                   |
| P3  | **Ground truth**      | Name and version come from the built artifact, not from a second parser of `pyproject.toml`, so static and dynamic versions behave identically and the guards check what will actually be uploaded.                     |
| P4  | **Minimal trust**     | No third-party action beyond `setup-uv` and `upload-artifact`. Every tool version is pinned. No caches are written (a release build must not consume or poison a cache). Needs only `contents: read`.                   |
| P5  | **Fast**              | Cheap checks run before slow ones. Few steps (each step costs a shell start). Nothing is installed or computed that is not used.                                                                                        |
| P6  | **Simple**            | All logic stays inline in `action.yml`; about five steps; two inputs plus one optional; two outputs plus one diagnostic. No separate script.                                                                            |
| P7  | **Portable**          | Identical behaviour on Linux, macOS, and Windows (Git Bash) runners. No dependency on `sha256sum`, `shasum`, or other platform-specific tools.                                                                          |
| P8  | **Safe to chain**     | `dist/` contains exactly the files that PyPI accepts (one wheel, one sdist) so the publish job can upload the directory as is.                                                                                          |
| P9  | **Secure by default** | Inputs and outputs go through `env:`, never `${{ }}` in `run:`. Third-party actions are pinned to SHAs with `# ratchet:` comments. The build job needs no `id-token`.                                                   |
| P10 | **Tested, cheaply**   | Every guard has a fixture that proves it fails for the expected reason. The two copies of the test suite are collapsed into one; CI cost and maintenance are proportional to the action's size.                         |

## 2. Current state: what is good

- Guards are in the right place conceptually (manual-run, tag/version, duplicate, smoke test).
- Smoke test installs the artifact in an isolated environment (`--isolated --no-project`, `python -I`),
  so the source tree cannot mask a broken package. Keep this.
- `uv build --clear` prevents stale files in `dist/`.
- Inputs flow through `env:`, third-party actions are SHA-pinned, workflows use `permissions: {}`
  with per-job least privilege, and the workflow split by role is clear.

## 3. Findings

Ordered by importance.

### F1. The duplicate check fails open (violates P2) — bug

```bash
status=$(curl -s -o /dev/null -w "%{http_code}" ".../json")
if [[ "$status" == "200" ]]; then fail; fi
```

`curl -s` returns `000` on a DNS/TLS/timeout error and the script treats that, and every 5xx or
429, as "not published". During a PyPI incident the guard silently passes, which is exactly when a
duplicate upload is most likely to confuse things. It also has no timeout or retry, and uses the
unnormalised name (`My_Package` vs `my-package`).
**Fix:** only `404` means "not published", `200` fails, anything else fails with "could not verify".
Normalise the name (PEP 503), set `--max-time`, and use a few `--retry` attempts.
**Test:** the fixture suite cannot simulate an outage, so the logic is kept to one small `case`
statement that is reviewed, not tested. (See section 7, rejected ideas.)

### F2. Metadata comes from a third-party action and a second parser (violates P3, P4)

`durandtibo/extract-pyproject-metadata-action` re-reads `pyproject.toml`. It is an extra
supply-chain dependency in the most sensitive workflow of a package, an extra step, and it can
disagree with what was built (for example a dynamic version, or a name that the backend
normalises). The wheel's `*.dist-info/METADATA` is the truth that PyPI will see.
**Fix:** read `Name` and `Version` from the built wheel with a six-line Python snippet run by the
`uv` that is already installed. The guards then compare against the exact version being uploaded.

### F3. Smoke test guesses the import name (correctness)

`MODULE_NAME=$(echo "$PACKAGE_NAME" | tr '.-' '_')` only works when the module is named after the
distribution. It wrongly fails for `pyyaml` (`yaml`), `scikit-learn` (`sklearn`), `pillow` (`PIL`),
namespace packages (`google-cloud-x`), and so on. The README documents this as a requirement,
which turns a tool limitation into a user constraint.
**Fix:** new optional input `import-name`. Default: derived from the wheel's `top_level.txt` or,
when it is absent, from the first path component of `RECORD` that is a package (same snippet as F2).
Explicit value wins. Keep the fallback derivation simple: if nothing is found, fail closed with a
message that asks for `import-name`.

### F4. The `SHA256SUMS` file is inside `dist/` (violates P8; also P6, P7)

`pypa/gh-action-pypi-publish` and `twine upload` take the whole of `dist/`, and the README tells
users to publish exactly that directory. A file that is not a distribution inside it is a risk
(depending on the version of the publish tooling it is warned about, ignored, or rejected). It
also needs a `sha256sum`/`shasum` fallback, a `cd`, and four assertions in the test helper.
The checksum adds almost no security: the artifact is already integrity-protected by
`upload-artifact` (content digest) between jobs, and PyPI computes its own hashes and, with
trusted publishing, signs attestations. Checksums for GitHub Releases are the release job's
concern, not this action's (P1).
**Fix:** remove checksum generation and the checksum assertions. Breaking change: the artifact
contains the wheel and the sdist only.

### F5. `setup-uv` is configured for more than needed (P4, P5)

- `activate-environment: true` creates a virtualenv nobody uses: `uv build`, `uv run --isolated`
  and `uvx` do not need it.
- The default `enable-cache` is on for GitHub-hosted runners: the release build restores and saves a
  cache. A restore can feed a poisoned cache into the artifact that will be published; the save is
  wasted time because the dependency set is tiny. Set `enable-cache: false`.
- `python-version` already sets `UV_PYTHON`; the extra `--python` and `PYTHON_VERSION` env in the
  smoke test are redundant.

### F6. Step layout is wasteful and the order is not fail-fast (P5, P6)

There are 10 steps and 8 shell starts for what is one logical "validate" phase. The slow smoke test
(installs, sdist rebuild) runs after cheap checks, which is right, but `twine` and the PyPI query
are separated by the third-party action step. Merge the checks into one step (see 5.2). That also
lets one `fail()` function write both the message and the machine-readable reason (F10).

### F7. `uvx twine` is unpinned (P4)

An unpinned `uvx twine` resolves to whatever is newest at build time: non-reproducible, and a new
`twine` release can break (or compromise) a release build without a change in this repo.
**Fix:** pin it (`uvx twine@<x.y.z>`) in one place; Dependabot/bot-pin-action cannot see it, so add
a comment `# bump with the quarterly review` or use a `uv tool` pin file. Keep it simple: a pinned
version in the script and a line in CLAUDE.md.

### F8. The manual-run guard is a blacklist (P2)

It rejects versions that match `^[0-9]+(\.[0-9]+)*$`. A `1.2.3.post1` or `1.2.3+local` passes as
"pre-release". Make it a whitelist: after PEP 440 normalisation, a manual run must contain a
`a`, `b`, `rc`, or `.dev` segment. Because the version now comes from the wheel (F2), it is already
normalised, so a regex is enough: `(a|b|rc)[0-9]+|\.dev[0-9]+`.

### F9. Tag guard compares unnormalised strings (P2, P3)

`"${TAG#v}" != "$VERSION"`: a tag `v1.0.0-rc1` is rejected although the normalised version is
`1.0.0rc1`. That is arguably right (the convention is `vX.Y.Z[...]` with the normalised form), but
it is accidental. State it as the rule: **the tag must be exactly `v` + the normalised version**.
Keep the logic; make the error message say so, and document it.

### F10. Failure tests cannot tell the guards apart (P10)

After a failure the tests only know "the action failed" plus whether `dist/SHA256SUMS` exists. The
four guards all fail after the build and before the checksums, so e.g. a plain-version fixture would
also pass the test if the duplicate check (or `twine`) failed instead. This breaks the rule
"assert that the action fails for the expected reason". Removing checksums (F4) removes even this
weak marker.
**Fix:** one diagnostic output `failed-check` set by the validate step before it exits
(`dist-contents`, `twine`, `manual-version`, `tag`, `published`, `import`), asserted by the tests.
The smoke test step is separate, so its failure is identified by `failed-check` being empty while
`dist/` exists.

### F11. The test suite exists twice (P10)

`ci-action.yaml` (426 lines) and `nightly-test-released.yaml` (411 lines) are the same jobs with a
different `uses:` ref. Both are needed and have different goals: `ci-action.yaml` tests the code in
the repo (`uses: ./`), `nightly-test-released.yaml` tests the latest released action, so a broken
release or drift in `uv`, `setup-uv`, or PyPI is caught on what users actually run. `uses:` cannot
take an expression, so the copy cannot be removed by parameterising the ref. The cost is that every
new guard needs two edits and the two copies drift. `legacy-invoke/` is a shim that exists only
because the released version is older than the current one.
**Fix:** keep both workflows and reduce the cost of keeping them in sync (F12 matrix, shared
assertions in `scripts/test-helper.sh`, section 5.4). Remove `legacy-invoke/` once the released
version builds with uv directly, as `CLAUDE.md` already says; the next release containing this
review's changes makes the released-version suite run the same fixtures and assertions.

### F12. Tests are one job per case (P10, P5)

About a dozen near-identical jobs: checkout, stage, run, assert. Failure cases are the same job with
different fixture, `event_name`, and expected reason. A matrix expresses that in a table and
makes adding a case a one-line change.

### F13. Smaller points

- `upload-artifact` default is `if-no-files-found: warn`: set `error`.
- `retention-days: 5` is hard-coded. Fine as a default; no input needed (P6). Mention in README.
- `uv build` should pass `--no-sources` so `[tool.uv.sources]` (path or git overrides used for local
  development) cannot make the release build differ from what a PyPI user would build.
- `uv build --out-dir dist` makes the `dist/` contract explicit instead of relying on the default.
- README says "Python 3.14" is the default; this stales silently. Keep the default but state in
  CLAUDE.md that it is bumped with the workflow config.
- README example publishes from the same job that builds. Show the recommended two-job pattern: the
  build job has `contents: read`; the publish job downloads the artifact and is the only one with
  `id-token: write` and the `pypi` environment. This keeps the build code away from the OIDC token.
- Releases: document a floating major tag (`v1`) next to immutable `vX.Y.Z`, and recommend a SHA
  pin in the README example. The current README pins `v0.0.2`, which leaves users without a
  non-breaking update path.

## 4. What stays unchanged

- Composite action, all logic inline in `action.yml`, no separate script (P6).
- Inputs `python-version` (default `3.14`) and `artifact-name` (default `dist`); outputs
  `package-name` and `package-version`.
- The four checks (build contents, metadata via `twine check --strict`, guards, smoke test) and their
  fail-closed behaviour.
- Workflow naming (`ci-*`, `lib-*`, `security-*`, `bot-*`), SHA pinning with ratchet, and the
  `permissions: {}` convention.

## 5. Target design

### 5.1 Interface

| Kind     | Name              | Change                                                                                                                         |
| -------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| input    | `python-version`  | unchanged (default `3.14`)                                                                                                     |
| input    | `artifact-name`   | unchanged (default `dist`)                                                                                                     |
| input    | `import-name`     | **new**, optional. Module imported by the smoke test. Default: detected from the wheel (F3).                                   |
| output   | `package-name`    | unchanged name; now the `Name` field of the built wheel's metadata (not necessarily the `pyproject.toml` spelling, but exact). |
| output   | `package-version` | unchanged name; now the normalised version of the built wheel.                                                                 |
| output   | `failed-check`    | **new**, diagnostic. Empty on success; otherwise the name of the failed check (F10).                                           |
| artifact | content           | **breaking**: wheel + sdist only; no `SHA256SUMS` (F4).                                                                        |

Breaking changes to flag in the release notes: `SHA256SUMS` removed; `package-name` is read from the
wheel; the smoke test no longer requires module name == distribution name.

### 5.2 Steps (5 instead of 10)

```yaml
runs:
  using: composite
  steps:
    - name: Install uv
      uses: astral-sh/setup-uv@<sha> # ratchet:astral-sh/setup-uv@<tag>
      with:
        python-version: ${{ inputs.python-version }}
        enable-cache: false # a release build must not consume or write a cache

    # --clear: no stale files from earlier builds in the artifact.
    # --no-sources: ignore [tool.uv.sources] so the build matches what PyPI users get.
    - name: Build package
      shell: bash
      run: uv build --clear --no-sources --out-dir dist

    # One step for every check that does not install anything, cheapest first.
    # Each failure records its name in `failed-check` so tests can assert the reason.
    - name: Validate distributions
      id: validate
      shell: bash
      env:
        EVENT_NAME: ${{ github.event_name }}
        REF: ${{ github.ref }}
        REF_NAME: ${{ github.ref_name }}
      run: |
        fail() {
          echo "failed-check=$1" >> "$GITHUB_OUTPUT"
          echo "::error::$2"
          exit 1
        }

        # 1. exactly one wheel and one sdist (the publish job uploads dist/ as is)
        shopt -s nullglob
        wheels=(dist/*.whl)
        sdists=(dist/*.tar.gz)
        [[ ${#wheels[@]} -eq 1 && ${#sdists[@]} -eq 1 ]] ||
          fail dist-contents "Expected one wheel and one sdist in dist/, found ${#wheels[@]} and ${#sdists[@]}"
        [[ $(find dist -mindepth 1 | wc -l) -eq 2 ]] ||
          fail dist-contents "Unexpected files in dist/"

        # 2. metadata renders on PyPI
        uvx twine@<pinned> check --strict dist/* || fail twine "twine check failed"

        # 3. name, version and import name come from the built wheel (not from pyproject.toml)
        read -r name version import_name < <(
          uv run --no-project python -I - "${wheels[0]}" <<'PY'
        import sys, zipfile
        from email.parser import Parser
        with zipfile.ZipFile(sys.argv[1]) as z:
            names = z.namelist()
            meta = Parser().parsestr(z.read(next(n for n in names if n.endswith(".dist-info/METADATA"))).decode())
            top = next((n for n in names if n.endswith(".dist-info/top_level.txt")), None)
            module = z.read(top).decode().split()[0] if top else ""
        print(meta["Name"], meta["Version"], module or "-")
        PY
        )
        { echo "name=${name}"; echo "version=${version}"; echo "import-name=${import_name}"; } >> "$GITHUB_OUTPUT"

        # 4. guards
        if [[ "${EVENT_NAME}" == workflow_dispatch && ! "${version}" =~ (a|b|rc)[0-9]+|\.dev[0-9]+ ]]; then
          fail manual-version "Manual runs need a dev/pre-release version, got ${version}"
        fi
        if [[ "${REF}" == refs/tags/* && "${REF_NAME}" != "v${version}" ]]; then
          fail tag "Tag ${REF_NAME} must be exactly v${version}"
        fi

        # 5. PyPI duplicate check. Only 404 proves "not published": anything else fails closed.
        canonical=$(echo "${name}" | tr '[:upper:]_.' '[:lower:]--' | sed -E 's/-+/-/g')
        status=$(curl --silent --show-error --max-time 20 --retry 3 --output /dev/null \
          --write-out '%{http_code}' "https://pypi.org/pypi/${canonical}/${version}/json" || true)
        case "${status}" in
          404) ;;
          200) fail published "${name} ${version} is already published on PyPI" ;;
          *)   fail published "Could not verify ${name} ${version} on PyPI (HTTP ${status}); failing closed" ;;
        esac

    # Install each artifact in a throwaway environment, without the project, and import
    # it in isolated mode, so the source tree cannot mask a broken artifact.
    - name: Smoke test distributions
      shell: bash
      env:
        IMPORT_NAME: ${{ inputs.import-name || steps.validate.outputs.import-name }}
      run: |
        [[ "${IMPORT_NAME}" != "-" ]] || { echo "::error::Cannot detect the module to import; set the import-name input"; exit 1; }
        for artifact in dist/*; do
          uv run --isolated --no-project --with "${artifact}" -- python -I -c "import importlib, os; importlib.import_module(os.environ['IMPORT_NAME'])"
        done

    - name: Upload distributions
      uses: actions/upload-artifact@<sha> # ratchet:actions/upload-artifact@<tag>
      with:
        name: ${{ inputs.artifact-name }}
        path: dist/
        retention-days: 5
        if-no-files-found: error

outputs:
  package-name:
    value: ${{ steps.validate.outputs.name }}
  package-version:
    value: ${{ steps.validate.outputs.version }}
  failed-check:
    value: ${{ steps.validate.outputs.failed-check }}
```

Notes on the sketch:

- It is a sketch to show the shape, not tested code. The `(a|b|rc)` regex, quoting inside `[[ =~ ]]`,
  heredoc indentation inside YAML, and the `tr` canonicalisation must be verified on all three
  runners (Git Bash on Windows in particular) before merge.
- `shopt` / `read` / process substitution are bash features; every step already sets `shell: bash`.
- The smoke test passes the module name through `env:`, as required (P9).
- Smoke test failures leave `failed-check` empty; the test helper treats "`dist/` exists, no
  `failed-check`" as "smoke test failed".

### 5.3 Why this satisfies the properties

| Property | How                                                                                                        |
| -------- | ---------------------------------------------------------------------------------------------------------- |
| P1       | No publishing, signing, or checksum generation. One job: build, validate, hand over.                       |
| P2       | Whitelist for manual runs, exact tag rule, PyPI check passes only on 404, missing import name is an error. |
| P3       | Name, version and import name read from the wheel that is uploaded.                                        |
| P4       | Two third-party actions instead of three; pinned `twine`; no cache; `contents: read` is enough.            |
| P5       | 5 steps instead of 10; cheap checks before the smoke test; no unused venv, no checksum pass.               |
| P6       | Still one `action.yml`; roughly the same line count as today even though F1, F3 and F8 are fixed.          |
| P7       | No `sha256sum`/`shasum` fallback needed; everything else is `uv`, `bash`, `curl`.                          |
| P8       | `dist/` holds two files and the check enforces it.                                                         |
| P9       | Unchanged rules, enforced for new inputs and the new step.                                                 |
| P10      | See 5.4.                                                                                                   |

### 5.4 Tests

Goal: one case table and one set of shared assertions, used by both test workflows.

- **Keep both** `ci-action.yaml` (current code, `uses: ./`) and `nightly-test-released.yaml` (last
  release, run by `nightly.yaml`); they have different goals (F11). Make them structurally identical
  so that they differ only in the `uses:` line and the staging of the fixtures: same matrices, same
  case table, same assertions from `scripts/test-helper.sh`. A new guard is then a new table row and
  one helper function, applied to both files in the same PR.
- Because the released version lags behind, the released-version suite must only assert behaviour
  that already exists in the release. Cases that depend on a new feature (`failed-check`,
  `import-name`) are added to `nightly-test-released.yaml` after the release that contains them;
  until then it keeps asserting the outcome only. Update the version in its header and `uses:` refs
  at release time, as `CLAUDE.md` says.
- Both workflows keep two kinds of jobs:
  1. `build` (matrix: OS, plus Python version on Linux): success path against `test/fixtures/pkg`.
     Asserts outputs and that `dist/` holds exactly two files.
  2. `reject` (matrix of cases) with `continue-on-error` on the action step.

     | fixture                | trigger             | expected `failed-check`             |
     | ---------------------- | ------------------- | ----------------------------------- |
     | `pkg-build-failure`    | push                | _(build step fails; `dist/` empty)_ |
     | `pkg-invalid-metadata` | push                | `twine`                             |
     | `pkg-plain-version`    | `workflow_dispatch` | `manual-version`                    |
     | `pkg-published`        | push                | `published`                         |
     | `pkg-import-failure`   | push                | _(empty; `dist/` holds both files)_ |
     | tag mismatch (new)     | tag `v9.9.9`        | `tag`                               |

     The `workflow_dispatch` and tag cases cannot be reproduced by a PR job's `github.event_name`.
     Today's suite already works around that; keep the same mechanism (a `workflow_dispatch` run
     of `ci-action.yaml`, or the `ref`/`event_name` set through an input of a dedicated job).
     Flag in the PR that those two cases only run on GitHub.
- New fixtures: `pkg-import-name` (distribution `pypi-release-action-fixture-alt`, module
  `fixture_alt`, built with `import-name` unset and set) to cover F3; `pkg-extra-file` is not
  needed because the dist-contents check is covered by the `build` assertion.
- `scripts/test-helper.sh` keeps `assert_metadata`, `assert_failure`, and gains
  `assert_failed_check <expected> <actual>`. It loses `assert_dist_artifact`'s checksum checks and
  the checksum-based `assert_failed_after_build`.
- Regression rule from CLAUDE.md: F1 (fail-open) and F3 (import name) get a failing-before test;
  F1 is the exception noted above.

### 5.5 Workflows and repository

- Keep `ci.yaml`, `lib-get-test-matrix.yaml`, `ci-format.yaml`, `ci-action.yaml`,
  `ci-verify-workflows.yaml`, `security-*.yaml`, `bot-*.yaml` as they are.
- Add a short release procedure to CLAUDE.md: tag `vX.Y.Z`, move the `vX` tag, and update the
  README example.
- CLAUDE.md edits: document `failed-check`, the `twine` pin, the rule "only 404 means not
  published", and the rule that new-feature test cases reach the released-version suite only after
  a release.

### 5.6 README

- Replace the "How it works" list with the five steps above, keeping the guard descriptions.
- Document `import-name` and `failed-check`; remove the "module name must equal the distribution
  name" requirement and all `SHA256SUMS` mentions.
- Use the two-job build/publish example:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@<sha> # v7
      - uses: durandtibo/build-pypi-package-action@v1
  publish:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      id-token: write
    steps:
      - uses: actions/download-artifact@<sha> # v?
        with:
          name: dist
          path: dist/
      - uses: pypa/gh-action-pypi-publish@release/v1
```

## 6. Migration order (one PR per logical change)

1. `fix/pypi-check-fail-closed`: F1 only. Small, urgent, safe to ship alone.
2. `refactor/read-metadata-from-wheel`: F2, F5, F6, F7, F8, F9, F13 (single validate step, remove
   the third-party action, pin `twine`, `enable-cache: false`, `--no-sources`). Adds
   `failed-check` and updates the helper and tests together.
3. `feat/import-name`: F3, new input, fixture, README.
4. `refactor/remove-checksums`: F4, breaking; combine with 2 if a single breaking release is preferred.
5. `ci/test-case-matrix`: F11, F12; convert both `ci-action.yaml` and `nightly-test-released.yaml`
   to the same case matrix; update CLAUDE.md. Remove `legacy-invoke/` after the first release that
   builds with uv.
6. `docs/two-job-example-and-release-process`: README example and release notes; tag `v1`.

PRs 2 to 4 change observable behaviour: list them as breaking in the release notes.

## 7. Considered and rejected

- **Moving the logic to `scripts/*.py` or a Python package.** Easier to unit test, but adds a
  checkout of the action's own files, a second language to maintain, and moves away from P6.
  Revisit only if `action.yml` grows past roughly 150 lines.
- **A `working-directory` input** for monorepos. Every step would need it; callers can use a
  matrix of jobs with `defaults.run.working-directory` and a checkout subpath instead.
- **Publishing from this action.** Violates P1 and would force `id-token: write` onto the build.
- **Running the project's test suite.** Out of scope; the caller has its own matrix.
- **TestPyPI / custom index input for the duplicate check.** Real need is unproven; one more input
  and more branching in the guard. Add on request.
- **Keeping `SHA256SUMS` as a second artifact.** The release job can hash files itself; not this
  action's responsibility.
- **Simulating a PyPI outage in tests.** Would need an injectable URL (an input or env var that only
  tests set), adding production surface for a three-line `case`. Accept review-only coverage.
- **Deleting the released-version suite or merging it into `ci-action.yaml`.** The two suites test
  different things (unreleased code vs. the release users run) and `uses:` cannot be parameterised.
  Keep both and share assertions instead.
