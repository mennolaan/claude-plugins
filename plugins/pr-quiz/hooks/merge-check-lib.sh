#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced library: the callers read these variables
# pr-quiz merge check: posts the status pr-quiz/merge-check after a quiz pass,
# so that a required check on the platform can block the merge of a PR that
# was opened outside Claude. GitHub: a commit status on HEAD. Azure DevOps: a
# pull request status on the iteration whose source commit is HEAD.
# Sourced after _lib.sh and prq_repo_ctx. Entry point: prq_mc_run.

PRQ_MC_CONTEXT="pr-quiz/merge-check"
PRQ_MC_GENRE="pr-quiz"
PRQ_MC_NAME="merge-check"
PRQ_ADO_RESOURCE="499b84ac-1321-427f-aa17-267ca6975798"
PRQ_ADO_API="7.0"

# prq_mc_switch: sets PRQ_MC (on | off | error), PRQ_MC_ERR and PRQ_MC_OVERRIDE
# (1 when the env says off and the repo file says on). The env beats the file.
prq_mc_switch() {
  local f="${PRQ_TOP}/.claude/pr-quiz.json" v="" file=""
  PRQ_MC=off; PRQ_MC_ERR=""; PRQ_MC_OVERRIDE=0
  if [ -f "$f" ]; then
    if ! jq -e . "$f" >/dev/null 2>&1; then
      PRQ_MC=error; PRQ_MC_ERR="${f} is not valid JSON. Write {\"merge_check\": true} or {\"merge_check\": false}."; return 0
    fi
    v="$(jq -r 'if type != "object" or (has("merge_check") | not) then "" elif (.merge_check | type) == "boolean" then (.merge_check | tostring) else "bad" end' "$f")"
    case "$v" in
      true|false) file="$v" ;;
      bad) PRQ_MC=error; PRQ_MC_ERR="${f}: merge_check must be true or false."; return 0 ;;
    esac
  fi
  case "${PR_QUIZ_MERGE_CHECK:-}" in
    on) PRQ_MC=on ;;
    off) PRQ_MC=off; [ "$file" = true ] && PRQ_MC_OVERRIDE=1 ;;
    "") [ "$file" = true ] && PRQ_MC=on ;;
    *) PRQ_MC=error; PRQ_MC_ERR="PR_QUIZ_MERGE_CHECK is \"${PR_QUIZ_MERGE_CHECK}\". Use on or off." ;;
  esac
  return 0
}

# prq_mc_override_msg: the message for a developer whose env stops the status.
prq_mc_override_msg() {
  printf 'pr-quiz: PR_QUIZ_MERGE_CHECK=off stops the merge check status for you. This repo turns the merge check on, so a required check can wait for it. Remove the override, then run /pr-quiz:quiz to post the status.'
}

