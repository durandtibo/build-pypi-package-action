#!/usr/bin/env bash
# Shared assertions of ci-action.yaml, which tests both the current checkout and the last
# stable release (input use-released), so the two only differ in which build-package action
# ref they exercise, not in verification logic.
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

# assert_hashes <hashes>
# The hashes output is the base64 of one "<sha256>  ./<file>" line per file of dist/ (sdist, wheel).
assert_hashes() {
	local decoded
	decoded=$(printf '%s' "$1" | base64 --decode) || {
		echo "::error::hashes output is not valid base64: $1"
		return 1
	}
	[[ "$(printf '%s\n' "${decoded}" | grep -cE '^[0-9a-f]{64}  \./')" -eq 2 ]] &&
		[[ "${decoded}" == *.tar.gz* && "${decoded}" == *.whl* ]] || {
		echo "::error::unexpected hashes output: ${decoded}"
		return 1
	}
}

# assert_dist_built <checksum-file>
# The action built one wheel and one sdist; dist/SHA256SUMS exists only when checksum-file is "true",
# and then it must verify the files.
assert_dist_built() {
	ls dist/*.whl dist/*.tar.gz
	if [[ "${1:?checksum-file (true or false) required}" == "true" ]]; then
		(cd dist && { sha256sum --check SHA256SUMS 2>/dev/null || shasum -a 256 --check SHA256SUMS; }) || {
			echo "::error::dist/SHA256SUMS is missing or does not match the files"
			return 1
		}
		# The signer (sign-pypi-package-action) accepts only plain file names, no ./ prefix.
		local bad
		bad=$(grep -vE '^[0-9a-f]{64} [ *][A-Za-z0-9][A-Za-z0-9._+-]*\.(tar\.gz|whl)$' dist/SHA256SUMS || true)
		test -z "${bad}" || {
			echo "::error::dist/SHA256SUMS has lines the signer rejects: ${bad}"
			return 1
		}
	else
		test ! -e dist/SHA256SUMS || {
			echo "::error::dist/SHA256SUMS exists, but checksum-file is not set"
			return 1
		}
	fi
}

# assert_stale_dist_cleared
# Files placed in dist/ before the build must be gone: they must never leak into the artifact.
assert_stale_dist_cleared() {
	if test -e dist/stale-0.0.0-py3-none-any.whl || test -e dist/stale-0.0.0.tar.gz; then
		echo "::error::stale files from a previous build are still in dist/"
		exit 1
	fi
}

# stage_oversized_file <dir>
# Writes 101 MiB of incompressible data into <dir>, above PyPI's 100 MiB limit,
# so that a package that ships it is rejected by the size check.
stage_oversized_file() {
	head -c $((101 * 1024 * 1024)) /dev/urandom >"$1/oversized.bin"
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
