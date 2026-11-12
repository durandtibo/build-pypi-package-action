# build-pypi-package-action

[![CI](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml/badge.svg)](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml)
[![Nightly](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/nightly.yaml/badge.svg)](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/nightly.yaml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/durandtibo/build-pypi-package-action/badge)](https://scorecard.dev/viewer/?uri=github.com/durandtibo/build-pypi-package-action)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/tag/durandtibo/build-pypi-package-action?label=release)](https://github.com/durandtibo/build-pypi-package-action/tags)

A composite GitHub Action that builds a Python package (sdist + wheel), validates it, and blocks the
workflow before a bad release can go out.

Point it at a repo with a `pyproject.toml`, and it builds the distributions with
`uv`, checks their metadata, verifies the version being built is actually safe to publish, smoke-tests
the wheel and the sdist in clean environments, and uploads everything as a workflow artifact — ready for a publish step
right after it.

## Why use it

Releasing a Python package to PyPI is unforgiving — you can't overwrite or delete a bad version once it's
up. This action exists to catch the usual ways that goes wrong _before_ the publish step runs:

- A `workflow_dispatch` dry run accidentally targets a real release version instead of a pre-release.
- A tag doesn't actually match the version in `pyproject.toml`.
- The version being built is already on PyPI (a duplicate/stale release).
- The wheel or the sdist builds but doesn't actually install or import.

If any of these are true, the action fails the job and nothing gets published.

## How it works

The action is a sequence of small steps, grouped by topic and numbered `N.x` in the log. Each step
has one purpose and one `failed-check` id (see [Outputs](#outputs)).

**0.x Setup**

- `0.1` installs a pinned `uv` and the requested Python version
  ([`astral-sh/setup-uv`](https://github.com/astral-sh/setup-uv), without cache: a release build never
  consumes or writes one).
- `0.2` defines the `fail` helper used by every later step.

**1.x Build and package checks**

- `1.1` builds the sdist and wheel into `dist/` with `uv build --clear --no-sources`, so stale files
  and `[tool.uv.sources]` overrides cannot change what is released (`build`).
- `1.2` fails unless `dist/` holds exactly one wheel and one sdist (`dist-contents`).
- `1.3` opens the wheel and the sdist once and extracts facts only, no verdict: name, version, missing
  metadata fields, unwanted files, import name. The name and version come from the built wheel's
  metadata, not from a second parser of `pyproject.toml`, so static and dynamic versions behave the
  same and the guards check what is uploaded. The import name is `top_level.txt` if the wheel has
  one, else the first top-level package (directory with `__init__.py`), else the first top-level
  module.
- `1.4` fails if the wheel has no `Summary` or no `Requires-Python` (`metadata-fields`).
- `1.5` fails if the wheel and the sdist have a different name or version (`artifact-mismatch`).
- `1.6` fails if either file contains `.env` (not `.env.example`), `.git`, `.pypirc`, SSH keys, `.pem`
  files, `__pycache__`, `.pyc` or `.DS_Store` (`unwanted-files`).
- `1.7` fails if a file exceeds PyPI's default 100 MiB limit (`size`).
- `1.8` only warns about a platform-specific wheel, which one runner cannot cover for every platform.
- `1.9` validates the metadata with `twine check --strict` (`twine`). It runs last, after the cheap
  local checks, because it needs a download. `twine` is pinned, and so are its dependencies
  (`uvx --exclude-newer <date>`), so the check is reproducible.

**2.x Release guards**

- `2.1` fails on a local version such as `1.2.3+abc` (setuptools-scm on an untagged commit), which PyPI
  rejects (`local-version`).
- `2.2` **manual runs:** on `workflow_dispatch`, fails unless the version is a pre-release (contains
  `aN`, `bN`, `rcN` or `.devN`, e.g. `1.2.3a1`, `1.2.3.dev1`). Final and post releases (`1.2.3`,
  `1.2.3.post1`) must go through a tag push (`manual-version`).
- `2.3` **tag pushes:** on any tag push (`refs/tags/*`), fails unless the tag is exactly `v` + the
  normalized package version (`v1.2.3` for `1.2.3`; `v1.0.0-rc1` is rejected, the tag is `v1.0.0rc1`)
  (`tag`).
- `2.4` **duplicate releases:** queries `https://pypi.org/pypi/<name>/<version>/json` (name normalized
  per PEP 503, 20 s timeout, 3 retries). Only an HTTP 404 passes: a 200 fails because the version is
  published, and any other answer (network error, 429, 5xx) fails too because the check could not prove
  the version is free. It does not detect versions on other indexes (e.g. TestPyPI) (`published`).

**3.x Smoke tests**

- `3.1` picks the module to import: the `import-name` input if set, else the one detected in `1.3`.
  It fails if neither is available (`import`).
- `3.2` and `3.3` install the wheel and the sdist, each into a throwaway environment, and import that
  module in isolated mode (`smoke-wheel`, `smoke-sdist`).
- `3.4` loads every declared entry point (console scripts, plugins) from the installed wheel, so a typo
  in `[project.scripts]` fails here and not when a user runs the command (`entry-points`). An entry
  point that needs an optional dependency which is not installed fails this check too.

**4.x Report and upload**

- `4.1` writes the job summary; `4.2` uploads `dist/` (the wheel and the sdist, nothing else) as a
  workflow artifact, kept for 5 days. The upload fails if `dist/` is empty. The publish job can upload
  the downloaded directory as is.

Every step is fail-closed: the first failing check stops the job, and nothing is uploaded after it. A
failure is reported as an annotation and in the job summary, in the form _what failed, why, how to
fix_, with the values involved. The steps use `bash` and work on Linux, macOS, and Windows (Git Bash)
runners.

## Requirements

The calling repo must provide, at its root:

| Requirement      | Notes                                                    |
| ---------------- | -------------------------------------------------------- |
| `pyproject.toml` | Must resolve a `name` and `version` (static or dynamic). |

- The calling job must check out the repo (`actions/checkout`) before this action runs.
- The package must be buildable with `uv build` (any PEP 517 build backend). The smoke test imports
  the module detected from the wheel; it does not have to match the distribution name (`pyyaml` →
  `yaml`). Set `import-name` if the detection picks the wrong module (e.g. several top-level
  packages).
- The action builds in the repo root and writes to `dist/`. Existing contents of `dist/` are removed
  first.
- `dist/` must end up with exactly one wheel and one sdist (`.tar.gz`).

## Inputs

| Name             | Description                                                   | Required | Default                 |
| ---------------- | ------------------------------------------------------------- | -------- | ----------------------- |
| `python-version` | Python version used to build and smoke-test the package.      | No       | `3.14`                  |
| `artifact-name`  | Name of the uploaded distribution artifact.                   | No       | `dist`                  |
| `import-name`    | Module imported by the smoke test (e.g. `yaml` for `pyyaml`). | No       | detected from the wheel |

The `python-version` is used for the build and for the smoke test; the package is not tested against
other versions, so run your own test matrix separately.

## Outputs

| Name              | Description                                                                       |
| ----------------- | --------------------------------------------------------------------------------- |
| `package-name`    | `Name` field of the built wheel's metadata (exact spelling of the build backend). |
| `package-version` | Normalized version of the built wheel.                                            |
| `failed-check`    | Diagnostic: id of the check that failed (see below); empty on success.            |

`package-name` and `package-version` are read from the built wheel, so they are what gets uploaded,
and are available once step `1.3` has run. If an earlier step fails, the action fails and they are
empty.

`failed-check` is one of `build`, `dist-contents`, `twine`, `metadata-fields`, `artifact-mismatch`,
`unwanted-files`, `size`, `local-version`, `manual-version`, `tag`, `published`, `import`,
`smoke-wheel`, `smoke-sdist`, `entry-points`. It is meant for diagnostics and tests: the annotation
and the job summary already say what failed and how to fix it. To read it after a failure, set
`continue-on-error: true` on the action step.

## Usage

### Basic

```yaml
- uses: actions/checkout@v7

- name: Build package
  uses: durandtibo/build-pypi-package-action@v1
  with:
    python-version: "3.14"
```

### Reading the outputs

```yaml
- name: Build package
  id: build
  uses: durandtibo/build-pypi-package-action@v1

- name: Show package metadata
  env:
    PACKAGE_NAME: ${{ steps.build.outputs.package-name }}
    PACKAGE_VERSION: ${{ steps.build.outputs.package-version }}
  run: echo "${PACKAGE_NAME} ${PACKAGE_VERSION}"
```

### Custom artifact name

```yaml
- name: Build package
  uses: durandtibo/build-pypi-package-action@v1
  with:
    artifact-name: my-package-dist
```

### End-to-end release workflow

Use two jobs. The `build` job only needs `contents: read`; the `publish` job downloads the artifact and
is the only one with `id-token: write` and the `pypi` environment, so the code that runs during the
build never sees the OIDC token. The workflow runs on manual dispatch (dry run with a pre-release
version) and on tag pushes (real release); only a tag push publishes. Publishing uses
[PyPI trusted publishing](https://docs.pypi.org/trusted-publishers/) (configure the trusted publisher
and the `pypi` environment first). The artifact holds the wheel and the sdist only, so the publish step
uploads the directory as is.

```yaml
name: Release

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

permissions: {}

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
      - uses: durandtibo/build-pypi-package-action@v1 # or pin the commit SHA

  publish:
    needs: build
    if: startsWith(github.ref, 'refs/tags/')
    runs-on: ubuntu-latest
    environment: pypi
    permissions:
      id-token: write # trusted publishing
    steps:
      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: dist
          path: dist/
      - uses: pypa/gh-action-pypi-publish@7245906fb61fa33a13554f9d5fb856fe61758086 # release/v1
```

## Versioning

Releases are tagged `vX.Y.Z` and are immutable. A floating major tag (`v1`) always points to the
latest `v1.Y.Z` release and only receives non-breaking updates. Use `@v1` to follow them, or pin the
full commit SHA of a release (as for any third-party action) for a reproducible build and let your
update bot bump it.

## Upgrading from v0.0.x

Breaking changes:

- **`SHA256SUMS` is gone.** The artifact holds exactly the wheel and the sdist. If a release job needs
  checksums, compute them there.
- **`package-name` is read from the built wheel** (the exact `Name` field), not from `pyproject.toml`.
- **The module name no longer has to match the distribution name.** It is detected from the wheel, or
  set with the new `import-name` input.
- **Stricter checks that can fail a build that passed before:** a missing `Summary` or
  `Requires-Python`, `.env`/key/`__pycache__` files in the package, a local version (`1.2.3+abc`), an
  entry point that cannot be loaded, a post release on a manual run, and any PyPI answer other than
  404 in the duplicate check (a PyPI outage now fails the job).
- **The tag must be exactly `v` + the normalized version** (`v1.0.0rc1`, not `v1.0.0-rc1`).
- New output `failed-check`; `twine` is pinned and the `uv` cache is disabled.

## Development

The action is defined entirely in [`action.yml`](action.yml); there is no separate script. Use the
`Makefile` (`make help` lists the targets):

```shell
make format   # format YAML, Makefile, shell and Markdown files
make lint     # lint the same files
```

The `.make/` directory is shared with other repos and synced automatically by
`bot-sync-shared-makefile.yaml`; do not edit it here.

### Tests

The action can only be exercised end to end on GitHub Actions; there is no local test run.

- `test/fixtures/` holds throwaway packages (success path, edge cases such as dotted names, dynamic
  versions and an import name that differs from the distribution name, and failure paths such as a
  failing build, invalid metadata, an unimportable package, an already-published version, a missing
  `Requires-Python`, a packaged `.env`, a local version, a broken entry point, and a plain or post
  version on a manual run). They are not part of the action.
- `scripts/test-helper.sh` holds the assertions shared by the test workflows.
- `ci-action.yaml` runs the action from the current checkout (`uses: ./`) against the fixtures on
  Linux, macOS, and Windows, and on every Python version on Linux. Its jobs are driven by case tables:
  `accept` (packages that must build) and `reject` (packages that must fail, with the `failed-check`
  id that the failure must carry). A new case is a new row.
- `reject-manual` only runs on `workflow_dispatch` and `reject-tag-mismatch` only when the workflow is
  run by hand on a tag ref (`gh workflow run ci.yaml --ref <tag>`), because a pull request job cannot
  reproduce those triggers. All other jobs are skipped on a tag ref.
- `nightly-test-released.yaml` has the same structure and tables and tests the last stable release. It
  only asserts the outcome and the failure stage, because the release has no `failed-check` output
  yet, and it lacks the rows of features that are not released yet.

### Workflows

Files in `.github/workflows/` are prefixed by role:

| Prefix / file              | Role                                                                               |
| -------------------------- | ---------------------------------------------------------------------------------- |
| `ci.yaml`                  | Entry point (PRs, pushes to `main`, nightly, manual); calls the reusable workflows |
| `ci-format.yaml`           | Checks formatting and lints shell and YAML files                                   |
| `ci-action.yaml`           | Tests the unreleased action against the fixtures                                   |
| `ci-verify-workflows.yaml` | Lints the workflow files; separate triggers so it can be a required check          |
| `lib-get-test-matrix.yaml` | Loads the OS and Python version matrices once                                      |
| `nightly*.yaml`            | Nightly tests of the last stable release                                           |
| `security-*.yaml`          | Dependency review and OSSF Scorecard                                               |
| `bot-*.yaml`               | Scheduled automation (pin actions, sync `.make/`, format files, cancel stale runs) |

## License

Distributed under the [BSD 3-Clause License](LICENSE).
