# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yml`) that builds a Python package (sdist + wheel) with
`uv`, validates it (`twine check --strict`, version guards, PyPI duplicate check), smoke-tests
the wheel, writes `SHA256SUMS`, and uploads `dist/` as an artifact. It exposes the outputs
`package-name` and `package-version`. All logic is inline in `action.yml`; there is no separate
script. `scripts/test-helper.sh` holds assertions shared by the test workflows, and
`test/fixtures/` holds throwaway packages that the test workflows build. Neither is part of the
action itself. `test/fixtures/legacy-invoke/` is not a package: `nightly-test-released.yaml` copies
it next to the fixture because the released version still builds through invoke; remove it once the
released version builds with uv directly.

## Environment

- Use the `Makefile`; run `make help` to list targets.
- Do not edit `.make/`: it is a shared directory synced by `bot-sync-shared-makefile.yaml`.
- Run `make format` and `make lint` before committing. Fix what they report instead of disabling
  rules.
- The action can only be exercised end to end by GitHub Actions (`ci-action.yaml`). Say so in the
  PR instead of claiming those tests pass locally.

## Git workflow

- One branch and one PR per logical change, branched from an up-to-date `main`. Never commit or
  push to `main`.
- Name branches `<type>/<short-description>` in kebab-case, with type one of: `feat`, `bugfix`,
  `hotfix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`.
- PR descriptions cover what changed, what was deliberately left alone, and any behaviour change.
- On conflicts with `main`, merge `origin/main` into the branch; do not rebase and force-push.
- Update `README.md` when inputs, outputs, behaviour, or workflows change.

## Action rules (`action.yml`)

- Keep input and output names, defaults, and descriptions consistent with `README.md`. Renaming or
  removing an input or output is a breaking change and must be flagged.
- Pass inputs and step outputs to scripts through `env:`, never by interpolating `${{ }}`
  expressions in `run:`.
- Every `run:` step sets `shell: bash`.
- Pin third-party actions (in the action and in workflows) to commit SHAs with a
  `# ratchet:<owner>/<repo>@<tag>` comment, never to tags or branches.
- Keep the guard steps (manual-run pre-release check, tag/version match, PyPI duplicate check)
  fail-closed with a clear `::error::` message.
- Keep the shell steps portable across Linux, macOS, and Windows (Git Bash) runners, e.g. the
  `sha256sum`/`shasum` fallback.
- Add a comment above a step when its purpose is not obvious.

## Workflow structure (`.github/workflows/`)

Files are prefixed by role, mirroring `durandtibo/cancel-queued-runs-action`:

- `ci.yaml`: entry point for pull requests, pushes to `main`, a nightly schedule and manual runs. It
  holds no steps, only jobs that call the reusable workflows below.
  - `lib-get-test-matrix.yaml`: loads the OS list (`os_all`: Linux, macOS, Windows) and the Python
    versions from `durandtibo/workflow-config-action` once, and exposes them as the `test_matrix`
    output. Callers pass it down; never hard-code OS or Python lists in a workflow.
  - `ci-format.yaml`: checks that YAML, Makefile, shell, and Markdown files are formatted
    (`make format` followed by `git diff --exit-code`) and lints the shell and YAML files.
  - `ci-action.yaml`: runs the action from this checkout (`uses: ./`), i.e. the version not
    released yet, against the fixtures in `test/fixtures/` on every OS, and on every Python version
    on Linux. It covers the success path and the failure paths (already-published version, plain
    version on a manual run, failing build).
- `nightly.yaml`: nightly entry point for the last stable release. It calls
  `nightly-test-released.yaml`, the same tests as `ci-action.yaml` against the last stable
  release. Update the version in its header comment and in its `uses:` refs when a new release is
  made.
- `ci-verify-workflows.yaml`: lints the workflow files themselves. It has its own triggers and is
  not called from `ci.yaml`, so it can be a required check.
- `security-dependency-review.yaml`: dependency review on pull requests.
- `security-scorecard.yaml`: OSSF Scorecard supply-chain analysis (weekly, on pushes to `main`, and
  manual runs); results go to the code-scanning dashboard.
- `bot-*.yaml`: scheduled automation that opens PRs or acts on runs (pin actions, sync `.make/`,
  format files, cancel stale queued runs).

Conventions:

- Set `permissions: {}` at the workflow level, and declare least-privilege `permissions` on each
  job (and on each job that calls a reusable workflow).
- Set `timeout-minutes` on every job.
- Each reusable workflow also has `workflow_dispatch`, so it can be run alone. Add a new check as a
  new workflow plus a job in `ci.yaml`.
- Put `make` targets in the steps rather than duplicating commands, so local runs and CI match.
- Start each file with a comment saying what it does, and update it when the behaviour changes.

## Tests

- Tests are workflow-based: a new behaviour or guard in `action.yml` needs a fixture under
  `test/fixtures/` (or an extra assertion) and a job in both `ci-action.yaml` and
  `nightly-test-released.yaml` where applicable.
- Put assertions shared by both workflows in `scripts/test-helper.sh` so the two only differ in
  which action ref they exercise.
- Failure-path fixtures must assert that the action fails for the expected reason, not just that
  it fails.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Reporting

- State which checks ran (`make lint`, `make format`) and which did not.
- Note that CI was not awaited, and that the workflow tests only run on GitHub.
- Report failures that already exist on `main` rather than hiding them.
