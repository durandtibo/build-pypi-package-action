# build-pypi-package-action

[![CI](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml/badge.svg)](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/durandtibo/build-pypi-package-action/badge)](https://scorecard.dev/viewer/?uri=github.com/durandtibo/build-pypi-package-action)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)
[![Latest release](https://img.shields.io/github/v/tag/durandtibo/build-pypi-package-action?label=release)](https://github.com/durandtibo/build-pypi-package-action/tags)

A composite GitHub Action that builds a Python package (sdist + wheel), validates it, and blocks the
workflow before a bad release can go out.

Point it at a repo with a `pyproject.toml`, and it builds the distributions with
`uv`, checks their metadata, verifies the version being built is actually safe to publish, smoke-tests the
wheel in a clean environment, and uploads everything as a workflow artifact — ready for a publish step
right after it.

## Why use it

Releasing a Python package to PyPI is unforgiving — you can't overwrite or delete a bad version once it's
up. This action exists to catch the usual ways that goes wrong _before_ the publish step runs:

- A `workflow_dispatch` dry run accidentally targets a real release version instead of a pre-release.
- A tag doesn't actually match the version in `pyproject.toml`.
- The version being built is already on PyPI (a duplicate/stale release).
- The wheel builds but doesn't actually install or import.

If any of these are true, the action fails the job and nothing gets published.

## How it works

1. Installs `uv` and the requested Python version ([`astral-sh/setup-uv`](https://github.com/astral-sh/setup-uv)).
2. Builds the sdist and wheel with `uv build --clear`, and fails unless `dist/` holds exactly one of each.
3. Validates the built distributions' metadata with `twine check --strict`.
4. Extracts the package name and version from `pyproject.toml`
   ([`durandtibo/extract-pyproject-metadata-action`](https://github.com/durandtibo/extract-pyproject-metadata-action)).
5. **Guard — manual runs:** on `workflow_dispatch`, fails unless the version is a dev/pre-release
   (e.g. `1.2.3a1`, `1.2.3.dev1`). Plain release versions (`1.2.3`) must go through a tag push instead.
6. **Guard — tag pushes:** on a `refs/tags/vX.Y.Z` push, fails unless the tag matches the package version.
7. **Guard — duplicate releases:** fails if that package name/version is already published on PyPI.
8. Smoke-tests the wheel and the sdist by installing each into a throwaway environment and importing the
   package in isolated mode.
9. Generates a `SHA256SUMS` checksum file alongside the distributions.
10. Uploads `dist/` (wheel, sdist, checksums) as a workflow artifact.

## Requirements

The calling repo must provide, at its root:

| Requirement      | Notes                                                    |
| ---------------- | -------------------------------------------------------- |
| `pyproject.toml` | Must resolve a `name` and `version` (static or dynamic). |

The calling job must also check out the repo (`actions/checkout`) before this action runs.

## Inputs

| Name             | Description                                              | Required | Default |
| ---------------- | -------------------------------------------------------- | -------- | ------- |
| `python-version` | Python version used to build and smoke-test the package. | No       | `3.14`  |
| `artifact-name`  | Name of the uploaded distribution artifact.              | No       | `dist`  |

## Outputs

| Name              | Description                                      |
| ----------------- | ------------------------------------------------ |
| `package-name`    | Package name extracted from `pyproject.toml`.    |
| `package-version` | Package version extracted from `pyproject.toml`. |

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
  run: echo "${{ steps.build.outputs.package-name }} ${{ steps.build.outputs.package-version }}"
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
publishes on the tag push:

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
    steps:
      - uses: actions/checkout@v7

      - name: Build package
        id: build
        uses: durandtibo/build-pypi-package-action@v0.0.2

      - name: Publish to PyPI
        if: startsWith(github.ref, 'refs/tags/')
        uses: pypa/gh-action-pypi-publish@release/v1
```

## License

Distributed under the [BSD 3-Clause License](LICENSE).
