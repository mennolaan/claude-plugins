#!/usr/bin/env bash
# shellcheck disable=SC2034  # OUT, RC and ERR are read by the lib.sh assertions
# Merge check matrix: the switch, the remote base check, GitHub and Azure DevOps
# posting through stub gh, curl and az, dedupe, the trigger hook, the helper,
# the Azure DevOps remote parser and the token handling.
set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STUB="${TMPROOT}/stub"; mkdir -p "$STUB"
LOG="${TMPROOT}/stub.log"; CFG="${TMPROOT}/stub.stdin"; RULES="${TMPROOT}/stub.rules"
export STUB_LOG="$LOG" STUB_STDIN="$CFG" STUB_CURL_RULES="$RULES"
unset AZURE_DEVOPS_EXT_PAT PR_QUIZ_MERGE_CHECK GH_TOKEN

cat > "${STUB}/gh" <<'EOF'
#!/usr/bin/env bash
printf 'gh' >> "$STUB_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$STUB_LOG"; done; printf '\n' >> "$STUB_LOG"
if [ -n "${STUB_GH_ERR:-}" ]; then printf '%s\n' "$STUB_GH_ERR" >&2; exit 1; fi
printf '{}\n'
EOF
cat > "${STUB}/az" <<'EOF'
#!/usr/bin/env bash
printf 'az' >> "$STUB_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$STUB_LOG"; done; printf '\n' >> "$STUB_LOG"
[ -z "${STUB_AZ_FAIL:-}" ] || exit 1
printf 'tok-from-az\n'
EOF
cat > "${STUB}/curl" <<'EOF'
#!/usr/bin/env bash
# Logs argv and stdin. Answers from $STUB_CURL_RULES: "METHOD URL-part CODE BODY-FILE" per line.
args=("$@"); out=""; method=GET; url=""; i=0
printf 'curl' >> "$STUB_LOG"; for a in "$@"; do printf ' %s' "$a" >> "$STUB_LOG"; done; printf '\n' >> "$STUB_LOG"
cat >> "$STUB_STDIN"
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -o) out="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    -X) method="${args[$((i + 1))]}"; i=$((i + 2)) ;;
    -K|-H|-w|--max-time|--data-binary) i=$((i + 2)) ;;
    -*) i=$((i + 1)) ;;
    *) url="${args[$i]}"; i=$((i + 1)) ;;
  esac
done
while read -r m part code body; do
  [ "$m" = "$method" ] || continue
  case "$url" in *"$part"*) cat "$body" > "$out"; printf '%s' "$code"; exit 0 ;; esac
done < "$STUB_CURL_RULES"
printf '{"message":"no stub rule"}' > "$out"; printf '599'
EOF
chmod +x "${STUB}/gh" "${STUB}/az" "${STUB}/curl"
PATH="${STUB}:${PATH}"; export PATH

reset_log() { : > "$LOG"; : > "$CFG"; }
calls() { grep -c "^$1" "$LOG" 2>/dev/null || true; }
head_of() { git -C "$REPO" rev-parse HEAD; }
switch_file() { mkdir -p "${REPO}/.claude"; printf '%s' "$1" > "${REPO}/.claude/pr-quiz.json"; }
mc_hook() { hook merge-check.sh "$(bash_in "${1:-git push -u origin feat}" "$REPO")"; }
forget() { rm -f "$(state_dir)/merge-check.json"; }

# mk_remote <origin url>: a bare remote for $REPO with main and feat, reached
# through url.insteadOf, so that git ls-remote works while the configured
# origin URL stays the GitHub or Azure DevOps form.
mk_remote() {
  local bare
  bare="$(mktemp -d "${TMPROOT}/bare.XXXXXX")"
  git init -q --bare "$bare"
  (cd "$REPO" && git remote set-url origin "$1" && git config "url.${bare}.insteadOf" "$1" \
    && git push -q origin main feat 2>/dev/null && git fetch -q origin) || { echo "FATAL: mk_remote" >&2; exit 1; }
  BARE="$bare"
}

# remote_commit: a new commit on the remote main that the checkout has not fetched.
remote_commit() {
  local c; c="$(mktemp -d "${TMPROOT}/clone.XXXXXX")"
  (git clone -q "$BARE" "$c/w" && cd "$c/w" && printf 'x\n' > other.txt && git add other.txt && git commit -qm other && git push -q origin main) \
    || { echo "FATAL: remote_commit" >&2; exit 1; }
}

