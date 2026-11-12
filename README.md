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

1. Installs `uv` and the requested Python version ([`astral-sh/setup-uv`](https://github.com/astral-sh/setup-uv)).
2. Builds the sdist and wheel with `uv build --clear`, and fails unless `dist/` holds exactly one of each.
3. Validates the built distributions' metadata with `twine check --strict`.
4. Extracts the package name and version from `pyproject.toml`
   ([`durandtibo/extract-pyproject-metadata-action`](https://github.com/durandtibo/extract-pyproject-metadata-action)).
5. **Guard — manual runs:** on `workflow_dispatch`, fails unless the version is a dev/pre-release
   (e.g. `1.2.3a1`, `1.2.3.dev1`). Plain release versions (`1.2.3`) must go through a tag push instead.
6. **Guard — tag pushes:** on any tag push (`refs/tags/*`), strips the leading `v` from the tag name and
   fails unless the result equals the package version (`v1.2.3` ↔ `1.2.3`). A tag that does not follow
   the `vX.Y.Z` convention therefore fails too.
7. **Guard — duplicate releases:** queries `https://pypi.org/pypi/<name>/<version>/json` (name
   normalized per PEP 503, 20 s timeout, 3 retries) and passes only on an HTTP 404. A 200 fails
   because the version is already published; any other answer (network error, 429, 5xx) fails too,
   because the check could not prove the version is free. It needs network access to PyPI and does
   not detect versions on other indexes (e.g. TestPyPI).
8. Smoke-tests the wheel and the sdist by installing each into a throwaway environment and importing the
   package in isolated mode.
9. Generates a `SHA256SUMS` checksum file alongside the distributions (`sha256sum`, or `shasum -a 256`
   where `sha256sum` is missing).
10. Uploads `dist/` (wheel, sdist, checksums) as a workflow artifact, kept for 5 days.

Every step is fail-closed: the first failing check stops the job, and nothing is uploaded after it.
The steps use `bash` and work on Linux, macOS, and Windows (Git Bash) runners.

## Requirements

The calling repo must provide, at its root:

| Requirement      | Notes                                                    |
| ---------------- | -------------------------------------------------------- |
| `pyproject.toml` | Must resolve a `name` and `version` (static or dynamic). |

- The calling job must check out the repo (`actions/checkout`) before this action runs.
- The package must be buildable with `uv build` (any PEP 517 build backend), and its importable module
  name must match the distribution name with `-` and `.` replaced by `_` (e.g. `my-package` →
  `my_package`), because the smoke test imports that module.
- The action builds in the repo root and writes to `dist/`. Existing contents of `dist/` are removed
  first.
- `dist/` must end up with exactly one wheel and one sdist (`.tar.gz`).

## Inputs

| Name             | Description                                              | Required | Default |
| ---------------- | -------------------------------------------------------- | -------- | ------- |
| `python-version` | Python version used to build and smoke-test the package. | No       | `3.14`  |
| `artifact-name`  | Name of the uploaded distribution artifact.              | No       | `dist`  |

The `python-version` is used for the build and for the smoke test; the package is not tested against
other versions, so run your own test matrix separately.

## Outputs

| Name              | Description                                      |
| ----------------- | ------------------------------------------------ |
| `package-name`    | Package name extracted from `pyproject.toml`.    |
| `package-version` | Package version extracted from `pyproject.toml`. |

The outputs are available once the metadata has been extracted (after the build and the `twine`
check). If an earlier step fails, the action fails and the outputs are empty.

## Usage

### Basic

```yaml
- uses: actions/checkout@v7

- name: Build package
  uses: durandtibo/build-pypi-package-action@v0.0.2
  with:
    python-version: "3.14"
```

### Reading the outputs

```yaml
- name: Build package
  id: build
  uses: durandtibo/build-pypi-package-action@v0.0.2

- name: Show package metadata
  env:
    PACKAGE_NAME: ${{ steps.build.outputs.package-name }}
    PACKAGE_VERSION: ${{ steps.build.outputs.package-version }}
  run: echo "${PACKAGE_NAME} ${PACKAGE_VERSION}"
```

### Custom artifact name

```yaml
- name: Build package
  uses: durandtibo/build-pypi-package-action@v0.0.2
  with:
    artifact-name: my-package-dist
```

### End-to-end release workflow

Runs on both manual dispatch (dry run with a pre-release version) and tag pushes (real release), and only
publishes on the tag push. Publishing uses
[PyPI trusted publishing](https://docs.pypi.org/trusted-publishers/), which needs `id-token: write`
(configure the trusted publisher on PyPI first). Pin third-party actions to commit SHAs in your own
workflows.

```yaml
name: Release

on:
  workflow_dispatch:
  push:
    tags:
      - "v*"

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # trusted publishing
    steps:
      - uses: actions/checkout@v7

      - name: Build package
        id: build
        uses: durandtibo/build-pypi-package-action@v0.0.2

      - name: Publish to PyPI
        if: startsWith(github.ref, 'refs/tags/')
        uses: pypa/gh-action-pypi-publish@release/v1
```

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

- `test/fixtures/` holds throwaway packages (success path, edge cases such as dotted names and dynamic
  versions, and failure paths such as a failing build, invalid metadata, an unimportable package, an
  already-published version, and a plain version on a manual run). They are not part of the action.
- `scripts/test-helper.sh` holds the assertions shared by the test workflows.
- `ci-action.yaml` runs the action from the current checkout (`uses: ./`) against the fixtures on
  Linux, macOS, and Windows, and on every Python version on Linux. Failure jobs also assert the stage
  at which the action failed.
- `nightly-test-released.yaml` runs the same tests against the last stable release.

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
