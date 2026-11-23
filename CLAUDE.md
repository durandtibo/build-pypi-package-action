# CLAUDE.md

Guidance for coding agents working in this repository.

## Repository purpose

A GitHub composite action (`action.yaml`) that builds a Python package (sdist + wheel) with
`uv`, validates it (`twine check --strict`, version guards, PyPI duplicate check), smoke-tests
the wheel, and uploads `dist/` (wheel and sdist only) as an artifact. It exposes the outputs
`package-name` and `package-version` (read from the built wheel) and the diagnostic `failed-check`.
All logic is inline in `action.yaml`; there is no separate script. `scripts/test-helper.sh`
(assertions shared by the test jobs), `scripts/load-cases.sh` (turns `test/cases.json` into job
matrices), `test/fixtures/` (throwaway packages that the test workflows build), `dev/check_export.sh`
(maintainer check of the exported files) and `dev/check_readme.sh` (maintainer check that the README
documents the inputs and outputs of `action.yaml`) are not part of the action itself. It is tested on
Linux, macOS and Windows (Git Bash) and on every standard Python version; the README claims all of
them, so every OS and Python version claimed is in a test matrix and every cell of a matrix is
claimed.

## Environment

- Use the `Makefile`; run `make help` to list targets.
- Do not edit `.make/`: it is a shared directory synced by `bot-sync-shared-makefile.yaml`.
- Run `make format` and `make lint` before committing. Fix what they report instead of disabling
  rules.
- The action can only be exercised end to end by GitHub Actions (`ci-action.yaml`). Say so in the
  PR instead of claiming those tests pass locally. `make test` (`make check-export` and
  `make check-readme`) runs locally.

## Git workflow

- One branch and one PR per logical change, branched from an up-to-date `main`. Never commit or
  push to `main`.
- Name branches `<type>/<short-description>` in kebab-case, with type one of: `feat`, `bugfix`,
  `hotfix`, `docs`, `refactor`, `perf`, `test`, `chore`, `ci`.
- Write commit messages and PR titles as a short imperative sentence starting with a verb such as
  `Add`, `Fix`, `Update`, `Remove` or `Improve`. Do not use conventional-commit prefixes like
  `docs:` or `feat:` (the type prefix is only for branch names). The squash-merge appends the PR
  number, so do not add one.
- PR descriptions cover what changed, what was deliberately left alone, and any behaviour change.
- Do not escape special characters such as the backtick (`` ` ``) in PR titles and descriptions
  (no `\``): the escape characters are not rendered well. Write them as plain Markdown.
- On conflicts with `main`, merge `origin/main` into the branch; do not rebase and force-push.
- Update `README.md` when inputs, outputs, behaviour, or workflows change.
- Releases are immutable exact version tags (`v0.1.0`, ...). Do not create or move floating tags
  (`v0`, `latest`) and do not document them as an option (see the release procedure below).

## Action rules (`action.yaml`)

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
  A step that can fail calls `fail <id> <title> <what> <how to fix>` (defined in step 0.2); step 4.4
  publishes the id as the `failed-check` output (`unexpected` if no check failed), so there is no
  second place to edit. Give a step an `id:` only when a later step reads its outputs.
  Failure messages say what failed, why, and how to fix, with the values involved.
- Only an HTTP 404 from PyPI means "not published"; a 200 is a duplicate and anything else fails
  closed.
- `uv` and `twine` are pinned by the defaults of the inputs `uv-version` and `twine-version`
  (used by steps 0.1 and 1.9). `twine-exclude-newer` defaults to empty (disabled); when set,
  `--exclude-newer` pins twine's dependencies and is scoped to twine, never to the package's own
  build. Bump the two version defaults together (and the README table), deliberately, in their own
  PR with the quarterly review. Pinning actions does not
  cover them.
- The default `python-version` (`3.14`) is bumped together with the workflow config.
- Only ship what the action needs at runtime: files the action itself uses (`action.yaml`,
  `LICENSE`) are exported, and `.gitattributes` marks everything else `export-ignore`. When the
  action starts using a new file, un-ignore it there and add it to `EXPECTED` in
  `dev/check_export.sh`. Never make the action read tests, fixtures or other repo files that are not
  exported. Check the exported set with `make check-export` (or `git archive --worktree-attributes
HEAD | tar t`).

## Shell script rules (`scripts/*.sh`, `dev/*.sh`)

These scripts are maintainer and test tooling, not part of the action, and run on the CI runners
(`scripts/test-helper.sh` is sourced by the test jobs on Linux, macOS and Windows Git Bash).

- Keep them portable across those platforms (no GNU-only flags in `scripts/test-helper.sh`).
- Start with `set -euo pipefail`. Quote all variables and validate inputs early with a clear
  `::error::` message.
- Keep logic in small functions (one assertion per function in `scripts/test-helper.sh`, no fixture
  knowledge in it).
- Code must pass `shellcheck` and `shfmt` via `make lint` / `make format`.
- A function that can fail is followed by an explicit `return 1` on failure
  (`cmd || { echo "::error::..."; return 1; }`). Never rely on `set -e`: a caller in an `||` list
  turns it off.

