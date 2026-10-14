#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT, RC and ERR are read by the lib.sh assertions
# Gate matrix: every gated command form, every allowed neighbour, pass binding,
# pass validity after commits, rebases and amends, and the fail-closed cases.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPO="$(mk_repo)"
mkdir -p "${REPO}/sub"

# No pass: every creating form is denied.
for c in 'gh pr create --fill' 'gh pr new --fill' 'cd sub && gh pr create --fill' 'FOO=1 gh pr create --fill' \
         'command gh pr create --fill' '\gh pr create --fill' '/opt/homebrew/bin/gh pr create --fill' \
         'bash -c "gh pr create --fill"' 'git push -u origin feat && gh pr create --draft --title "a; b" --body "c && d"' \
         'gh pr ready' 'glab mr create --fill' 'az repos pr create --title x' 'hub pull-request -m x' 'tea pr create --title x'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "no pass denies: $c" 'mode full, 10 questions, base main'
done
for c in 'gh api -X POST repos/acme/demo/pulls -f title=x' 'gh api repos/acme/demo/pulls -f title=x' \
         'gh api --method=POST /repos/acme/demo/pulls --input body.json' 'gh api graphql -f query="mutation { createPullRequest(input: {}) { clientMutationId } }"' \
         'curl -X POST https://api.github.com/repos/acme/demo/pulls -d {}' 'glab api projects/1/merge_requests -X POST' 'hub api repos/acme/demo/pulls -F title=x'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "raw API denied: $c" 'raw API'
done
hook pr-gate.sh "$(tool_in mcp__github__create_pull_request '{"owner":"acme","repo":"demo","head":"feat","base":"main","title":"x"}' "$REPO")"
expect_deny "no pass denies MCP create_pull_request" 'mode full'

# Neighbours that create nothing are allowed.
for c in 'gh pr view 3' 'gh pr list' 'gh pr checkout 3' 'gh api repos/acme/demo/pulls' 'git push -u origin feat' \
         'echo "gh pr create"' 'git commit -m "docs: explain gh pr create"' 'curl https://api.github.com/repos/acme/demo/pulls' \
         'gh pr ready --undo' 'ls -la'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_allow "allowed: $c"
done

# gh aliases (needs gh).
if command -v gh >/dev/null 2>&1; then
  gh alias set prc 'pr create --draft' >/dev/null 2>&1
  gh alias set --shell shx 'gh pr create --fill' >/dev/null 2>&1
  gh alias set co2 'pr checkout' >/dev/null 2>&1
  hook pr-gate.sh "$(bash_in 'gh prc --fill' "$REPO")"; expect_deny "gh alias to pr create is resolved" 'mode full'
  hook pr-gate.sh "$(bash_in 'gh shx' "$REPO")"; expect_deny "gh shell alias to pr create is resolved" 'mode full'
  hook pr-gate.sh "$(bash_in 'gh co2 3' "$REPO")"; expect_allow "gh alias to pr checkout is allowed"
  hook pr-gate.sh "$(bash_in 'gh alias set mk "pr create --fill"' "$REPO")"; expect_deny "gh alias set with pr create is denied" 'alias'
  hook pr-gate.sh "$(bash_in 'gh alias import aliases.yml' "$REPO")"; expect_deny "gh alias import is denied" 'alias import'
  hook pr-gate.sh "$(bash_in 'gh alias set v "pr view"' "$REPO")"; expect_allow "gh alias set with pr view is allowed"
else
  bad "gh alias cases" "gh is not installed; these cases did not run"
fi

# A pass at HEAD opens the gate, bound to branch, base and repo.
pass_quiz
expect_true "full quiz writes a pass" has_pass
for c in 'gh pr create --fill' 'gh pr create --draft --base main --head feat' 'gh pr create --head acme:feat --fill' \
         'gh pr create -R Acme/Demo --fill' 'gh pr create --repo https://github.com/acme/demo.git --fill' 'GH_REPO=acme/demo gh pr create --fill' 'gh pr ready'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_allow "pass allows: $c"
done
hook pr-gate.sh "$(tool_in mcp__github__create_pull_request '{"owner":"Acme","repo":"Demo","head":"feat","base":"main"}' "$REPO")"
expect_allow "pass allows MCP create_pull_request for the same head and base"
(cd "$REPO" && git branch -q other main && git update-ref refs/remotes/origin/develop main)
hook pr-gate.sh "$(bash_in 'gh pr create --head other --fill' "$REPO")"; expect_deny "pass does not cover --head other" 'head is other'
hook pr-gate.sh "$(bash_in 'gh pr create -H acme:other --fill' "$REPO")"; expect_deny "pass does not cover -H owner:other" 'head is other'
hook pr-gate.sh "$(bash_in 'gh pr create --base develop --fill' "$REPO")"; expect_deny "pass does not cover --base develop" 'base main.*base develop'
hook pr-gate.sh "$(bash_in 'gh pr create -R evil/fork --fill' "$REPO")"; expect_deny "pass does not cover -R evil/fork" 'repo is evil/fork'
hook pr-gate.sh "$(bash_in 'GH_REPO=evil/fork gh pr create --fill' "$REPO")"; expect_deny "pass does not cover GH_REPO=evil/fork" 'repo is evil/fork'
hook pr-gate.sh "$(bash_in 'export GH_REPO=evil/fork; gh pr create --fill' "$REPO")"; expect_deny "pass does not cover export GH_REPO" 'repo is evil/fork'
hook pr-gate.sh "$(bash_in 'gh pr ready 123' "$REPO")"; expect_deny "pass does not cover gh pr ready <number>" 'cannot map'
hook pr-gate.sh "$(bash_in 'gh api -X POST repos/acme/demo/pulls -f head=feat' "$REPO")"; expect_deny "pass does not open the raw API" 'raw API'
hook pr-gate.sh "$(tool_in mcp__github__create_pull_request '{"owner":"acme","repo":"demo","head":"other","base":"main"}' "$REPO")"
expect_deny "pass does not cover MCP head other" 'head is other'
hook pr-gate.sh "$(tool_in mcp__github__create_pull_request '{"owner":"evil","repo":"fork","head":"feat","base":"main"}' "$REPO")"
expect_deny "pass does not cover MCP owner evil" 'repo is evil/fork'

