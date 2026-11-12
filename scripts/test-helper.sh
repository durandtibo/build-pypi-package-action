#!/usr/bin/env bash
# Shared assertions for ci-action.yaml and nightly-test-released.yaml, so the two
# workflows only differ in which build-package action ref they exercise
# (local checkout vs. last stable release), not in verification logic.
set -euo pipefail

# assert_metadata <actual-name> <actual-version> <expected-name> <expected-version>
assert_metadata() {
	local actual_name="$1" actual_version="$2" expected_name="$3" expected_version="$4"

	test "${actual_name}" = "${expected_name}" || {
		echo "::error::unexpected package-name output: ${actual_name}"
		exit 1
	}
	test "${actual_version}" = "${expected_version}" || {
		echo "::error::unexpected package-version output: ${actual_version}"
		exit 1
	}
}

# assert_dist_built
# The action built one wheel and one sdist.
assert_dist_built() {
	ls dist/*.whl dist/*.tar.gz
	test ! -e dist/SHA256SUMS || {
		echo "::error::dist/SHA256SUMS exists, but the action no longer writes checksums"
		exit 1
	}
}

# assert_stale_dist_cleared
# Files placed in dist/ before the build must be gone: they must never leak into the artifact.
assert_stale_dist_cleared() {
	if test -e dist/stale-0.0.0-py3-none-any.whl || test -e dist/stale-0.0.0.tar.gz; then
		echo "::error::stale files from a previous build are still in dist/"
		exit 1
	fi
}

# assert_released_dist_built
# Same for the last released action, which still writes dist/SHA256SUMS.
# Used by nightly-test-released.yaml only; remove it, and the *_released helpers
# below, once the nightly suite runs a release without checksums.
assert_released_dist_built() {
	ls dist/*.whl dist/*.tar.gz dist/SHA256SUMS
}

# assert_failure <label> <actual-outcome>
assert_failure() {
	local label="$1" actual_outcome="$2"

	test "${actual_outcome}" = "failure" || {
		echo "::error::expected ${label} to fail, got outcome=${actual_outcome}"
		exit 1
	}
}

# assert_failed_check <expected> <actual>
# The action must have failed in the expected check (its failed-check output),
# not just failed. Tests assert the id, never the message text.
assert_failed_check() {
	local expected="$1" actual="$2"

	test "${actual}" = "${expected}" || {
		echo "::error::expected failed-check=${expected}, got '${actual}'"
		exit 1
	}
}

# assert_dist_artifact
# The downloaded artifact must hold exactly one wheel and one sdist, nothing
# else, so that a publish job can upload the directory as is.
assert_dist_artifact() {
	ls dist/*.whl dist/*.tar.gz
	# uv writes dist/.gitignore when --out-dir is given; hidden files are not
	# uploaded, so they are ignored here to give the local dist/ and the
	# downloaded artifact the same expectation.
	test "$(find dist -mindepth 1 -not -name .gitignore | wc -l)" -eq 2 || {
		echo "::error::unexpected files in dist/: $(find dist -mindepth 1 -not -name .gitignore)"
		exit 1
	}
}

# assert_released_dist_artifact
# Same for the last released action: wheel, sdist and checksums that cover
# exactly those two files and verify. See assert_released_dist_built.
assert_released_dist_artifact() {
	ls dist/*.whl dist/*.tar.gz dist/SHA256SUMS
	test "$(find dist -mindepth 1 -not -name .gitignore | wc -l)" -eq 3 || {
		echo "::error::unexpected files in dist/: $(find dist -mindepth 1)"
		exit 1
	}
	test "$(wc -l <dist/SHA256SUMS)" -eq 2 || {
		echo "::error::SHA256SUMS should list exactly 2 files"
		exit 1
	}
	(cd dist && sha256sum --check SHA256SUMS)
}

# assert_released_failed_stage <expected-failed-check>
# The last release has no failed-check output, so only the stage is asserted:
# before the distributions exist when the build itself was expected to fail
# (expected = build), after they were built otherwise.
assert_released_failed_stage() {
	if test "$1" = "build"; then
		assert_failed_during_build
	else
		assert_failed_after_build
	fi
}

# assert_failed_during_build
# The action must have failed before producing any distribution.
assert_failed_during_build() {
	if compgen -G "dist/*.whl" >/dev/null || compgen -G "dist/*.tar.gz" >/dev/null; then
		echo "::error::dist/ holds distributions, but the build was expected to fail"
		exit 1
	fi
}

# assert_failed_after_build
# For the last released action only (it has no failed-check output): see
# assert_released_dist_built.
# The distributions were built, but the action failed in a later check
# (metadata, guards, smoke test) before checksums and upload.
assert_failed_after_build() {
	ls dist/*.whl dist/*.tar.gz
	test ! -e dist/SHA256SUMS || {
		echo "::error::dist/SHA256SUMS exists, so the action got past its checks"
		exit 1
	}
}
