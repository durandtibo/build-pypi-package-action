# Security Policy

## Supported Versions

Security fixes are only released for the latest release of the action, published as an immutable
`vX.Y.Z` tag. There are no floating tags. Older releases are not patched, so please upgrade to the
latest release before reporting an issue.

## Reporting a Vulnerability

The `build-pypi-package-action` team takes security bugs seriously. We appreciate your efforts to
responsibly disclose your findings.

### Where to Report

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report security vulnerabilities privately using
[GitHub Security Advisories](https://github.com/durandtibo/build-pypi-package-action/security/advisories/new).

### What to Expect

- We will acknowledge receipt of your report within **5 business days**.
- We will provide an initial assessment (including whether the report is accepted, and an
  estimated timeline for a fix) within **10 business days** of acknowledgment.

### What to Include

Please include the following information in your report:

- Type of issue (e.g., script injection, secret exposure, bypass of a release guard, etc.)
- The affected step in `action.yml` or file in the repository
- The affected version (tag, branch or commit)
- Any special configuration required to reproduce the issue (inputs, runner OS, event type)
- Step-by-step instructions to reproduce the issue
- Proof-of-concept (if possible)
- Impact of the issue, including how an attacker might exploit the issue

This information will help us triage your report more quickly.

### Security Update Policy

- Security updates will be released as soon as possible
- Security updates will be clearly marked in release notes
- We will notify users through GitHub releases and other appropriate channels

## Known Security Considerations

This action builds and validates a Python package, then uploads it as an artifact. It does not
publish to PyPI and needs no secrets.

- **The package's build backend runs arbitrary code**: building the sdist and wheel executes the
  build backend and any build requirements of the package, with the permissions of the job. Only
  run the action on code you trust. Be careful with `pull_request_target` or other triggers that
  check out code from forks.
- **Least-privilege permissions**: the action needs only read access to the repository contents.
  Grant it no more in your workflow, and keep publishing credentials out of the job that builds.
- **Pinned tools**: `uv` and `twine` are pinned by the defaults of the `uv-version` and
  `twine-version` inputs; `twine-exclude-newer` (dependency date pin) is off by default.
  Overriding them is your responsibility.
- **PyPI duplicate check**: the check queries the public PyPI JSON API for the package name and
  version. Only an HTTP 404 means "not published"; any other answer fails the build.
- **Pin the action**: reference the action by commit SHA (or a full `vX.Y.Z` tag) in your
  workflows. Release tags are immutable and there are no floating tags.