# A rebase that keeps the content keeps the pass.
(cd "$REPO" && git checkout -q main && printf 'more\n' >> README.md && git commit -qam "main: docs" \
  && git update-ref refs/remotes/origin/main HEAD && git checkout -q feat && git rebase -q main)
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_allow "content-neutral rebase keeps the pass"

# A new commit needs a delta quiz.
commit_in "$REPO" '# new line'
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_deny "new commit needs a delta quiz" 'mode delta, 3 questions'

# Amending the new commit keeps the rebased pass copy as the delta start.
(cd "$REPO" && printf '# amended\n' >> app.py && git commit -q --amend -am "amended")
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_deny "amend of the new commit needs a delta quiz" 'rebased to.*mode delta'

# Rewriting the passed commit itself needs a full quiz.
(cd "$REPO" && git reset -q --hard HEAD~1 && printf '# rewritten\n' >> app.py && git commit -q --amend -am "rewritten")
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_deny "amend of the passed commit needs a full quiz" 'history changed.*mode full'

# A plain new commit after a pass needs a delta quiz of 3.
R5="$(mk_repo)"
REPO="$R5"; pass_quiz
commit_in "$R5" '# plain'
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$R5")"; expect_deny "plain new commit needs a delta quiz of 3" 'new changes since the quiz pass at [0-9a-f]{7}\. .*mode delta, 3 questions'

# Added lines that differ only in indentation (d() moved under the if) void the pass.
R2="$(mk_repo)"
(cd "$R2" && printf 'if x:\n    c()\nd()\n' >> app.py && git commit -q --amend -am "feat: return 2, add guard")
REPO="$R2"; pass_quiz
(cd "$R2" && sed -i.bak 's/^d()$/    d()/' app.py && rm -f app.py.bak && git commit -q --amend -am "feat: return 2, add guard")
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$R2")"; expect_deny "whitespace-only behavior change voids the pass" 'history changed.*mode full'

# Fail closed.
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$TMPROOT")"; expect_deny "outside a checkout is denied" 'outside a git checkout'
R3="$(mk_repo)"; (cd "$R3" && git checkout -q --detach)
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$R3")"; expect_deny "detached HEAD is denied" 'detached'
R4="$(mk_repo)"; (cd "$R4" && git remote remove origin && git symbolic-ref --delete refs/remotes/origin/HEAD 2>/dev/null; git update-ref -d refs/remotes/origin/main; git branch -q -m main trunk)
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$R4")"; expect_deny "no default branch is denied" 'default branch'

nojq="${TMPROOT}/nojq"; mkdir -p "$nojq"
for f in /usr/bin/* /bin/*; do b="${f##*/}"; [ "$b" = jq ] || [ -e "${nojq}/${b}" ] || ln -s "$f" "${nojq}/${b}"; done
gitbin="$(command -v git)"; [ -e "${nojq}/git" ] || ln -s "$gitbin" "${nojq}/git"
OUT="$(bash_in 'gh pr create --fill' "$REPO" | PATH="$nojq" CLAUDE_PLUGIN_ROOT="$PLUGIN" "${nojq}/bash" "${PLUGIN}/hooks/pr-gate.sh" 2>"${TMPROOT}/stderr")"; RC=$?; ERR="$(cat "${TMPROOT}/stderr")"
expect_deny "missing jq is denied (exit 2)" 'jq is not installed'

oldgit="${TMPROOT}/oldgit"; mkdir -p "$oldgit"
printf '#!/bin/sh\nif [ "$1" = patch-id ] && [ "$2" = --verbatim ]; then echo "error: unknown option" >&2; exit 129; fi\nexec %s "$@"\n' "$gitbin" > "${oldgit}/git"
chmod +x "${oldgit}/git"
OUT="$(bash_in 'gh pr create --fill' "$REPO" | PATH="${oldgit}:$PATH" CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "${PLUGIN}/hooks/pr-gate.sh" 2>"${TMPROOT}/stderr")"; RC=$?; ERR="$(cat "${TMPROOT}/stderr")"
expect_deny "git without patch-id --verbatim is denied" 'git 2.39'

finish
