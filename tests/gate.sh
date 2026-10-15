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

# Parser forms found in review: continuations, gh flags before the action,
# dynamic program names, and directory changes the gate cannot resolve.
hook pr-gate.sh "$(bash_in "$(printf 'gh \\\npr create --fill')" "$REPO")"; expect_deny "line continuation inside the command" 'mode full'
for c in 'gh --repo acme/demo pr create --fill' 'gh -R acme/demo pr create --fill' 'gh pr -R acme/demo create --fill' 'gh pr --repo=acme/demo new --fill'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "gh flag before the subcommand or action: $c" 'mode full'
done
hook pr-gate.sh "$(bash_in 'gh -R acme/demo pr list' "$REPO")"; expect_allow "gh flag before a read-only action is allowed"
for c in 'G=gh; $G pr create --fill' '"$GH" pr create --fill' '${HUB:-hub} pull-request -m x' '$(echo gh) pr create --fill' '`echo gh` pr new --fill'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "dynamic program name: $c" 'cannot resolve the program name'
done
hook pr-gate.sh "$(bash_in 'X=ls; $X -la' "$REPO")"; expect_allow "dynamic program name without a PR action is allowed"
for c in 'cd "$OTHER" && gh pr create --fill' 'cd - && gh pr create --fill' 'popd; gh pr create --fill' 'pushd -n x && gh pr create --fill'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "unresolvable directory: $c" 'cannot tell which checkout'
done
hook pr-gate.sh "$(bash_in 'pushd sub && gh pr create --fill' "$REPO")"; expect_deny "pushd is tracked like cd" 'mode full'

# Second review round: redirections, gh flag values before the action, combined
# curl flags, and a harness self-test.
for c in 'gh pr create>pr-url.txt --fill' '>pr-url.txt gh pr create --fill' 'gh pr create --fill 2>&1 | tee log' \
         'gh pr --base main create --fill' 'gh pr --title x create' 'gh --repo acme/demo pr --base main create'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "redirect or flag value form: $c" 'mode full'
done
for c in 'curl -sX POST https://api.github.com/repos/acme/demo/pulls' 'curl -sd {} https://api.github.com/repos/acme/demo/pulls' \
         'curl -s -d '"'"'{"title":"x","head":"feat"}'"'"' https://api.github.com/repos/acme/demo/pulls' 'gh api -iX POST repos/acme/demo/pulls'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "combined short flags: $c" 'raw API'
