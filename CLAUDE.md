# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yml`) that builds a Python package (sdist + wheel) with
`uv`, validates it (`twine check --strict`, version guards, PyPI duplicate check), smoke-tests
the wheel, and uploads `dist/` (wheel and sdist only) as an artifact. It exposes the outputs
`package-name` and `package-version` (read from the built wheel) and the diagnostic `failed-check`. All logic is inline in `action.yml`;
there is no separate script. `scripts/test-helper.sh` holds assertions shared by the test workflows, and
`test/fixtures/` holds throwaway packages that the test workflows build. Neither is part of the
action itself.

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
- Steps are small (one purpose, one failure id, about 15 lines), named `N.x` by topic (`0.x` setup,
  `1.x` build and package checks, `2.x` release guards, `3.x` smoke tests, `4.x` report and upload).
  A step that can fail calls `fail <id> <title> <what> <how to fix>` (defined in step 0.2); step 4.3
  publishes the id as the `failed-check` output (`unexpected` if no check failed), so there is no
  second place to edit. Give a step an `id:` only when a later step reads its outputs.
  Failure messages say what failed, why, and how to fix, with the values involved.
- Only an HTTP 404 from PyPI means "not published"; a 200 is a duplicate and anything else fails
  closed.
- `uv` and `twine` are pinned by the defaults of the inputs `uv-version` and `twine-version`
  (used by steps 0.1 and 1.9). `twine-exclude-newer` defaults to empty (disabled); when set,
  `--exclude-newer` pins twine's dependencies and is scoped to twine, never to the package's own
  build. Bump the two version defaults together (and the README table), deliberately, in their own PR with the quarterly review. Pinning actions does not
  cover them.
- The default `python-version` (`3.14`) is bumped together with the workflow config.

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
  `test/fixtures/` (or an extra assertion) and a row in `test/cases.json`, the single file with the
  case tables (`accept`, `reject`, `reject-manual`, `reject-tag-mismatch`). A row has `"released":
false` until the last release has the feature; the nightly workflow runs only the rows with
  `"released": true` (`scripts/load-cases.sh`). `ci-action.yaml` and `nightly-test-released.yaml` have
  the same structure: `build`/`build-python` (success path), `accept` (packages that must build),
  `reject` (packages that must fail, with the expected `failed-check` id), `reject-manual`
  (`workflow_dispatch` only), `reject-tag-mismatch` (tag ref only) and `verify-artifact`. They differ
  only in the `uses:` ref, in the artifact names and in the mode passed to
  `load-cases.sh`. A new case is a new row in `test/cases.json`, not a new job.
- Put assertions shared by both workflows in `scripts/test-helper.sh` so the two only differ in
  which action ref they exercise.
- Failure-path fixtures must assert that the action fails for the expected reason, not just that
  it fails: use `assert_failed_check <id> "${FAILED_CHECK}"` with the action's `failed-check` output
  (set `continue-on-error: true` on the action step). Assert the id, never the message text.
- `nightly-test-released.yaml` may only assert behaviour that exists in the last release. A case
  that needs a new feature (`failed-check`, ...) reaches it after the release that contains the
  feature; until then it keeps asserting the outcome only.
- `unexpected` has no row: its only trigger is an invalid input. Check it by hand after changing step
  4.3: run the action with `python-version: "9.9"` and `continue-on-error: true` and read
  `failed-check`.
- Every guard has a fixture row, except a closed list of review-only exceptions: `dist-contents`
  (no sane backend writes a second wheel) and the `published` check when PyPI is down (non-404
  answer). Add to this list only with a reason; a check no fixture can fail should not exist.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Release procedure

1. Merge to `main` with green checks, including `nightly.yaml` on the previous release.
2. Tag the commit `vX.Y.Z` (immutable) and create the GitHub release; list breaking changes in the
   notes.
3. Do not create or move a floating major tag (`vX`): releases are only immutable `vX.Y.Z` tags.
4. Update the version and SHA in the `uses:` refs and in the header of
   `nightly-test-released.yaml`, flip `released` to `true` in `test/cases.json` for the features of the new release, and update the
   `@vX.Y.Z` version in the README examples.

## Reporting

- State which checks ran (`make lint`, `make format`) and which did not.
- Note that CI was not awaited, and that the workflow tests only run on GitHub.
- Report failures that already exist on `main` rather than hiding them.
