# Target state for `build-pypi-package-action`

Review of the repository at `fb41eaf`, with a proposed target state. Breaking changes are accepted
where they improve the end state. Nothing in this document has been implemented or run; the action
can only be exercised on GitHub Actions.

## 1. Properties of the action

These are the properties the target state must satisfy. Each one is checked against the proposal in
section 5.

| #   | Property              | Definition                                                                                                                                                                                                                                                       |
| --- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | **Single purpose**    | Build one Python package (sdist + wheel) from the repo root with `uv`, prove it is safe to publish, and hand `dist/` to a later publish job as an artifact. It never publishes, signs, or tests the package's own code.                                          |
| P2  | **Fail closed**       | Any check that cannot positively conclude "safe" fails the job with a clear `::error::` message. This includes a network error or a 5xx while querying PyPI, not only a definite "already published".                                                            |
| P3  | **Ground truth**      | Name and version come from the built artifact, not from a second parser of `pyproject.toml`, so static and dynamic versions behave identically and the guards check what will actually be uploaded.                                                              |
| P4  | **Minimal trust**     | No third-party action beyond `setup-uv` and `upload-artifact`. Every tool version is pinned. No caches are written (a release build must not consume or poison a cache). Needs only `contents: read`.                                                            |
| P5  | **Fast**              | Cheap checks run before slow ones; local checks before network checks. Nothing is installed or computed that is not used. Extra shell starts are accepted when they buy clarity (P12).                                                                           |
| P6  | **Simple**            | All logic stays inline in `action.yml`; no separate script. Two inputs plus one optional; two outputs plus one diagnostic.                                                                                                                                       |
| P7  | **Portable**          | Identical behaviour on Linux, macOS, and Windows (Git Bash) runners. No dependency on `sha256sum`, `shasum`, or other platform-specific tools.                                                                                                                   |
| P8  | **Safe to chain**     | `dist/` contains exactly the files that PyPI accepts (one wheel, one sdist) so the publish job can upload the directory as is.                                                                                                                                   |
| P9  | **Secure by default** | Inputs and outputs go through `env:`, never `${{ }}` in `run:`. Third-party actions are pinned to SHAs with `# ratchet:` comments. The build job needs no `id-token`.                                                                                            |
| P10 | **Tested, cheaply**   | Every guard has a fixture that proves it fails for the expected reason. The two test suites (current code, last release) share one case table and one set of assertions; CI cost and maintenance are proportional to the action's size.                          |
| P11 | **Fail loudly**       | A failure says what failed, why it matters, the values involved, and how to fix it, in an annotation and in the job summary, at the top level of the log. The user never has to read a stack trace or the action's source to understand it.                      |
| P12 | **Small steps**       | Many small steps rather than a few large ones: one purpose and one failure id per step, about 15 lines at most, named `N.x` by topic (`0.x` setup, `1.x` build, `2.x` guards, `3.x` smoke tests, `4.x` upload). Each step can be read, changed and tested alone. |

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

### F6. Step layout: ungrouped and uneven (P5, P12)

The current 10 steps are not grouped, and their size is uneven: `Smoke test` loops over two artifacts
in one script, `Check dist contents` is a 10-line script, while the three guards each have their own
step. The order is mostly fail-fast, but the third-party metadata action sits between `twine` and
the guards. The target is more, smaller steps grouped by topic (`0.x` to `4.x`, see 5.2): one step
per check, one failure id per step, with the wheel and sdist smoke tests split so that a failure
names the artifact. Steps share only outputs and a `fail` helper (the one thing that cannot be shared
between composite steps otherwise).

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
**Fix:** one diagnostic output `failed-check` set by the failing step before it exits
(`build`, `dist-contents`, `twine`, `manual-version`, `tag`, `published`, `import`, `smoke-wheel`,
`smoke-sdist`), asserted by the tests. Each id is the `id:` of the step that can fail.

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

### F13. Failures are quiet and give no remedy (violates P11)