## Workflow structure (`.github/workflows/`)

Files are prefixed by role, mirroring `durandtibo/cancel-queued-runs-action`:

- `ci.yaml`: entry point for pull requests, pushes to `main`, a nightly schedule and manual runs. It
  holds no steps, only jobs that call the reusable workflows below.
  - `lib-get-test-matrix.yaml`: loads the lists from `durandtibo/workflow-config-action` once, and
    exposes them as the `test_matrix` output with the keys that every action repository has:
    `os_matrix` (Linux, macOS and Windows, from `os_all`, because the README claims Windows),
    `os_macos`, `os_latest` (the `*-latest` runners), `python_versions` and
    `python_versions_standard`. Callers pass it down; never hard-code OS or Python lists in a
    workflow.
  - `ci-format.yaml`: two jobs. `format` checks that YAML, Makefile, shell, and Markdown files are
    formatted (`make format` followed by `git diff --exit-code`); `lint` runs `make lint` (YAML,
    Makefile, shell, Markdown and the workflow files with actionlint), so CI and a local run use
    the same target.
  - `ci-export.yaml`: checks the exported set (`make check-export`, `dev/check_export.sh`).
  - `ci-readme.yaml`: checks that the README inputs, outputs and defaults match `action.yaml`
    (`make check-readme`, `dev/check_readme.sh`).
  - `ci-action.yaml`: the one reusable test workflow, with a boolean input `use-released`. `ci.yaml`
    calls it with `false`: the action from this checkout (`uses: ./`), i.e. the version not
    released yet. `nightly.yaml` calls it with `true`: the last release. It runs against the
    fixtures in `test/fixtures/` and covers the success path and the failure paths (already-published
    version, plain version on a manual run, failing build).
- `nightly.yaml`: scheduled entry point that calls `ci-action.yaml` with `use-released: true`. It is
  not part of `ci.yaml`. There is no separate released-action workflow: update the version in the
  header comment of `ci-action.yaml` and in its `uses:` refs when a new release is made.
- `ci-verify-workflows.yaml`: lints the workflow files themselves. It has its own triggers and
  is not called from `ci.yaml`, so it can be a required check.
- `security-dependency-review.yaml`: dependency review on pull requests.
- `security-scorecard.yaml`: OSSF Scorecard supply-chain analysis (weekly, on pushes to `main`, and
  manual runs); results go to the code-scanning dashboard.
- `bot-*.yaml`: scheduled automation that opens PRs or acts on runs (pin actions, sync `.make/`,
  format files, cancel stale queued runs).

Conventions:

- Set `permissions: {}` at the workflow level, and declare least-privilege `permissions` on each
  job (and on each job that calls a reusable workflow).
- Set `timeout-minutes` on every job.
- Each `ci-*` check is a `workflow_call` workflow that also has `workflow_dispatch`, so it can be
  run alone. Add a new check as a new `ci-<name>.yaml` plus a job in `ci.yaml`.
- Put `make` targets in the steps rather than duplicating commands, so local runs and CI match.
- Start each file with a comment saying what it does, and update it when the behaviour changes.

## Tests

- Tests are workflow-based: a new behaviour or guard in `action.yaml` needs a fixture under
  `test/fixtures/` (or an extra assertion) and a row in `test/cases.json`, the single file with the
  case tables (`accept`, `reject`, `reject-manual`, `reject-tag-mismatch`). A row has `"released":
false` until the last release has the feature; the released run (`use-released: true`) loads only
  the rows with `"released": true` (`scripts/load-cases.sh`). A new case is a new row in
  `test/cases.json`, not a new job.
- `ci-action.yaml` has these jobs: `test` (success path on the full matrix), `accept` (packages that
  must build), `reject` (packages that must fail, with the expected `failed-check` id),
  `reject-manual` (`workflow_dispatch` only), `accept-plain-version-outside-manual-run`,
  `reject-tag-mismatch` (tag ref only) and `test-export` (runs the action from the exported
  archive, so a file wrongly marked `export-ignore` fails; local run only).
- The full matrix is 18 OS x 5 Python versions = 90 cells per run (`workflow-config-action`
  v0.3.1), the same on pull requests, pushes and the schedule. Only `test` crosses it; update this
  count when the config changes.
- General behaviour is the `test` job only (the default usage, which also sets `artifact-name`):
  it is the one job that crosses `os_matrix` and `python_versions_standard`. Add a second job on the
  matrix (`test-<usage>`) only for a documented usage that the default does not cover, because each
  one costs 90 cells. Every other job is an edge case and runs on one runner.
- Every input has a case that sets it and shows that it reaches the step that uses it. An input
  that changes the outcome has a `reject` row whose value makes the step fail with the expected
  `failed-check` id (`twine-version`, `twine-exclude-newer`, `import-name`), or a row that asserts
  the effect (`artifact-name` in the `test` job). `python-version` is set by the `test` job on every
  version, and `uv-version` by every run (the default); an invalid value of these two fails before
  any check runs and ends as `unexpected` (see below), so it is a manual check.