done
hook pr-gate.sh "$(bash_in 'curl -fsSL https://api.github.com/repos/acme/demo/pulls' "$REPO")"; expect_allow "curl GET with combined flags is allowed"
hook pr-gate.sh "$(bash_in '{ git status; gh pr create --fill; }' "$REPO")"; expect_deny "a command group is still parsed" 'mode full'
hook pr-gate.sh "$(bash_in "wget -qO- --post-data='{\"query\":\"mutation { createPullRequest(input: {}) { clientMutationId } }\"}' https://api.github.com/graphql" "$REPO")"
expect_deny "a GraphQL createPullRequest through any program is denied" 'GraphQL mutation'
selftest="$(OUT='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"mode full"}}'; RC=0; ERR=""; PASSED=0; FAILED=0; expect_deny probe 'mode full' >/dev/null; echo "$FAILED")"
expect_true "expect_deny rejects an explicit allow decision" '[ "$selftest" = 1 ]'

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
hook pr-gate.sh "$(bash_in 'gh --repo evil/fork pr create --fill' "$REPO")"; expect_deny "pass does not cover a leading --repo evil/fork" 'repo is evil/fork'
hook pr-gate.sh "$(bash_in 'cd /tmp && cd - && gh pr create --fill' "$REPO")"; expect_deny "pass does not cover an unresolvable directory" 'cannot tell which checkout'
OTHER="$(mk_repo)"
hook pr-gate.sh "$(bash_in "cd ${OTHER} && gh pr create --fill" "$REPO")"; expect_deny "a pass in one repo does not cover cd into another" 'No quiz pass exists'
hook pr-gate.sh "$(bash_in "pushd ${OTHER} && gh pr create --fill" "$REPO")"; expect_deny "a pass in one repo does not cover pushd into another" 'No quiz pass exists'
hook pr-gate.sh "$(bash_in 'env GH_REPO=evil/fork gh pr create --fill' "$REPO")"; expect_deny "pass does not cover env GH_REPO=evil/fork" 'repo is evil/fork'
hook pr-gate.sh "$(bash_in '(cd /tmp && ls); gh pr create --fill' "$REPO")"; expect_allow "a cd inside a subshell does not leak out (pass repo)"
hook pr-gate.sh "$(bash_in "(cd ${REPO} && git status --short); gh pr create --fill" "$OTHER")"; expect_deny "a subshell cd into the pass repo does not lend its pass" 'No quiz pass exists'
hook pr-gate.sh "$(bash_in 'gh pr create -R github.com/acme/demo --fill' "$REPO")"; expect_allow "pass allows -R HOST/OWNER/REPO with the origin host"
hook pr-gate.sh "$(bash_in 'gh pr create -R gitlab.com/acme/demo --fill' "$REPO")"; expect_deny "pass does not cover another host" 'repo is gitlab.com/acme/demo'
(cd "$REPO" && git config branch.feat.gh-merge-base develop)
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$REPO")"; expect_deny "gh-merge-base config sets the base" 'base main.*base develop'
(cd "$REPO" && git config --unset branch.feat.gh-merge-base)
R6="$(mk_repo)"; REPO_SAVE="$REPO"; REPO="$R6"; pass_quiz; REPO="$REPO_SAVE"
(cd "$R6" && git remote set-url origin https://other.example/acme/demo.git)
hook pr-gate.sh "$(bash_in 'gh pr create --fill' "$R6")"; expect_deny "a new origin host voids the pass" 'quiz pass is for github.com/acme/demo'
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

# 0.3.0: quoted words, raw API paths, status writes, policy skips and Azure DevOps targets.
REPO_MAIN="$REPO"; REPO="$(mk_repo)"; mkdir -p "${REPO}/dir with space"
hook pr-gate.sh "$(bash_in 'cd "dir with space" && gh pr create --fill' "$REPO")"; expect_deny "a quoted cd path with spaces resolves" 'mode full'
hook pr-gate.sh "$(bash_in "cd '${REPO}/dir with space' && gh pr create --fill" "$REPO")"; expect_deny "a single-quoted absolute path with spaces resolves" 'mode full'
for c in 'sh -c "cd /tmp && gh pr create --fill"' 'eval "gh pr create --fill"' 'nohup bash -c "gh pr new"'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "a quoted command string is parsed: $c" 'mode full|cannot tell which checkout|outside a git checkout'
done
hook pr-gate.sh "$(bash_in 'git commit -m "gh pr create later"' "$REPO")"; expect_allow "a quoted message that names a PR command is allowed"
for c in 'curl -X POST api.github.com/repos/acme/demo/pulls -d {}' 'curl -X POST https://api.github.com/ --request-target /repos/acme/demo/pulls -d {}' \
         'wget --post-data={} https://api.github.com/repos/acme/demo/pulls' 'az devops invoke --area git --resource pullRequests --http-method POST --in-file pr.json' \
         'az rest --method post --uri https://dev.azure.com/acme/p/_apis/git/repositories/r/pullrequests?api-version=7.1 --body {}'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "raw API denied: $c" 'raw API'
done
for c in 'gh api repos/acme/demo/statuses/abc -f state=success -f context=pr-quiz/merge-check' 'gh api -X POST repos/acme/demo/statuses/abc --input s.json' \
         'hub api repos/acme/demo/statuses/abc -f state=success' 'curl -X POST https://api.github.com/repos/acme/demo/statuses/abc -d {}' \
         'curl -sX POST api.github.com/repos/acme/demo/statuses/abc' \
         'curl -X POST https://dev.azure.com/ --request-target /acme/p/_apis/git/repositories/r/pullRequests/1/statuses?api-version=7.1 -d {}' \
         'curl -X PATCH https://dev.azure.com/acme/p/_apis/git/repositories/r/pullRequests/1/statuses?api-version=7.1 -d []' \
         'wget --post-data={} https://dev.azure.com/acme/p/_apis/git/repositories/r/pullRequests/1/statuses' \
         'az devops invoke --area git --resource pullRequestStatuses --route-parameters project=p --http-method POST --in-file s.json' \
         'az rest --method post --uri https://dev.azure.com/acme/p/_apis/git/repositories/r/pullRequests/1/statuses?api-version=7.1 --body {}'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "status write denied: $c" 'writes a commit or pull request status'
done
hook pr-gate.sh "$(tool_in mcp__gh__create_commit_status '{"owner":"acme","repo":"demo","sha":"abc","state":"success"}' "$REPO")"; expect_deny "MCP status tool denied" 'writes a commit or pull request status'
for c in 'gh api repos/acme/demo/statuses/abc' 'gh api repos/acme/demo/commits/abc/statuses' 'curl https://api.github.com/repos/acme/demo/statuses/abc' \
         'az rest --method get --uri https://dev.azure.com/acme/p/_apis/git/repositories/r/pullRequests/1/statuses'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_allow "status read allowed: $c"
done
for c in 'gh pr merge 5 --admin' 'gh pr merge --admin --squash' 'az repos pr update --id 5 --bypass-policy true --bypass-policy-reason x' \
         'az repos pr update --id 5 --bypass-policy=true' 'az repos pr create --bypass-policy true --title x'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_deny "policy skip denied: $c" 'skips the branch rules or policies'
done
for c in 'gh pr merge 5 --squash' 'az repos pr update --id 5 --bypass-policy false' 'az repos pr update --id 5 --status completed'; do
  hook pr-gate.sh "$(bash_in "$c" "$REPO")"; expect_allow "merge without a policy skip allowed: $c"
done
hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write '{"action":"update","pullRequestId":5,"bypassPolicy":true,"bypassReason":"x"}' "$REPO")"; expect_deny "MCP update with bypassPolicy denied" 'skips the branch rules or policies'
hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write '{"action":"update","pullRequestId":5,"autoComplete":true}' "$REPO")"; expect_allow "MCP update without bypassPolicy allowed"
hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write '{"action":"vote","pullRequestId":5,"vote":"Approved"}' "$REPO")"; expect_allow "MCP vote allowed"
hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write '{"action":"create","repositoryId":"demo","sourceRefName":"refs/heads/feat","targetRefName":"refs/heads/main","title":"x"}' "$REPO")"
expect_deny "Azure DevOps MCP create against a GitHub origin" 'not an Azure DevOps https remote'
hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write '{"action":"create","sourceRefName":"refs/heads/feat","targetRefName":"refs/heads/main","title":"x"}' "$REPO")"
expect_deny "Azure DevOps MCP create without a pass" 'mode full'