# Azure DevOps remote parser ------------------------------------------------
parse() { (. "${PLUGIN}/hooks/_lib.sh"; prq_ado_parse "$1" && printf '%s|%s|%s|%s|%s' "$PRQ_ADO_BASE" "$PRQ_ADO_ORG" "$PRQ_ADO_PROJECT" "$PRQ_ADO_REPO" "$PRQ_ADO_REPO_ENC"); }
row() { local got; got="$(parse "$1")"; if [ "$got" = "$2" ]; then ok "parser: $1"; else bad "parser: $1" "want $2, got ${got:-<not Azure DevOps>}"; fi; }
row "https://acme@dev.azure.com/acme/My%20Project/_git/My%20Repo" "https://dev.azure.com/acme/My%20Project|acme|My Project|My Repo|My%20Repo"
row "https://dev.azure.com/qlaut/FamilieStamboom/_git/FamilieStamboom" "https://dev.azure.com/qlaut/FamilieStamboom|qlaut|FamilieStamboom|FamilieStamboom|FamilieStamboom"
row "https://acme.visualstudio.com/DefaultCollection/Proj/_git/Repo" "https://acme.visualstudio.com/DefaultCollection/Proj|acme|Proj|Repo|Repo"
row "git@ssh.dev.azure.com:v3/acme/My%20Proj/repo" "https://dev.azure.com/acme/My%20Proj|acme|My Proj|repo|repo"
row "acme@vs-ssh.visualstudio.com:v3/acme/Proj/repo" "https://dev.azure.com/acme/Proj|acme|Proj|repo|repo"
row "https://tfs.corp.example:8080/tfs/Coll/Proj/_git/Repo" "https://tfs.corp.example:8080/tfs/Coll/Proj|tfs.corp.example:8080/tfs/Coll|Proj|Repo|Repo"
row "https://github.com/Acme/Demo.git" ""
expect_true "an Azure DevOps Server ssh remote is an error, not GitHub" '(. "${PLUGIN}/hooks/_lib.sh"; ! prq_ado_parse "ssh://tfs.corp.example:22/tfs/Coll/Proj/_git/Repo" && [ -n "$PRQ_ADO_ERR" ])'

# GitHub: the switch --------------------------------------------------------
REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"
reset_log; pass_quiz
expect_true "switch off by default: a pass makes no call" '[ "$(calls gh)" = 0 ]'
switch_file '{"merge_check": true}'
reset_log; out="$(helper publish)"
expect_true "switch on: publish posts the commit status" "grep -q '^gh api --hostname github.com -X POST repos/acme/demo/statuses/$(head_of) -f state=success -f context=pr-quiz/merge-check -f description=Quiz passed at [0-9a-f]\{7\}: round 1 10/10\$' \"\$LOG\""
expect_true "publish reports the status" 'printf "%s" "$out" | grep -q "pr-quiz/merge-check is success on"'
reset_log; mc_hook
expect_true "the same HEAD is posted once" '[ "$(calls gh)" = 0 ] && [ -z "$OUT" ]'
forget; reset_log; out="$(PR_QUIZ_MERGE_CHECK=off helper publish)"
expect_true "env off beats the repo file" '[ "$(calls gh)" = 0 ]'
expect_true "env off against the repo file names the override" 'printf "%s" "$out" | grep -q "PR_QUIZ_MERGE_CHECK=off stops the merge check status for you"'
rm -f "${REPO}/.claude/pr-quiz.json"; reset_log; out="$(PR_QUIZ_MERGE_CHECK=on helper publish)"
expect_true "env on works without the repo file" '[ "$(calls gh)" = 1 ]'
forget; switch_file '{"merge_check": false}'; reset_log; out="$(PR_QUIZ_MERGE_CHECK=on helper publish)"
expect_true "env on beats a repo file that says false" '[ "$(calls gh)" = 1 ]'
forget; switch_file '{"merge_check": "yes"}'; reset_log; out="$(helper publish)"
expect_true "a non-boolean switch value is an error with no call" '[ "$(calls gh)" = 0 ] && printf "%s" "$out" | grep -q "merge_check must be true or false"'
switch_file '{"merge_check": tru'; reset_log; out="$(helper publish)"
expect_true "an invalid JSON switch file is an error with no call" '[ "$(calls gh)" = 0 ] && printf "%s" "$out" | grep -q "is not valid JSON"'
rm -f "${REPO}/.claude/pr-quiz.json"; reset_log; out="$(PR_QUIZ_MERGE_CHECK=yes helper publish)"
expect_true "a bad env value is an error with no call" '[ "$(calls gh)" = 0 ] && printf "%s" "$out" | grep -q "Use on or off"'

