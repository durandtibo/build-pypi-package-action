# build-pypi-package-action

GitHub Action to build a Python package (sdist + wheel) with uv/invoke, validate its metadata, and smoke-test the wheel.

## What it does

1. Installs `uv` and sets up the requested Python version.
2. Installs the calling repo's task runner via `make install-invoke`.
3. Builds the package by running `build-command` (default: `inv build-package`).
4. Validates the built distributions' metadata with `twine check --strict`.
5. Extracts the package name/version from `pyproject.toml`.
6. On a manual (`workflow_dispatch`) run, fails if the version is a plain release version (only dev/pre-release versions are allowed).
7. On a tag push, fails if the tag (`vX.Y.Z`) doesn't match the package version.
8. Fails if the package name/version is already published on PyPI.
9. Smoke-tests the built wheel by installing it into a clean venv and importing it.
10. Generates a `SHA256SUMS` checksum file for the distributions.
11. Uploads the distributions (and checksums) as the `dist` artifact.

## Requirements

The calling repo must provide:

- `make install-invoke`
- An invoke task matching `build-command` (default: `inv build-package`) that builds sdist + wheel into `dist/`
- A `pyproject.toml` at the repo root

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

```yaml
- name: Build package
  uses: durandtibo/build-pypi-package-action@v1
  with:
    python-version: "3.14"
```
