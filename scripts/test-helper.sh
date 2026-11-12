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
assert_dist_built() {
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

# assert_dist_artifact
# The downloaded artifact must hold exactly one wheel, one sdist and checksums
# that cover exactly those two files and verify.
assert_dist_artifact() {
	ls dist/*.whl dist/*.tar.gz dist/SHA256SUMS
	test "$(find dist -mindepth 1 | wc -l)" -eq 3 || {
		echo "::error::unexpected files in dist/: $(find dist -mindepth 1)"
		exit 1
	}
	test "$(wc -l <dist/SHA256SUMS)" -eq 2 || {
		echo "::error::SHA256SUMS should list exactly 2 files"
		exit 1
	}
	(cd dist && sha256sum --check SHA256SUMS)
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
# The distributions were built, but the action failed in a later check
# (metadata, guards, smoke test) before checksums and upload.
assert_failed_after_build() {
	ls dist/*.whl dist/*.tar.gz
	test ! -e dist/SHA256SUMS || {
		echo "::error::dist/SHA256SUMS exists, so the action got past its checks"
		exit 1
	}
}