REPO="$(mk_repo)"; (cd "$REPO" && git remote set-url origin "https://acme@dev.azure.com/acme/My%20Project/_git/My%20Repo"); pass_quiz
mcp_ado() { hook pr-gate.sh "$(tool_in mcp__ado__repo_pull_request_write "$(jq -cn --arg r "$1" --arg p "$2" '{action:"create",repositoryId:$r,project:$p,sourceRefName:"refs/heads/feat",targetRefName:"refs/heads/main",title:"x"}')" "$REPO")"; }
mcp_ado "My Repo" "my project"; expect_allow "Azure DevOps MCP create by repo name with a pass"
mcp_ado "Other Repo" "My Project"; expect_deny "Azure DevOps MCP create to another repo" 'targets repository Other Repo, but origin is My Repo'
mcp_ado "11111111-2222-3333-4444-555555555555" "My Project"; expect_deny "Azure DevOps MCP create by GUID" 'by GUID'
mcp_ado "My Repo" "Else"; expect_deny "Azure DevOps MCP create to another project" 'targets project Else'
hook pr-gate.sh "$(bash_in 'az repos pr create --repository "My Repo" --project "My Project" --org https://dev.azure.com/acme/ --source-branch feat --target-branch main --title "a b"' "$REPO")"
expect_allow "az repos pr create with quoted names and a pass"
hook pr-gate.sh "$(bash_in 'az repos pr create --repository Other --title x' "$REPO")"; expect_deny "az repos pr create to another repo" 'targets repository Other'
hook pr-gate.sh "$(bash_in 'az repos pr create --org https://dev.azure.com/evil --title x' "$REPO")"; expect_deny "az repos pr create to another organization" 'targets organization'
hook pr-gate.sh "$(bash_in 'az repos pr create --org https://acme.visualstudio.com --title x' "$REPO")"; expect_allow "az repos pr create with the visualstudio.com form of the origin organization"
hook pr-gate.sh "$(bash_in 'az repos pr create --title "fix (edge case)" --bypass-policy true' "$REPO")"; expect_deny "a quoted ( cannot hide --bypass-policy" 'skips the branch rules or policies'
hook pr-gate.sh "$(bash_in 'az repos pr create --title "a; b" --repository Other' "$REPO")"; expect_deny "a quoted ; cannot hide --repository" 'targets repository Other'