Today's messages state the symptom only: `Tag v1.2 does not match package version 1.2.0`,
`... is already published on PyPI`, `Expected exactly one wheel and one sdist`. They do not say what
to do next. The other failures are not explained at all: a failing smoke test ends in a raw `uv`
error, a failing build or `twine check` in the tool's own output with no pointer to the check that
failed, and nothing is written to the job summary, so the reader must open the log, find the red
step, and infer the cause. Fixing the cause often needs context the message omits: the event, the
ref, the detected version, and the rule that was applied.
**Fix:** every failure goes through one `fail()` helper that emits an annotation with a title and a
message of the form _what failed - why - how to fix_, including the actual values, and appends the
same text to `$GITHUB_STEP_SUMMARY`. Build and smoke-test failures are wrapped so that the tool's
output is followed by the same kind of message. The messages are specified in 5.2.1.

### F14. Few checks on what is actually built (P2, P11)

Today the built files are checked for: one wheel and one sdist, `twine check`, and an import in a
clean environment. Releases are irreversible, so cheap checks of common failures belong here. The
target adds, each as its own step with its own `failed-check` id:

| Step | `failed-check`      | Catches                                                                                             |
| ---- | ------------------- | --------------------------------------------------------------------------------------------------- |
| 1.5  | `metadata-fields`   | Missing `Summary` or `Requires-Python` (pip would install on unsupported Python; blank PyPI page).  |
| 1.6  | `artifact-mismatch` | Wheel and sdist with a different name or version.                                                   |
| 1.7  | `unwanted-files`    | `.env`, `.git`, `.pypirc`, private keys, `.pem`, `__pycache__`, `.pyc`, `.DS_Store` in either file. |
| 1.8  | `size`              | A file over PyPI's 100 MiB default limit, found before the upload.                                  |
| 1.9  | _(warning only)_    | A platform-specific wheel, which one runner cannot cover for all platforms.                         |
| 2.1  | `local-version`     | `1.2.3+abc` (setuptools-scm on an untagged commit), which PyPI rejects.                             |
| 3.4  | `entry-points`      | A console script or plugin entry point that does not resolve to an importable object.               |

All are local, take under a second except 3.4 (one more `uv run`), and are deterministic, so they
are testable with fixtures (5.4). Considered but not added: license checks (PyPI does not require
one), `__version__` consistency (no standard way to find it), and a pure-Python requirement (would
block compiled packages).

### F15. Smaller points

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

### 5.2 Steps (21 small steps, grouped by topic)

Rules for steps:

- One purpose and one failure id per step; a step is about 15 lines or fewer.
- Steps are grouped by topic and numbered `N.x` in their name: `0.x` setup, `1.x` build and package
  checks, `2.x` release guards, `3.x` smoke tests, `4.x` report and upload. The numbering shows the
  order and the topic in the log; a new check slots in as the next `N.x`.
- Steps share data only through step outputs and the `fail` helper (0.2), never through files in the
  repo or implicit state.
- A guard that does not apply is skipped with `if:` (visible as "skipped" in the UI) instead of
  being an `if` inside the script.
- A step can be read, changed, and tested on its own; a failure points at one step and one
  `failed-check` id.

