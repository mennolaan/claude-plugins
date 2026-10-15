#!/usr/bin/env bash
# Runs every matrix. Exit 0 only when all pass. PRQ_PLUGIN_DIR selects the
# plugin copy under test (tests/mutation.sh uses it); default: plugins/pr-quiz.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash --version | head -1
git --version
jq --version
rc=0
for t in gate quiz guard merge; do
  bash "${here}/${t}.sh" || rc=1
done
[ "$rc" = 0 ] && echo "ALL PASSED" || echo "SOME FAILED"
exit "$rc"