# GitHub: answers and triggers ----------------------------------------------
switch_file '{"merge_check": true}'; forget
reset_log; STUB_GH_ERR='gh: No commit found for SHA: abc (HTTP 422)' mc_hook
expect_ctx "an unpushed commit is not yet, for Claude" 'not posted yet: commit [0-9a-f]{7} is not on github.com yet'
expect_true "not yet shows the developer nothing" '[ -z "$(sysmsg)" ]'
reset_log; STUB_GH_ERR='gh: Bad credentials (HTTP 401)' mc_hook
expect_sysmsg "a refused post is an error the developer sees" 'gh could not post the status to github.com/acme/demo: gh: Bad credentials \(HTTP 401\)\. Fix: run gh auth login'
reset_log; mc_hook 'ls -la'
expect_true "an unrelated command makes no call" '[ "$(calls gh)" = 0 ] && [ -z "$OUT" ]'
reset_log; mc_hook 'git push -u origin feat'
expect_sysmsg "a push through Claude posts the status" 'pr-quiz merge check: pr-quiz/merge-check is success on'
forget; reset_log; hook merge-check.sh "$(tool_in mcp__github__create_pull_request '{"owner":"acme","repo":"demo","head":"feat","base":"main"}' "$REPO")"
expect_true "an MCP PR creation posts the status" '[ "$(calls gh)" = 1 ]'
reset_log; out="$(helper reset --all)"
expect_true "reset --all posts a pending status" 'grep -q "statuses/$(head_of) -f state=pending" "$LOG"'
expect_true "reset --all drops the pass" '! has_pass'

# GitHub: the pass itself posts, and the pass binds the origin ---------------
REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; switch_file '{"merge_check": true}'
reset_log; pass_quiz
expect_true "with the switch on, the pass posts the status" '[ "$(calls gh)" = 1 ]'
expect_sysmsg "the pass tells the developer about the status" 'PR quiz passed!.*Merge check: pr-quiz/merge-check is success on'
REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; switch_file '{"merge_check": true}'
reset_log; PR_QUIZ_MERGE_CHECK=off pass_quiz
expect_true "an env override at the pass posts nothing" '[ "$(calls gh)" = 0 ]'
expect_sysmsg "an env override at the pass names the override" 'PR_QUIZ_MERGE_CHECK=off stops the merge check status for you'
git clone -q --bare "$BARE" "${BARE}-other"
(cd "$REPO" && git remote set-url origin "https://github.com/Other/Repo.git" && git config "url.${BARE}-other.insteadOf" "https://github.com/Other/Repo.git")
reset_log; mc_hook
expect_true "a pass for another origin posts nothing" '[ "$(calls gh)" = 0 ]'

# GitHub: the pass must cover HEAD against the remote base ------------------
REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
commit_in "$REPO" '# after the pass'
reset_log; out="$(helper publish)"
expect_true "a new commit after the pass posts nothing" '[ "$(calls gh)" = 0 ]'
reset_log; mc_hook
expect_ctx "a new commit after the pass is not yet" 'does not cover'

REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
(cd "$REPO" && printf '# amended\n' >> app.py && git commit -q --amend -a --no-edit)
reset_log; mc_hook
expect_true "an amended passed commit with a real change posts nothing" '[ "$(calls gh)" = 0 ]'

REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; commit_in "$REPO" '# second commit'
(cd "$REPO" && git update-ref refs/remotes/origin/main HEAD^)
pass_quiz; switch_file '{"merge_check": true}'
reset_log; mc_hook
expect_true "a quiz scoped against a moved local origin/main posts nothing" '[ "$(calls gh)" = 0 ]'
expect_ctx "a moved local base is reported" 'does not cover [0-9a-f]{7} against origin main'

REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
remote_commit
reset_log; mc_hook
expect_ctx "a remote base commit that is not fetched asks for a fetch" 'origin main is at [0-9a-f]{7}, which this checkout does not have\. Run git fetch origin main'
(cd "$REPO" && git fetch -q origin && git rebase -q origin/main && git push -qf origin feat 2>/dev/null)
reset_log; mc_hook
expect_true "a rebase that keeps the content posts on the new HEAD" "grep -q 'statuses/$(head_of) -f state=success' \"\$LOG\""

REPO="$(mk_repo)"; mk_remote "https://ghe.corp.example/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
reset_log; mc_hook
expect_true "a GitHub Enterprise origin uses its host" 'grep -q "^gh api --hostname ghe.corp.example -X POST repos/acme/demo/statuses/" "$LOG"'