```yaml
runs:
  using: composite
  steps:
    # ---- 0.x Setup ---------------------------------------------------------
    - name: 0.1 Install uv
      uses: astral-sh/setup-uv@<sha> # ratchet:astral-sh/setup-uv@<tag>
      with:
        python-version: ${{ inputs.python-version }}
        enable-cache: false # a release build must not consume or write a cache

    # Composite steps cannot share shell functions, so write the failure helper once (P11).
    - name: 0.2 Define failure helper
      shell: bash
      run: |
        cat > "${RUNNER_TEMP}/fail.sh" <<'EOF'
        # fail <check-id> <title> <what happened and why> <how to fix>
        fail() {
          echo "failed-check=$1" >> "$GITHUB_OUTPUT"
          echo "::error title=$2::$3 How to fix: $4"
          printf '### :x: %s\n\n%s\n\n**How to fix:** %s\n' "$2" "$3" "$4" >> "$GITHUB_STEP_SUMMARY"
          exit 1
        }
        EOF

    # ---- 1.x Build and package checks ---------------------------------------
    # --clear: no stale files from earlier builds. --no-sources: ignore [tool.uv.sources]
    # so the build matches what PyPI users get.
    - name: 1.1 Build package
      id: build
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        uv build --clear --no-sources --out-dir dist ||
          fail build "Build failed" "uv build failed (output above); nothing was uploaded." \
            "Run uv build locally; the error comes from the build backend."

    - name: 1.2 Check dist contents
      id: dist-contents
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        shopt -s nullglob
        files=(dist/*) wheels=(dist/*.whl) sdists=(dist/*.tar.gz)
        [[ ${#files[@]} -eq 2 && ${#wheels[@]} -eq 1 && ${#sdists[@]} -eq 1 ]] ||
          fail dist-contents "Unexpected files in dist/" \
            "dist/ holds: ${files[*]:-nothing}; exactly one wheel and one sdist are required." \
            "Check [build-system] and that no other step writes to dist/."

    - name: 1.3 Check package metadata
      id: twine
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        uvx twine@<pinned> check --strict dist/* ||
          fail twine "Invalid package metadata" \
            "twine check --strict rejected the metadata (output above); PyPI would reject or misrender it." \
            "Fix the readme/description named above; run uvx twine check --strict dist/* locally."

    # Name, version and module come from the wheel that will be uploaded, not from pyproject.toml.
    - name: 1.4 Read package metadata
      id: metadata
      shell: bash
      run: |
        read -r name version module canonical < <(uv run --no-project python -I - dist/*.whl <<'PY'
        import re, sys, zipfile
        from email.parser import Parser
        with zipfile.ZipFile(sys.argv[1]) as z:
            names = z.namelist()
            meta = Parser().parsestr(z.read(next(n for n in names if n.endswith(".dist-info/METADATA"))).decode())
            top = next((n for n in names if n.endswith(".dist-info/top_level.txt")), None)
            canonical = re.sub(r"[-_.]+", "-", meta["Name"]).lower()  # PEP 503
            print(meta["Name"], meta["Version"], z.read(top).decode().split()[0] if top else "-", canonical)
        PY
        )
        { echo "name=${name}"; echo "version=${version}"; echo "module=${module}"; echo "canonical-name=${canonical}"; } >> "$GITHUB_OUTPUT"

    # Metadata PyPI and installers rely on: without Requires-Python pip installs the package on
    # Python versions it does not support; without Summary the project page is blank.
    - name: 1.5 Check required metadata fields
      id: metadata-fields
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        missing=$(uv run --no-project python -I - dist/*.whl <<'PY'
        import sys, zipfile
        from email.parser import Parser
        with zipfile.ZipFile(sys.argv[1]) as z:
            meta = Parser().parsestr(z.read(next(n for n in z.namelist() if n.endswith(".dist-info/METADATA"))).decode())
        print(*[k for k in ("Summary", "Requires-Python") if not meta[k]])
        PY
        )
        [[ -z "${missing}" ]] ||
          fail metadata-fields "Required metadata missing" "The wheel has no: ${missing}." \
            "Set description and requires-python in [project] of pyproject.toml."

    # The wheel and the sdist must describe the same release; a mismatch means two builds or a
    # backend that rewrites the name/version differently per format.
    - name: 1.6 Check wheel and sdist agree
      id: artifact-mismatch
      shell: bash
      env:
        NAME: ${{ steps.metadata.outputs.canonical-name }}
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        sdist=$(uv run --no-project python -I - dist/*.tar.gz <<'PY'
        import re, sys, tarfile
        from email.parser import Parser
        with tarfile.open(sys.argv[1]) as t:
            m = next(m for m in t.getmembers() if m.name.count("/") == 1 and m.name.endswith("/PKG-INFO"))
            meta = Parser().parsestr(t.extractfile(m).read().decode())
        print(re.sub(r"[-_.]+", "-", meta["Name"]).lower(), meta["Version"])
        PY
        )
        [[ "${sdist}" == "${NAME} ${VERSION}" ]] ||
          fail artifact-mismatch "Wheel and sdist disagree" \
            "Wheel is ${NAME} ${VERSION}, sdist is ${sdist}." \
            "Build both from the same source; check dynamic name/version settings of the backend."

    # Files that must never ship: secrets, VCS data, caches. Fails closed on a path match.
    - name: 1.7 Check no unwanted files are packaged
      id: unwanted-files
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        found=$(uv run --no-project python -I - dist/*.whl dist/*.tar.gz <<'PY'
        import re, sys, tarfile, zipfile
        bad = re.compile(r"(^|/)(\.env(\..*)?|\.git(/|$)|\.pypirc|id_(rsa|ed25519)|[^/]*\.pem|__pycache__(/|$)|\.DS_Store)$|\.pyc$")
        names = zipfile.ZipFile(sys.argv[1]).namelist() + tarfile.open(sys.argv[2]).getnames()
        print(*sorted({n for n in names if bad.search(n)}))
        PY
        )
        [[ -z "${found}" ]] ||
          fail unwanted-files "Unwanted files in the package" "Found: ${found}" \
            "Exclude them in the build backend config (e.g. hatch exclude, MANIFEST.in) and rotate any leaked secret."

    # PyPI rejects files over 100 MiB by default; fail here instead of at upload time.
    - name: 1.8 Check file sizes
      id: size
      shell: bash
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        for f in dist/*; do
          size=$(wc -c < "${f}")
          (( size <= 100 * 1024 * 1024 )) ||
            fail size "File too large for PyPI" "${f} is ${size} bytes; PyPI's default limit is 100 MiB." \
              "Exclude data and build artifacts from the package, or request a limit increase from PyPI."
        done

    # A platform-specific wheel built on one runner does not cover the other platforms.
    # Warn only: compiled packages are legitimate, but the caller should know.
    - name: 1.9 Warn on platform-specific wheel
      shell: bash
      run: |
        wheel=$(basename dist/*.whl)
        [[ "${wheel}" == *-none-any.whl ]] ||
          echo "::warning title=Platform-specific wheel::${wheel} only installs on one platform; build other platforms separately."

    # ---- 2.x Release guards (local checks first, network last) ---------------
    # PyPI rejects local versions ("1.2.3+abc"), typical of setuptools-scm on untagged commits.
    - name: 2.1 Check version has no local segment
      id: local-version
      shell: bash
      env:
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        [[ "${VERSION}" != *+* ]] ||
          fail local-version "Local version cannot be published" \
            "${VERSION} has a local segment (+...), which PyPI rejects." \
            "Build from a tagged commit, or configure the version scheme to drop local versions."

    - name: 2.2 Check manual run uses a pre-release version
      id: manual-version
      if: github.event_name == 'workflow_dispatch'
      shell: bash
      env:
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        [[ "${VERSION}" =~ (a|b|rc)[0-9]+|\.dev[0-9]+ ]] ||
          fail manual-version "Version not allowed on manual run" \
            "Event is workflow_dispatch and ${VERSION} is a final release." \
            "Use a pre-release (${VERSION}a1, ${VERSION}.dev1) or publish by pushing tag v${VERSION}."

    - name: 2.3 Check tag matches version
      id: tag
      if: startsWith(github.ref, 'refs/tags/')
      shell: bash
      env:
        TAG: ${{ github.ref_name }}
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        [[ "${TAG}" == "v${VERSION}" ]] ||
          fail tag "Tag does not match version" \
            "Tag is ${TAG}, package version is ${VERSION}; the tag must be exactly v${VERSION}." \
            "Fix the version in pyproject.toml, or delete the tag and create v${VERSION}."

    # Only a 404 proves "not published"; any other answer fails closed.
    - name: 2.4 Check version not already on PyPI
      id: published
      shell: bash
      env:
        NAME: ${{ steps.metadata.outputs.canonical-name }}
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        status=$(curl --silent --show-error --max-time 20 --retry 3 --output /dev/null \
          --write-out '%{http_code}' "https://pypi.org/pypi/${NAME}/${VERSION}/json" || true)
        case "${status}" in
          404) ;;
          200) fail published "Version already on PyPI" \
                 "${NAME} ${VERSION} exists on PyPI, which never allows re-uploading a version." \
                 "Bump the version (and create a new tag for a tag push)." ;;
          *)   fail published "Cannot verify against PyPI" \
                 "PyPI answered HTTP ${status}; failing closed instead of guessing." \
                 "Re-run the job; check https://status.python.org if it persists." ;;
        esac

    # ---- 3.x Smoke tests (install each artifact in a clean environment) ------
    # Without the project and in isolated mode (-I), so the source tree cannot mask a broken artifact.
    - name: 3.1 Resolve import name
      id: import
      shell: bash
      env:
        MODULE: ${{ inputs.import-name || steps.metadata.outputs.module }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        [[ "${MODULE}" != "-" ]] ||
          fail import "Import name not detected" \
            "The wheel has no top_level.txt, so the module to import is unknown." \
            "Set the import-name input."
        echo "module=${MODULE}" >> "$GITHUB_OUTPUT"

    - name: 3.2 Smoke test wheel
      id: smoke-wheel
      shell: bash
      env:
        MODULE: ${{ steps.import.outputs.module }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        uv run --isolated --no-project --with dist/*.whl -- python -I -c "import os, importlib; importlib.import_module(os.environ['MODULE'])" ||
          fail smoke-wheel "Wheel cannot be imported" \
            "Installing the wheel in a clean environment and importing ${MODULE} failed (output above)." \
            "Check that the wheel contains the package (unzip -l dist/*.whl), or set import-name."

    - name: 3.3 Smoke test sdist
      id: smoke-sdist
      shell: bash
      env:
        MODULE: ${{ steps.import.outputs.module }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        uv run --isolated --no-project --with dist/*.tar.gz -- python -I -c "import os, importlib; importlib.import_module(os.environ['MODULE'])" ||
          fail smoke-sdist "Sdist cannot be built or imported" \
            "Building the sdist in a clean environment and importing ${MODULE} failed (output above)." \
            "Check that the sdist contains the sources and build files (tar tzf dist/*.tar.gz)."

    # Every declared entry point (console scripts, plugins) must resolve to an importable object:
    # a typo there installs fine and fails only when the user runs the command.
    - name: 3.4 Smoke test entry points
      id: entry-points
      shell: bash
      env:
        NAME: ${{ steps.metadata.outputs.name }}
      run: |
        source "${RUNNER_TEMP}/fail.sh"
        uv run --isolated --no-project --with dist/*.whl -- python -I -c "import os; from importlib.metadata import distribution; [ep.load() for ep in distribution(os.environ['NAME']).entry_points]" ||
          fail entry-points "Entry point cannot be loaded" \
            "An entry point of ${NAME} failed to load (output above)." \
            "Check the [project.scripts] / [project.entry-points] targets for typos and import errors."

    # ---- 4.x Report and upload -----------------------------------------------
    - name: 4.1 Write job summary
      shell: bash
      env:
        NAME: ${{ steps.metadata.outputs.name }}
        VERSION: ${{ steps.metadata.outputs.version }}
      run: |
        printf '### :white_check_mark: %s %s\n\nBuilt and checked: %s\n' "${NAME}" "${VERSION}" "$(ls dist | tr '\n' ' ')" >> "$GITHUB_STEP_SUMMARY"

    - name: 4.2 Upload distributions
      uses: actions/upload-artifact@<sha> # ratchet:actions/upload-artifact@<tag>
      with:
        name: ${{ inputs.artifact-name }}
        path: dist/
        retention-days: 5
        if-no-files-found: error

outputs:
  package-name:
    value: ${{ steps.metadata.outputs.name }}
  package-version:
    value: ${{ steps.metadata.outputs.version }}
  # Diagnostic: id of the failed check, empty on success. Only one step can fail, so at most one is set.
  failed-check:
    value: >-
      ${{ steps.build.outputs.failed-check || steps.dist-contents.outputs.failed-check
      || steps.twine.outputs.failed-check || steps.manual-version.outputs.failed-check
      || steps.tag.outputs.failed-check || steps.published.outputs.failed-check
      || steps.metadata-fields.outputs.failed-check || steps.artifact-mismatch.outputs.failed-check
      || steps.unwanted-files.outputs.failed-check || steps.size.outputs.failed-check
      || steps.local-version.outputs.failed-check
      || steps.import.outputs.failed-check || steps.smoke-wheel.outputs.failed-check
      || steps.smoke-sdist.outputs.failed-check || steps.entry-points.outputs.failed-check }}
```

