#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT, RC and ERR are read by the lib.sh assertions
# Guard matrix: direct writes to quiz state or to the installed plugin, and CLI
# calls that disable it, are denied; plugin development and helper calls are not.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(mk_repo)"
edit_in() { jq -cn --arg t "$1" --arg p "$2" --arg d "$REPO" '{tool_name:$t,tool_input:{file_path:$p,content:"{}"},cwd:$d}'; }

hook state-guard.sh "$(edit_in Write "${REPO}/.git/pr-quiz/abc/pass.json")"; expect_deny "Write to the pass file" 'is quiz state'
hook state-guard.sh "$(edit_in Edit ".git/worktrees/wt/pr-quiz/abc/round.json")"; expect_deny "Edit of a worktree round file" 'is quiz state'
hook state-guard.sh "$(edit_in Write "${HOME}/.claude/plugins/cache/mennolaan/pr-quiz/0.1.0/hooks/pr-gate.sh")"; expect_deny "Write into the installed plugin" 'installed plugin'
for c in 'echo {} > .git/pr-quiz/abc/pass.json' 'cat "$(git rev-parse --git-dir)/pr-quiz/abc/key-1.json"' 'rm -rf .git/pr-quiz' \
         'ls "$(git rev-parse --absolute-git-dir)/pr-quiz"'; do
  hook state-guard.sh "$(bash_in "$c" "$REPO")"; expect_deny "Bash reaching the state: $c" 'quiz state directly'
done
hook state-guard.sh "$(bash_in 'sed -i "" s/deny/allow/ ~/.claude/plugins/cache/mennolaan/pr-quiz/0.1.0/hooks/pr-gate.sh' "$REPO")"; expect_deny "Bash editing the installed plugin" 'installed plugin'
hook state-guard.sh "$(bash_in 'claude plugin disable pr-quiz@mennolaan' "$REPO")"; expect_deny "claude plugin disable" 'may not disable'
hook state-guard.sh "$(bash_in 'claude plugin uninstall pr-quiz' "$REPO")"; expect_deny "claude plugin uninstall" 'may not disable'

for c in '"/x/plugins/pr-quiz/skills/quiz/scripts/pr-quiz" status' '/x/skills/quiz/scripts/pr-quiz key < /tmp/key.json' \
         'git add .gitignore plugins/pr-quiz/hooks/pr-gate.sh' 'bash tests/run.sh' 'ls -la' 'cat plugins/pr-quiz/README.md'; do
  hook state-guard.sh "$(bash_in "$c" "$REPO")"; expect_allow "allowed: $c"
done
hook state-guard.sh "$(edit_in Write "${REPO}/plugins/pr-quiz/README.md")"; expect_allow "Write to the plugin source is allowed"
hook state-guard.sh "$(edit_in Write "${REPO}/.gitignore")"; expect_allow "Write to .gitignore is allowed"

finish