# prq_mc_provider: sets PRQ_MC_PROVIDER (github | ado) and its target, from the
# configured origin URL (not insteadOf-rewritten). Returns 1 with PRQ_MC_ERR.
prq_mc_provider() {
  local url norm
  url="$(git config --get remote.origin.url 2>/dev/null)" || url=""
  [ -n "$url" ] || { PRQ_MC_ERR="the repo has no origin remote."; return 1; }
  if prq_ado_parse "$url"; then PRQ_MC_PROVIDER=ado; return 0; fi
  [ -z "$PRQ_ADO_ERR" ] || { PRQ_MC_ERR="$PRQ_ADO_ERR"; return 1; }
  norm="$(prq_norm_repo "$url")"
  PRQ_GH_HOST="${norm%%/*}"; PRQ_GH_REPO="${norm#*/}"
  case "$PRQ_GH_HOST" in *.*) ;; *) PRQ_MC_ERR="cannot read a host from origin ${url}."; return 1 ;; esac
  case "$PRQ_GH_REPO" in */*/*|*/|/*|"") PRQ_MC_ERR="cannot read OWNER/REPO from origin ${url}."; return 1 ;; esac
  PRQ_MC_PROVIDER=github
}

prq_mc_set() { PRQ_MC_RESULT="$1"; PRQ_MC_MSG="$2"; }

# prq_mc_seen <key>: true when merge-check.json records <key> for HEAD.
prq_mc_seen() {
  local f="${PRQ_STATE}/merge-check.json"
  [ -f "$f" ] && jq -e --arg h "$PRQ_HEAD" --arg k "$1" '.head == $h and ((.posted // []) | index($k)) != null' "$f" >/dev/null 2>&1
}

# prq_mc_record <key>: adds <key> for HEAD to merge-check.json.
prq_mc_record() {
  local f="${PRQ_STATE}/merge-check.json" cur='{}'
  [ -f "$f" ] && cur="$(cat "$f")"
  printf '%s' "$cur" | jq --arg h "$PRQ_HEAD" --arg k "$1" --arg p "$PRQ_MC_PROVIDER" \
    'if .head == $h then .posted = ((.posted // []) + [$k] | unique) else {head:$h, provider:$p, posted:[$k]} end' \
    | prq_write_json "$f"
}

# prq_mc_github <state> <description>: posts the commit status on HEAD.
prq_mc_github() {
  local out
  if out="$(gh api --hostname "$PRQ_GH_HOST" -X POST "repos/${PRQ_GH_REPO}/statuses/${PRQ_HEAD}" \
      -f "state=$1" -f "context=${PRQ_MC_CONTEXT}" -f "description=$2" 2>&1 >/dev/null)"; then
    return 0
  fi
  case "$out" in
    *"HTTP 422"*) prq_mc_set notyet "commit ${PRQ_HEAD:0:7} is not on ${PRQ_GH_HOST} yet. The status follows after the next push through Claude, or run /pr-quiz:quiz." ;;
    *) prq_mc_set error "gh could not post the status to ${PRQ_GH_HOST}/${PRQ_GH_REPO}: ${out%%$'\n'*}. Fix: run gh auth login -h ${PRQ_GH_HOST} with an account that has push access, or set GH_TOKEN." ;;
  esac
  return 1
}

# prq_ado_auth: sets PRQ_ADO_AUTH (an Authorization header value). The token
# never goes into argv: curl reads the header from stdin (prq_ado_call).
prq_ado_auth() {
  local tok
  if [ -n "${AZURE_DEVOPS_EXT_PAT:-}" ]; then
    PRQ_ADO_AUTH="Basic $(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 | tr -d '\n')"
    return 0
  fi
  if ! command -v az >/dev/null 2>&1; then
    prq_mc_set error "no Azure DevOps credentials. Run az login (Azure CLI), or set AZURE_DEVOPS_EXT_PAT to a PAT with the Code (status) scope."
    return 1
  fi
  tok="$(az account get-access-token --resource "$PRQ_ADO_RESOURCE" --query accessToken -o tsv 2>/dev/null)" || tok=""
  if [ -z "$tok" ]; then
    prq_mc_set error "az account get-access-token failed. Run az login with an account that has access to ${PRQ_ADO_ORG}, or set AZURE_DEVOPS_EXT_PAT."
    return 1
  fi
  PRQ_ADO_AUTH="Bearer ${tok}"
}

# prq_ado_call <method> <url> [json body]: sets PRQ_ADO_CODE and PRQ_ADO_BODY.
# Returns 1 with an error result unless the answer is a 2xx JSON document.
prq_ado_call() {
  local tmp code
  local -a data=()
  [ -n "${3:-}" ] && data=(--data-binary "$3")
  tmp="$(mktemp "${TMPDIR:-/tmp}/prq-ado.XXXXXX")" || { prq_mc_set error "mktemp failed."; return 1; }
  code="$(printf 'header = "Authorization: %s"\n' "$PRQ_ADO_AUTH" \
    | curl -sS --max-time 15 -K - -X "$1" -H 'Accept: application/json' -H 'Content-Type: application/json' \
        ${data[@]+"${data[@]}"} -o "$tmp" -w '%{http_code}' "$2" 2>"${tmp}.err")" || code="000"
  PRQ_ADO_CODE="$code"
  PRQ_ADO_BODY="$(cat "$tmp" 2>/dev/null)"
  local err; err="$(head -1 "${tmp}.err" 2>/dev/null)"
  rm -f "$tmp" "${tmp}.err"
  case "$code" in
    2??) if [ "$code" != 203 ] && printf '%s' "$PRQ_ADO_BODY" | jq -e . >/dev/null 2>&1; then return 0; fi
         prq_mc_set error "Azure DevOps answered HTTP ${code} without JSON (a sign-in page): the credentials are not valid for ${PRQ_ADO_ORG}. Run az login, or renew AZURE_DEVOPS_EXT_PAT." ;;
    401|403) prq_mc_set error "Azure DevOps refused the call (HTTP ${code}). The account needs Contribute access to ${PRQ_ADO_PROJECT}, or a PAT with the Code (status) scope." ;;
    404) prq_mc_set error "Azure DevOps answered HTTP 404 for ${PRQ_ADO_BASE} repo ${PRQ_ADO_REPO}. Check the origin URL and your access." ;;
    000) prq_mc_set error "the call to ${PRQ_ADO_BASE} failed: ${err:-no answer}." ;;
    *) prq_mc_set error "Azure DevOps answered HTTP ${code}: $(printf '%s' "$PRQ_ADO_BODY" | jq -r '.message // empty' 2>/dev/null | head -c 200)" ;;
  esac
  return 1
}

# prq_mc_ado <state> <description> <base>: posts the PR status on every active PR
# from the branch to <base>, on the iteration whose source commit is HEAD.
prq_mc_ado() {
  local state="$1" desc="$2" base="$3" api src tgt ids id it body posted="" missing="" seen=0
  prq_ado_auth || return 1
  api="${PRQ_ADO_BASE}/_apis/git/repositories/${PRQ_ADO_REPO_ENC}"
  src="$(jq -rn --arg v "refs/heads/${PRQ_BRANCH}" '$v | @uri')"
  tgt="$(jq -rn --arg v "refs/heads/${base}" '$v | @uri')"
  prq_ado_call GET "${api}/pullrequests?searchCriteria.sourceRefName=${src}&searchCriteria.targetRefName=${tgt}&searchCriteria.status=active&api-version=${PRQ_ADO_API}" || return 1
  ids="$(printf '%s' "$PRQ_ADO_BODY" | jq -r '.value[]?.pullRequestId')"
  if [ -z "$ids" ]; then
    prq_mc_set notyet "no active pull request from ${PRQ_BRANCH} to ${base} yet. The status follows when the PR exists (create it through Claude, or run /pr-quiz:quiz after you create it)."
    return 1
  fi
  for id in $ids; do
    prq_ado_call GET "${api}/pullRequests/${id}/iterations?api-version=${PRQ_ADO_API}" || return 1
    it="$(printf '%s' "$PRQ_ADO_BODY" | jq -r --arg h "$PRQ_HEAD" '[.value[]? | select(.sourceRefCommit.commitId == $h) | .id] | max // empty')"
    if [ -z "$it" ]; then missing="${missing} !${id}"; continue; fi
    if [ "$state" = succeeded ] && prq_mc_seen "ado:${api}:${id}:${it}"; then seen=$((seen + 1)); continue; fi
    body="$(jq -cn --arg s "$state" --arg d "$desc" --arg g "$PRQ_MC_GENRE" --arg n "$PRQ_MC_NAME" --argjson it "$it" \
      '{state:$s, description:$d, context:{genre:$g, name:$n}, iterationId:$it}')"
    prq_ado_call POST "${api}/pullRequests/${id}/statuses?api-version=${PRQ_ADO_API}" "$body" || return 1
    [ "$state" = succeeded ] && prq_mc_record "ado:${api}:${id}:${it}"
    posted="${posted} !${id}"
  done
  if [ -n "$posted" ]; then
    prq_mc_set posted "${PRQ_MC_CONTEXT} is ${state} on PR${posted} for ${PRQ_HEAD:0:7} (Azure DevOps)."
    return 0
  fi
  if [ -n "$missing" ]; then
    prq_mc_set notyet "PR${missing} has no push of ${PRQ_HEAD:0:7} yet. The status follows after the push."
    return 1
  fi
  [ "$seen" -gt 0 ] && prq_mc_set skip ""
  return 0
}

# prq_mc_run [success | pending]: posts the status when the switch is on. For
# success, the pass must cover HEAD against the remote base. Sets PRQ_MC_RESULT
# (off | skip | posted | notyet | error) and PRQ_MC_MSG. Never exits.
prq_mc_run() {
  local want="${1:-success}" pass="${PRQ_STATE}/pass.json" base="" pid r R cur desc ghkey
  prq_mc_set off ""
  prq_mc_switch
  [ "$PRQ_MC" = error ] && { prq_mc_set error "$PRQ_MC_ERR"; return 0; }
  [ "$PRQ_MC" = on ] || return 0
  if [ -z "$PRQ_BRANCH" ] || [ -z "$PRQ_HEAD" ]; then prq_mc_set skip ""; return 0; fi
  prq_mc_provider || { prq_mc_set error "$PRQ_MC_ERR"; return 0; }
  ghkey="github:${PRQ_GH_HOST:-}/${PRQ_GH_REPO:-}:${PRQ_HEAD}"
  if [ "$want" = success ]; then
    [ -f "$pass" ] || { prq_mc_set skip ""; return 0; }
    if [ "$(jq -r '.branch // ""' "$pass")" != "$PRQ_BRANCH" ] || [ "$(jq -r '.repo // ""' "$pass")" != "$PRQ_ORIGIN" ]; then
      prq_mc_set skip ""; return 0
    fi
    base="$(jq -r '.base // ""' "$pass")"; pid="$(jq -r '.patch_id // ""' "$pass")"
    [ "$PRQ_MC_PROVIDER" = github ] && prq_mc_seen "$ghkey" && { prq_mc_set skip ""; return 0; }
    if ! r="$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never git ls-remote origin "refs/heads/${base}" 2>&1)"; then
      prq_mc_set error "git ls-remote origin failed, so pr-quiz cannot check the remote base: ${r%%$'\n'*}"; return 0
    fi
    R="${r%%[[:space:]]*}"
    [ -n "$R" ] || { prq_mc_set error "origin has no branch ${base}, so pr-quiz cannot check the quiz scope."; return 0; }
    if ! git cat-file -e "${R}^{commit}" 2>/dev/null; then
      prq_mc_set notyet "origin ${base} is at ${R:0:7}, which this checkout does not have. Run git fetch origin ${base}, then /pr-quiz:quiz."; return 0
    fi
    cur="$(prq_patch_id "$R" "$PRQ_HEAD")" || cur=""
    if [ -z "$cur" ] || [ "$cur" != "$pid" ]; then
      prq_mc_set notyet "the quiz pass does not cover ${PRQ_HEAD:0:7} against origin ${base} at ${R:0:7}. Run git fetch origin ${base}, then /pr-quiz:quiz for the changes."; return 0
    fi
    desc="$(jq -r '"Quiz passed at \(.head[0:7]): " + ([.history[] | "round \(.round) \(.correct)/\(.total)"] | join(", "))' "$pass" | cut -c1-140)"
  else
    [ -f "$pass" ] && base="$(jq -r '.base // ""' "$pass")"
    desc="Quiz restarted. Run /pr-quiz:quiz in Claude Code."
  fi
  case "$PRQ_MC_PROVIDER" in
    github)
      prq_mc_github "$want" "$desc" || return 0
      [ "$want" = success ] && prq_mc_record "$ghkey"
      prq_mc_set posted "${PRQ_MC_CONTEXT} is ${want} on ${PRQ_HEAD:0:7} (${PRQ_GH_HOST}/${PRQ_GH_REPO})."
      ;;
    ado)
      [ -n "$base" ] || base="$(prq_pr_base)"
      if [ "$want" = success ]; then prq_mc_ado succeeded "$desc" "$base"; else prq_mc_ado pending "$desc" "$base"; fi
      ;;
  esac
  return 0
}