Notes on the sketch:

- It is a sketch to show the shape, not tested code. Verify on all three runners (Git Bash on
  Windows in particular): the `(a|b|rc)` regex and quoting inside `[[ =~ ]]`, heredoc indentation
  inside YAML (both heredocs), `source "${RUNNER_TEMP}/fail.sh"` with a Windows `RUNNER_TEMP`, the
  `tr` canonicalisation, and `dist/*.whl` expanding to exactly one file after check 1.2.
- Also verify that a failed composite action still exposes the outputs of its failed step (the
  `failed-check` output and the `continue-on-error` pattern the tests rely on). If it does not, fall
  back to the file-state markers the tests use today.
- `shopt`, `read` and process substitution are bash features; every step sets `shell: bash`.
- Values reach scripts through `env:` (P9). The only `${{ }}` in a `run:` is none.
- Every failure has its own `failed-check` id, including build and smoke tests, so tests no longer
  need to infer the stage from `dist/`.
- Cost of more steps: each step starts a shell (about a second on Windows at worst). The
  steps that run `uv` dominate the time; the extra shells are accepted for maintainability (P12).

#### 5.2.1 Failure messages (P11)

Each message has a title (annotation heading), what happened with the real values, and the fix. The
wording below is the contract; the exact text can be tuned in the PR.