- Assert the value or the format of the outputs (`assert_metadata`), never just print them.
- Put assertions in `scripts/test-helper.sh`, not in the workflow, so the local and the released run
  share them.
- Failure-path fixtures must assert that the action fails for the expected reason, not just that
  it fails: use `assert_failed_check <id> "${FAILED_CHECK}"` with the action's `failed-check` output
  (set `continue-on-error: true` on the action step). Assert the id, never the message text.
- A case that needs a feature that the last release lacks (`failed-check`, ...) has
  `"released": false` and reaches the released run after the release that contains the feature.
- `unexpected` has no row: its only trigger is an invalid input. Check it by hand after changing step
  4.4: run the action with `python-version: "9.9"` and `continue-on-error: true` and read
  `failed-check`.
- Every guard has a fixture row, except a closed list of review-only exceptions: `dist-contents`
  (no sane backend writes a second wheel) and the `published` check when PyPI is down (non-404
  answer). Add to this list only with a reason; a check no fixture can fail should not exist.
- What cannot be tested in CI is written down with the check that covers it: the trigger-dependent
  jobs (header of `ci-action.yaml`), `unexpected` (by hand, above) and the review-only guards.
- Every bug fix needs a regression test that fails without the fix.
- If a check fails for a real reason, report it rather than weakening the test.

## Testing strategy

The strategy is the same for all the action repositories of `durandtibo`. The full reasoning and
the properties (T1 to T16) are in `review/testing.md` of `durandtibo/cancel-queued-runs-action`.
This repository follows it: the action cases are the rows of `test/cases.json`, read by
`ci-action.yaml`.

Three levels:

1. **Code**: each script or function, tested alone with mocks. This repository has no level 1: all
   the logic is inline in `action.yaml`, so it is tested only through the action (the README says so).
   If logic moves to scripts, test them with bats and add a `ci-shell.yaml`.
2. **Local action**: the action from this checkout (`uses: ./`) in a real workflow.
3. **Released action**: the latest stable release (`uses: durandtibo/build-pypi-package-action@<sha>`),
   run nightly with the same cases as level 2. Never run it on pull requests.

Rules:

- Test a behaviour at the cheapest level that can show it. The action tests (levels 2 and 3) check
  the contract and the wiring: inputs reach the steps, outputs are set, the action fails with the
  right `failed-check` id. Because the logic is inline, the guards are tested here, one fixture row
  per guard.
- Split the action tests in two. **General behaviour** (the default usage) runs on the full matrix:
  `os_matrix` (Linux, macOS, Windows) crossed with `python_versions_standard`, because the action
  runs in the user's Python. **Edge cases** (one input, one invalid value, an unusual file) run on one
  runner, or on `os_latest` when the case depends on the OS. There is no reduced matrix on pull
  requests: the same matrix runs on pull requests, pushes and the schedule.
- Never write an OS or a Python version in a workflow: read the lists from
  `durandtibo/workflow-config-action` through `lib-get-test-matrix.yaml`.
- Layout: one reusable `ci-action.yaml` with a boolean input `use-released`. `ci.yaml` calls it with
  `false`, `nightly.yaml` with `true`. Each job has two action steps, `uses: ./` with
  `if: ${{ !inputs.use-released }}` (`id: local`) and the pinned release with
  `if: ${{ inputs.use-released }}` (`id: released`), and one verify step reading
  `steps.local.outputs.x || steps.released.outputs.x`.
- Put the cases in a JSON file (a new case is a row, not a job). A row has `"released": false` until
  the last release has the feature; the released run skips those rows.
- Failure paths use `continue-on-error: true`, an `id`, and a step that asserts the outcome and the
  `failed-check` id. Assert an id or an exact output, not a message. A negative test needs a positive
  run before it, so it cannot pass for the wrong reason (the `test` job and `accept` rows are the
  positive controls for the `reject` rows).
- Tests have no side effects outside the runner: throwaway packages and artifacts, no publishing.
  Cases that depend on the trigger (`workflow_dispatch`, a tag ref) run in their own job with an
  `if`, and the header of `ci-action.yaml` says how to run them by hand.
- Check what is shipped: the exported set (`make check-export`) must contain every file the action
  needs, because `uses: ./` runs the whole checkout and hides a missing file.
- Set `timeout-minutes`, `fail-fast: false` and `max-parallel` on matrix jobs.
- Keep the README inputs and outputs in step with `action.yaml`.

## Release procedure

1. Merge to `main` with green checks, including `nightly.yaml` on the previous release.
2. Tag the commit `vX.Y.Z` (immutable) and create the GitHub release; list breaking changes in the
   notes.
3. Do not create or move a floating major tag (`vX`): releases are only immutable `vX.Y.Z` tags.
4. Update the version and SHA in the `uses:` refs and in the header of `ci-action.yaml`, flip
   `released` to `true` in `test/cases.json` for the features of the new release, and update the
   `@vX.Y.Z` version in the README examples.

## Reporting

- State which checks ran (`make lint`, `make format`, `make check-export`, `make check-readme`) and
  which did not.
- Note that CI was not awaited, and that the workflow tests only run on GitHub.
- Report failures that already exist on `main` rather than hiding them.