# Codex code review round 3: quoted separators, eval, shell -c, wrapped text, GET.
REPO="$(mk_repo)"; pass_quiz; OTHER="$(mk_repo)"
hook pr-gate.sh "$(bash_in 'gh pr create --title "a; b" --base other' "$REPO")"; expect_deny "a quoted ; cannot hide --base" 'other'
hook pr-gate.sh "$(bash_in 'gh pr create --title "fix (edge case)" --repo evil/fork' "$REPO")"; expect_deny "a quoted ( cannot hide --repo" 'the PR repo is evil/fork'
hook pr-gate.sh "$(bash_in 'gh pr create --title "a (b); c" --fill' "$REPO")"; expect_allow "a quoted title with ; and ( is allowed with a pass"
hook pr-gate.sh "$(bash_in 'gh pr create --title "x > y" --base other' "$REPO")"; expect_deny "a quoted > cannot hide --base" 'other'
hook pr-gate.sh "$(bash_in 'az repos pr update --id 1 --title "x > y" --bypass-policy true' "$REPO")"; expect_deny "a quoted > cannot hide --bypass-policy" 'skips the branch rules or policies'
hook pr-gate.sh "$(bash_in 'gh pr create --title "t" --fill 2>/dev/null && gh pr ready 2>&1 >/dev/null' "$REPO")"; expect_allow "unquoted redirections are dropped in both passes"
hook pr-gate.sh "$(bash_in "export GH_REPO=evil/fork; bash -c 'export GH_REPO=acme/demo'; gh pr create --fill" "$REPO")"; expect_deny "a child shell cannot reset GH_REPO for its parent" 'the PR repo is evil/fork'
hook pr-gate.sh "$(bash_in 'eval -- gh pr create --fill' "$OTHER")"; expect_deny "eval -- runs its words" 'mode full'
hook pr-gate.sh "$(bash_in "eval 'cd ${OTHER}' && gh pr create --fill" "$REPO")"; expect_deny "a cd inside eval persists" 'mode full'
hook pr-gate.sh "$(bash_in 'eval gh "pr create --fill"' "$OTHER")"; expect_deny "eval joins its words" 'mode full'
hook pr-gate.sh "$(bash_in "bash -c 'cd ${OTHER} && gh pr create --fill'" "$REPO")"; expect_deny "a cd inside bash -c applies to its PR command" 'mode full'
hook pr-gate.sh "$(bash_in "$(printf "cat > notes.md <<'EOF'\nit's here\nEOF\ngh pr create --fill")" "$OTHER")"; expect_deny "a PR command after an apostrophe in a heredoc" 'mode full'
for c in 'bash -lc "gh pr create --fill"' 'bash -o pipefail -c "gh pr create --fill"' 'xargs -I{} sh -c "gh pr create --fill"' 'watch -n 5 "gh pr create --fill"' 'nohup sh -c "gh pr new"'; do
  hook pr-gate.sh "$(bash_in "$c" "$OTHER")"; expect_deny "a shell command string is parsed: $c" 'mode full'
done
for c in 'env LC_ALL=C printf "%s\n" "gh pr create --fill"' 'bash script.sh' 'nohup printf "%s" "gh pr new"'; do
  hook pr-gate.sh "$(bash_in "$c" "$OTHER")"; expect_allow "text that is not run as a command is allowed: $c"
done
for c in 'curl -X GET https://api.github.com/repos/acme/demo/commits/abc/statuses' 'curl -sX GET https://api.github.com/repos/acme/demo/statuses/abc' \
         'curl --request=GET https://api.github.com/repos/acme/demo/statuses/abc' 'wget --method=GET https://api.github.com/repos/acme/demo/statuses/abc' \
         'curl -I https://api.github.com/repos/acme/demo/statuses/abc'; do
  hook pr-gate.sh "$(bash_in "$c" "$OTHER")"; expect_allow "an explicit GET of statuses is allowed: $c"
done
for c in 'curl -sXPOST https://api.github.com/repos/acme/demo/statuses/abc' 'curl -X GET -d {} https://api.github.com/repos/acme/demo/statuses/abc' 'curl --request PATCH https://dev.azure.com/acme/p/_apis/git/repositories/r/pullRequests/1/statuses'; do
  hook pr-gate.sh "$(bash_in "$c" "$OTHER")"; expect_deny "a status write is denied: $c" 'writes a commit or pull request status'
done
REPO="$REPO_MAIN"

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