| `failed-check`               | Title                             | What happened                                                                                   | How to fix                                                                                                             |
| ---------------------------- | --------------------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `build`                      | Build failed                      | `uv build` failed (its output is above). Nothing was uploaded.                                  | Run `uv build` locally; the error above is from the build backend, not from this action.                               |
| `dist-contents`              | Unexpected files in dist/         | Found N wheel(s), M sdist(s), list of files. Exactly one of each is required.                   | Check `[build-system]` and that no other step writes to `dist/`.                                                       |
| `twine`                      | Invalid package metadata          | `twine check --strict` rejected the metadata (output above). PyPI would reject or misrender it. | Fix the `readme`, `description`, or classifiers named above; run `uvx twine check --strict dist/*` locally.            |
| `metadata-fields`            | Required metadata missing         | The wheel has no: Summary / Requires-Python.                                                    | Set `description` and `requires-python` in `[project]`.                                                                |
| `artifact-mismatch`          | Wheel and sdist disagree          | Wheel is `a 1.0`, sdist is `a 1.1`.                                                             | Build both from the same source; check dynamic name/version settings.                                                  |
| `unwanted-files`             | Unwanted files in the package     | Found: `.env`, `.git/config`.                                                                   | Exclude them in the backend config and rotate any leaked secret.                                                       |
| `size`                       | File too large for PyPI           | `dist/x.whl` is N bytes; the default limit is 100 MiB.                                          | Exclude data and build artifacts from the package.                                                                     |
| `local-version`              | Local version cannot be published | `1.2.3+abc` has a local segment, which PyPI rejects.                                            | Build from a tagged commit or drop local versions in the version scheme.                                               |
| `entry-points`               | Entry point cannot be loaded      | An entry point of `name` failed to load (output above).                                         | Check `[project.scripts]` / `[project.entry-points]` for typos and import errors.                                      |
| `manual-version`             | Version not allowed on manual run | Event is `workflow_dispatch` and the version is `1.2.3`, which is a final release.              | Set a pre-release version (`1.2.3a1`, `1.2.3.dev1`), or publish by pushing the tag `v1.2.3`.                           |
| `tag`                        | Tag does not match version        | Tag is `v1.2`, package version is `1.2.0`. The tag must be exactly `v` + the version.           | Change the version in `pyproject.toml`, or delete the tag and create `v1.2.0`.                                         |
| `published`                  | Version already on PyPI           | `name 1.2.3` exists on PyPI. PyPI never allows re-uploading a version.                          | Bump the version and, for a tag push, create a new tag.                                                                |
| `published`                  | Cannot verify against PyPI        | PyPI answered HTTP 503 (or no answer). The action fails closed instead of guessing.             | Re-run the job; check https://status.python.org if it persists.                                                        |
| `smoke-wheel`, `smoke-sdist` | Distribution cannot be imported   | Installing `<file>` into a clean environment and importing `<module>` failed (output above).    | Check that the wheel and sdist contain the package (`unzip -l`), or set `import-name` if `<module>` is the wrong name. |
| `import`                     | Import name not detected          | The wheel has no `top_level.txt` and the action cannot tell which module to import.             | Set the `import-name` input.                                                                                           |

