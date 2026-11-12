#!/usr/bin/env bash
# Writes the test matrices of ci-action.yaml and nightly-test-released.yaml to
# $GITHUB_OUTPUT, one output per job (accept, reject, reject-manual,
# reject-tag-mismatch), from the single case file test/cases.json.
# Usage: load-cases.sh <all|released>
#   all       every row (the current checkout)
#   released  only the rows with "released": true, i.e. the features that the
#             last stable release has
set -euo pipefail

mode="${1:?usage: load-cases.sh <all|released>}"
case "${mode}" in
all) released_only=false ;;
released) released_only=true ;;
*)
	echo "::error::unknown mode '${mode}', expected all or released"
	exit 1
	;;
esac

for job in accept reject reject-manual reject-tag-mismatch; do
	matrix=$(jq -c --arg job "${job}" --argjson released_only "${released_only}" \
		'{include: [.[$job][] | select(.released or ($released_only | not))]}' test/cases.json)
	echo "${job}=${matrix}" >>"${GITHUB_OUTPUT}"
done
