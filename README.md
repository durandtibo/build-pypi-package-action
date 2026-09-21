# build-pypi-package-action

[![CI](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml/badge.svg)](https://github.com/durandtibo/build-pypi-package-action/actions/workflows/ci.yaml)
[![License](https://img.shields.io/github/license/durandtibo/build-pypi-package-action)](LICENSE)

A composite GitHub Action that builds a Python package (sdist + wheel) with `uv`/`invoke`, validates its
metadata, guards against publishing mistakes, smoke-tests the wheel, and uploads the distributions as a
workflow artifact.

It's meant to run before a PyPI publish step, so a broken or already-released package never gets that far.

## What it does

1. Installs `uv` and sets up the requested Python version (`astral-sh/setup-uv`).
2. Installs the calling repo's task runner via `make install-invoke`.
3. Builds the package by running `build-command` (default: `inv build-package`).
4. Validates the built distributions' metadata with `twine check --strict`.
5. Extracts the package name/version from `pyproject.toml` (`durandtibo/extract-pyproject-metadata-action`).
6. On a manual (`workflow_dispatch`) run, fails if the version is a plain release version — only
   dev/pre-release versions (e.g. `1.2.3a1`, `1.2.3.dev1`) are allowed.
7. On a tag push (`refs/tags/vX.Y.Z`), fails if the tag doesn't match the package version.
8. Fails if the package name/version is already published on PyPI.
9. Smoke-tests the built wheel by installing it into a clean venv and importing it.
10. Generates a `SHA256SUMS` checksum file for the distributions.
11. Uploads the distributions (and checksums) as a workflow artifact.

These checks exist to catch the common ways a release goes wrong: a stale/duplicate version, a manual
dry run that accidentally targets a real release version, a tag/version mismatch, or a wheel that fails
to install/import.

## Requirements

The calling repo must provide, at its root:

- `make install-invoke` — a Makefile target that installs `invoke`.
- An invoke task matching `build-command` (default: `inv build-package`) that builds sdist + wheel into
  `dist/`.
- A `pyproject.toml` with `name` and `version` (or equivalent dynamic metadata resolvable by
  `extract-pyproject-metadata-action`).

The job must also check out the repo (`actions/checkout`) before calling this action.

## Inputs

| Name             | Description                                             | Required | Default             |
| ---------------- | ------------------------------------------------------- | -------- | ------------------- |
| `python-version` | Python version used to build and smoke test the package | No       | `3.14`              |
| `artifact-name`  | Name of the uploaded distribution artifact              | No       | `dist`              |
| `build-command`  | Command used to build the package                       | No       | `inv build-package` |

## Outputs

| Name              | Description                                     |
| ----------------- | ----------------------------------------------- |
| `package-name`    | Package name extracted from `pyproject.toml`    |
| `package-version` | Package version extracted from `pyproject.toml` |

## Usage

### Basic

```yaml
- name: Build package
  uses: durandtibo/build-pypi-package-action@v0.0.2
  with:
    python-version: "3.14"
```

### Using the outputs

```yaml
- name: Build package
  id: build
  uses: durandtibo/build-pypi-package-action@v0.0.2

- name: Show package metadata
  run: echo "${{ steps.build.outputs.package-name }} ${{ steps.build.outputs.package-version }}"
```

### Custom build command and artifact name

```yaml
- name: Build package
  uses: durandtibo/build-pypi-package-action@v0.0.2
  with:
    build-command: inv custom-build
    artifact-name: my-package-dist
```

### Full release workflow

A typical setup runs this action on both manual dispatch (with a pre-release version, to dry-run the
pipeline) and on tag pushes (to publish a real release):

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

See [LICENSE](LICENSE).