# Codex code review round 3 ------------------------------------------------
k="${TMPROOT}/k.json"
REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
P="$(head_of)"; commit_in "$REPO" '# not quizzed'
W="${TMPROOT}/upload-pack-reset"
printf '#!/bin/sh\ngit -C "%s" reset -q --hard %s\nexec git upload-pack "$@"\n' "$REPO" "$P" > "$W"; chmod +x "$W"
git -C "$REPO" config remote.origin.uploadpack "$W"
reset_log; mc_hook
expect_true "a HEAD that moves during ls-remote gets no status" '[ "$(calls gh)" = 0 ]'
expect_true "the probe really moved HEAD during ls-remote" '[ "$(head_of)" = "$P" ]'
git -C "$REPO" config --unset remote.origin.uploadpack

REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; commit_in "$REPO" '# second commit'
(cd "$REPO" && git update-ref refs/remotes/origin/main HEAD^)
switch_file '{"merge_check": true}'
helper start >/dev/null; make_key 10 > "$k"; helper key < "$k" >/dev/null
ask_and_answer "$k" 1 4 "$(correct_answers "$k" 1 4)"
ask_and_answer "$k" 5 8 "$(correct_answers "$k" 5 8)"
(cd "$REPO" && git fetch -q origin)
reset_log; ask_and_answer "$k" 9 10 "$(correct_answers "$k" 9 10)"
expect_ctx "the quiz passes after a fetch during the quiz" 'PASS'
expect_true "a fetch during the quiz cannot widen the pass" '[ "$(calls gh)" = 0 ]'

REPO="$(mk_repo)"; mk_remote "https://github.com/Acme/Demo.git"; pass_quiz; switch_file '{"merge_check": true}'
reset_log; hook merge-check.sh "$(bash_in "cd '${REPO}' && git push origin feat" "$TMPROOT")"
expect_true "a push after cd posts for that checkout" '[ "$(calls gh)" = 1 ]'
forget; reset_log; mc_hook 'gh pr --base main create --fill'
expect_true "a PR command with flags before the action posts" '[ "$(calls gh)" = 1 ]'
forget; reset_log; mc_hook 'git push origin feat && cd ..'
expect_true "a cd after the push keeps the push checkout" '[ "$(calls gh)" = 1 ]'
mv "$REPO" "${REPO} (work)"; REPO="${REPO} (work)"
forget; reset_log; hook merge-check.sh "$(bash_in "cd '${REPO}' && git push origin feat" "$TMPROOT")"
expect_true "a checkout path with ( and spaces is followed" '[ "$(calls gh)" = 1 ]'
git clone -q --bare "$BARE" "${BARE}-moved"
(cd "$REPO" && git remote set-url origin "https://github.com/Moved/Repo.git" && git config "url.${BARE}-moved.insteadOf" "https://github.com/Moved/Repo.git")
reset_log; pass_quiz
expect_true "a new origin at the same HEAD gets its own status" 'grep -q "^gh api --hostname github.com -X POST repos/moved/repo/statuses/" "$LOG"'

