#!/usr/bin/env bash
# Shared assertions for test-local.yaml and test-stable.yaml, so the two
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
assert_dist_artifact() {
	ls dist/*.whl dist/*.tar.gz dist/SHA256SUMS
	(cd dist && sha256sum --check SHA256SUMS)
}