Rules for all messages:

- Always include the values involved (version, tag, event, file, HTTP status), never only a verdict.
- A message must be understandable without reading `action.yml`.
- The build and smoke-test steps run their tool first, so the real error is directly above the
  action's message; the action's message is the last thing in the log and in the summary.
- On success, the job summary lists name, version, files, and the checks that passed, so a green run
  is also readable (`### :white_check_mark: name version`).
- Tests assert the `failed-check` id, not the text, so wording can improve without touching tests.

### 5.3 Why this satisfies the properties

| Property | How                                                                                                             |
| -------- | --------------------------------------------------------------------------------------------------------------- |
| P1       | No publishing, signing, or checksum generation. One job: build, validate, hand over.                            |
| P2       | Whitelist for manual runs, exact tag rule, PyPI check passes only on 404, missing import name is an error.      |
| P3       | Name, version and import name read from the wheel that is uploaded.                                             |
| P4       | Two third-party actions instead of three; pinned `twine`; no cache; `contents: read` is enough.                 |
| P5       | Local checks before the network check before the smoke tests; no unused venv, no checksum pass.                 |
| P6       | Still one `action.yml`, no script; longer than today because of the added guards (F14), but each step is short. |
| P7       | No `sha256sum`/`shasum` fallback needed; everything else is `uv`, `bash`, `curl`.                               |
| P8       | `dist/` holds two files and the check enforces it.                                                              |
| P9       | Unchanged rules, enforced for new inputs and the new step.                                                      |
| P10      | See 5.4.                                                                                                        |
| P11      | One `fail()` helper; what / why / fix with real values in annotation and job summary (5.2.1).                   |
| P12      | 21 steps in 5 topic groups, each one purpose and one failure id; the longest (1.7) is about 15 lines.           |

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

     | fixture                                          | trigger             | expected `failed-check` |
     | ------------------------------------------------ | ------------------- | ----------------------- |
     | `pkg-build-failure`                              | push                | `build`                 |
     | `pkg-invalid-metadata`                           | push                | `twine`                 |
     | `pkg-plain-version`                              | `workflow_dispatch` | `manual-version`        |
     | `pkg-published`                                  | push                | `published`             |
     | `pkg-import-failure`                             | push                | `smoke-wheel`           |
     | tag mismatch (new)                               | tag `v9.9.9`        | `tag`                   |
     | `pkg-no-requires-python` (new)                   | push                | `metadata-fields`       |
     | `pkg-secret-file` (new, force-includes a `.env`) | push                | `unwanted-files`        |
     | `pkg-local-version` (new, `1.0.0+local`)         | push                | `local-version`         |
     | `pkg-bad-entry-point` (new)                      | push                | `entry-points`          |

     The `workflow_dispatch` and tag cases cannot be reproduced by a PR job's `github.event_name`.
     The `size`, `artifact-mismatch` and platform-wheel checks have no cheap fixture (a 100 MiB file,
     or a backend that disagrees with itself) and are covered by review only. Today's suite already works around the event limits; keep the same mechanism (a `workflow_dispatch` run
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

- Replace the "How it works" list with the step groups above (`0.x` to `4.x`), keeping the guard descriptions.
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
2. `refactor/read-metadata-from-wheel`: F2, F5, F6, F7, F8, F9, F13, F15 (grouped `N.x` steps, remove
   the third-party action, pin `twine`, `enable-cache: false`, `--no-sources`). Adds
   `failed-check` and updates the helper and tests together.
3. `feat/import-name`: F3, new input, fixture, README.
4. `feat/package-guards`: F14 (steps 1.5 to 1.9, 2.1, 3.4) with their fixtures; each guard is a new
   step and a table row, so they can also be split across PRs.
5. `refactor/remove-checksums`: F4, breaking; combine with 2 if a single breaking release is preferred.
6. `ci/test-case-matrix`: F11, F12; convert both `ci-action.yaml` and `nightly-test-released.yaml`
   to the same case matrix; update CLAUDE.md. Remove `legacy-invoke/` after the first release that
   builds with uv.
7. `docs/two-job-example-and-release-process`: README example and release notes; tag `v1`.

PRs 2 to 5 change observable behaviour: list them as breaking in the release notes.

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