# Azure DevOps ----------------------------------------------------------------
REPO="$(mk_repo)"; mk_remote "https://acme@dev.azure.com/acme/My%20Project/_git/My%20Repo"; pass_quiz; switch_file '{"merge_check": true}'
H="$(head_of)"
printf '{"count":1,"value":[{"pullRequestId":7}]}' > "${TMPROOT}/prs.json"
printf '{"count":0,"value":[]}' > "${TMPROOT}/noprs.json"
jq -cn --arg h "$H" '{count:3, value:[{id:1, sourceRefCommit:{commitId:$h}}, {id:2, sourceRefCommit:{commitId:$h}}, {id:3, sourceRefCommit:{commitId:"0000000000000000000000000000000000000000"}}]}' > "${TMPROOT}/its.json"
printf '{"count":1,"value":[{"id":1,"sourceRefCommit":{"commitId":"1111111111111111111111111111111111111111"}}]}' > "${TMPROOT}/its-old.json"
printf '{"id":1}' > "${TMPROOT}/status.json"
printf '<html>sign in</html>' > "${TMPROOT}/signin.html"
rules() { printf '%s\n' "$@" > "$RULES"; }
ok_rules() {
  rules "GET /pullrequests?searchCriteria.sourceRefName=refs%2Fheads%2Ffeat&searchCriteria.targetRefName=refs%2Fheads%2Fmain 200 ${TMPROOT}/prs.json" \
        "GET /pullRequests/7/iterations 200 ${TMPROOT}/its.json" \
        "POST /pullRequests/7/statuses 200 ${TMPROOT}/status.json"
}
ok_rules; reset_log; out="$(AZURE_DEVOPS_EXT_PAT=pat-secret helper publish)"
expect_true "Azure DevOps: publish posts the PR status" 'grep -q "^curl .* -X POST .*https://dev.azure.com/acme/My%20Project/_apis/git/repositories/My%20Repo/pullRequests/7/statuses?api-version=7.0$" "$LOG"'
expect_true "Azure DevOps: the status goes on the newest iteration of HEAD, not the newest iteration" 'grep -q "\"iterationId\":2}" "$LOG"'
expect_true "Azure DevOps: the status is pr-quiz/merge-check, succeeded" 'grep -q "{\"state\":\"succeeded\",\"description\":\"Quiz passed at [0-9a-f]\{7\}: round 1 10/10\",\"context\":{\"genre\":\"pr-quiz\",\"name\":\"merge-check\"}" "$LOG"'
expect_true "Azure DevOps: only PRs to the pass base are listed" 'grep -q "searchCriteria.targetRefName=refs%2Fheads%2Fmain&searchCriteria.status=active" "$LOG"'
expect_true "Azure DevOps: publish reports the PR" 'printf "%s" "$out" | grep -q "succeeded on PR !7"'
expect_true "the PAT goes to curl on stdin" 'grep -q "^header = \"Authorization: Basic $(printf ":%s" pat-secret | base64 | tr -d "\n")\"" "$CFG"'
expect_true "the PAT never appears in argv" '! grep -q "pat-secret\|$(printf ":%s" pat-secret | base64 | tr -d "\n")" "$LOG"'
reset_log; out="$(AZURE_DEVOPS_EXT_PAT=pat-secret helper publish)"
expect_true "Azure DevOps: the same PR iteration is posted once" '[ "$(grep -c " -X POST " "$LOG")" = 0 ]'
forget; reset_log; out="$(helper publish)"
expect_true "without a PAT the token comes from az" 'grep -q "^az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv$" "$LOG" && grep -q "Authorization: Bearer tok-from-az" "$CFG"'
expect_true "the az token never appears in argv" '! grep -q "tok-from-az" "$LOG"'
forget; reset_log; out="$(STUB_AZ_FAIL=1 helper publish)"
expect_true "a failed az token is an error" 'printf "%s" "$out" | grep -q "az account get-access-token failed"'
forget; rules "GET /pullrequests? 200 ${TMPROOT}/noprs.json"; reset_log; mc_hook
expect_ctx "Azure DevOps: no PR yet is not yet" 'no active pull request from feat to main yet'
rules "GET /pullrequests? 200 ${TMPROOT}/prs.json" "GET /pullRequests/7/iterations 200 ${TMPROOT}/its-old.json"; reset_log; mc_hook
expect_ctx "Azure DevOps: a PR without a push of HEAD is not yet" 'PR !7 has no push of [0-9a-f]{7} yet'
rules "GET /pullrequests? 203 ${TMPROOT}/signin.html"; reset_log; mc_hook
expect_sysmsg "Azure DevOps: a sign-in page is an error" 'HTTP 203 without JSON'
rules "GET /pullrequests? 401 ${TMPROOT}/signin.html"; reset_log; mc_hook
expect_sysmsg "Azure DevOps: HTTP 401 is an error" 'refused the call \(HTTP 401\)'
ok_rules; reset_log; out="$(helper reset --all)"
expect_true "Azure DevOps: reset --all posts a pending status" 'grep -q "{\"state\":\"pending\"" "$LOG"'

# hooks.json wiring ---------------------------------------------------------
HJ="${PLUGIN}/hooks/hooks.json"
expect_true "hooks.json runs the merge check after Bash" 'jq -e ".hooks.PostToolUse[] | select(.matcher == \"Bash\") | .hooks[] | select(.command | test(\"merge-check.sh\"))" "$HJ" >/dev/null'
expect_true "hooks.json runs the merge check after the Azure DevOps MCP PR tool" 'jq -e "[.hooks.PostToolUse[] | select(.hooks[].command | test(\"merge-check.sh\")) | .matcher] | any(. as \$m | \"mcp__ado__repo_pull_request_write\" | test(\$m))" "$HJ" >/dev/null'
for t in mcp__ado__repo_pull_request_write mcp__github__create_pull_request mcp__gh__create_commit_status; do
  expect_true "hooks.json gates $t" 'jq -e --arg t "$t" "[.hooks.PreToolUse[] | select(.hooks[].command | test(\"pr-gate.sh\")) | .matcher] | any(. as \$m | \$t | test(\$m))" "$HJ" >/dev/null'
done

finish
