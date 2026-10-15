#!/usr/bin/env bash
# Positive control for the matrices. Each mutant disables one rule in a copy of
# the plugin; the matrix that covers the rule must then fail. A mutant whose
# anchor text is missing fails loud: it would prove nothing.
# Usage: tests/mutation.sh [mutant-name ...]   (default: all)
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(cd "${here}/../plugins/pr-quiz" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/prq-mut.XXXXXX")"
trap 'rm -rf "$work"' EXIT
shopt -u patsub_replacement 2>/dev/null || true

want=" $* "
fails=0; ran=0; pids=""; names=""
run_one() { # name file suite anchor replacement
  local dir="${work}/$1" f content
  cp -R "$src" "$dir"
  f="${dir}/$2"
  content="$(cat "$f"; printf x)"; content="${content%x}"
  case "$content" in
    *"$4"*) ;;
    *) echo "VOID $1: anchor not found in $2: $4"; return 2 ;;
  esac
  printf '%s' "${content/"$4"/$5}" > "$f"
  if QUIET=1 PRQ_PLUGIN_DIR="$dir" bash "${here}/$3.sh" >"${dir}.log" 2>&1; then
    echo "SURVIVED $1 ($3 matrix stayed green)"; return 1
  fi
  echo "killed   $1 ($(grep -c '^FAIL' "${dir}.log") failing case(s) in $3)"
}

mut() {
  [ "$want" = "  " ] || case "$want" in *" $1 "*) ;; *) return 0 ;; esac
  ran=$((ran + 1))
  run_one "$@" > "${work}/$1.result" 2>&1 &
  pids="$pids $!"; names="$names $1"
  if [ "$(printf '%s' "$pids" | wc -w)" -ge 6 ]; then
    for p in $pids; do wait "$p" || fails=$((fails + 1)); done
    pids=""
  fi
}

# mut <name> <file in the plugin> <suite> <anchor text> <replacement>
mut gate-off hooks/pr-gate.sh gate 'prq_read_input' 'prq_read_input; exit 0'
mut head-binding hooks/pr-gate.sh gate 'if [ -n "$head" ] && [ "$head" != "$PRQ_BRANCH" ]; then' 'if false; then'
mut repo-binding hooks/pr-gate.sh gate 'prq_same_repo "$r" "$PRQ_ORIGIN" || prq_deny' 'true || prq_deny'
mut raw-api hooks/pr-gate.sh gate 'api_posts_pr "$@" && deny_raw "gh api"' 'true'
mut graphql hooks/pr-gate.sh gate 'case "$2" in *createPullRequest*' 'case "$2" in NOPE*'
mut continuation hooks/pr-gate.sh gate 'cmd="${cmd//"$cont"/ }"' ':'
mut gh-leading-flags hooks/pr-gate.sh gate 'gh_normalize "$@"' 'GH_WORDS=("$@")'
mut dynamic-program hooks/pr-gate.sh gate '*'"'"'$'"'"'*)
      case " $* " in' '*NOPE*)
      case " $* " in'
mut unknown-dir hooks/pr-gate.sh gate '[ -n "$dir" ] || prq_deny' 'true || prq_deny'
mut pushd hooks/pr-gate.sh gate 'if [ "$prog" = cd ] || [ "$prog" = pushd ]; then' 'if [ "$prog" = cd ]; then'
mut redirections hooks/pr-gate.sh gate "cmd=\"\$(printf '%s' \"\$cmd\" | sed -E -e 's/[0-9]*(>>?|<)[&|]?[[:space:]]*[^[:space:]]*/ /g')\"" ':'
mut subshell-scope hooks/pr-gate.sh gate '*__PRQ_CLOSE__*) [ ${#dirs[@]} -gt 0 ] && {' '*__PRQ_CLOSE__*) false && {'
mut gh-flag-values hooks/pr-gate.sh gate '--?*|-?) lead+=("${w[$i]}" "${w[$((i + 1))]:-}"); i=$((i + 2)) ;;' '--?*|-?) lead+=("${w[$i]}"); i=$((i + 1)) ;;'
mut curl-combined hooks/pr-gate.sh gate '"curl -"*d*|"curl -"*F*|"curl -"*T*) data=1 ;;' '"curl -d"|"curl -F"|"curl -T") data=1 ;;'
mut env-gh-repo hooks/pr-gate.sh gate '        case "$w" in GH_REPO=*) GH_REPO_CUR="${w#GH_REPO=}" ;; esac
        i=$((i + 1))' '        i=$((i + 1))'
mut repo-host hooks/_lib.sh gate 'u="${host%%:*}/${u#*/}"' 'u="${u#*/}"'
mut gh-merge-base hooks/_lib.sh gate 'b="$(git config --get "branch.${PRQ_BRANCH}.gh-merge-base" 2>/dev/null)"' 'b=""'
mut delta-revert hooks/_lib.sh quiz '[ -n "$files" ] || files="$(git diff --name-only "$3" HEAD | sort -u)"' ':'
mut celebration hooks/quiz-post.sh quiz '{systemMessage:$m, hookSpecificOutput' '{hookSpecificOutput'
mut alias-resolution hooks/pr-gate.sh gate '[ -n "$exp" ] || return 0' 'return 0'
mut base-binding hooks/_lib.sh gate 'if [ "$p_base" != "$base" ]; then' 'if false; then'
mut stable-patch-id hooks/_lib.sh gate '| git patch-id --verbatim | cut' '| git patch-id --stable | cut'
mut rebase-walk hooks/_lib.sh gate 'if [ "$(prq_patch_id "$base_ref" "$c")" = "$p_pid" ]; then' 'if false; then'
mut delta-count hooks/_lib.sh gate 'PRQ_COUNT=$PRQ_DELTA_COUNT; PRQ_FROM="$p_head"' 'PRQ_COUNT=$PRQ_FULL_COUNT; PRQ_FROM="$p_head"'
mut grade-always-ok hooks/quiz-post.sh quiz 'verdict: (if $afk then "timeout"' 'verdict: (if true then "ok" elif $afk then "timeout"'
mut timeout-ok hooks/quiz-post.sh quiz 'then "timeout"' 'then "ok"'
mut followup-ok hooks/quiz-post.sh quiz 'then "followup"' 'then "ok"'
mut missing-ok hooks/quiz-post.sh quiz 'then "missing"' 'then "ok"'
mut idk-ok hooks/quiz-post.sh quiz 'then "idk"' 'then "ok"'
mut wrong-ok hooks/quiz-post.sh quiz 'then "wrong"' 'then "ok"'
mut other-ok hooks/quiz-post.sh quiz 'else "other" end' 'else "ok" end'
mut pass-on-failure hooks/quiz-post.sh quiz 'if [ "$nfail" -eq 0 ]; then' 'if true; then'
# 0.3.0: feedback after each call, the recap, the gate additions and the merge check.
mut call-explain hooks/quiz-post.sh quiz '(.[] | select(explain) | "Explained:' '(.[] | select(false) | "Explained:'
mut wrong-hidden hooks/quiz-post.sh quiz 'map("\(.label) \"\(.question)\"") | join("; ")' 'map("\(.label) \"\(.question)\" \(.correct)") | join("; ")'
mut wrong-log hooks/quiz-post.sh quiz 'select(.verdict != "ok" and .verdict != "idk" and .verdict != "other")' 'select(false)'
mut recap hooks/quiz-post.sh quiz '(.wrong_log // []) | if length == 0 then ""' '[] | if length == 0 then ""'
mut ready-ask hooks/quiz-post.sh quiz 'whether they are ready for round' 'whether to go on with round'
mut reset-all skills/quiz/scripts/pr-quiz quiz '"${PRQ_STATE}/pass.json" "${PRQ_STATE}/merge-check.json"' '"${PRQ_STATE}/merge-check.json"'
mut quoted-words hooks/_lib.sh gate $'\'"\'|"\'") q="$c"; have=1 ;;' $'\'"\'|"\'") have=1 ;;'
mut status-api hooks/pr-gate.sh gate 'api_posts_status "$@" && deny_status "gh api"' 'true'
mut status-http hooks/pr-gate.sh gate 'http_path statuses "$@" && deny_status "$prog"' 'true'
mut http-scheme hooks/pr-gate.sh gate '    case "$kind $w" in' '    case "$kind $w" in "pulls "[!h]*|"statuses "[!h]*) ;;'
mut wget hooks/pr-gate.sh gate '"wget --post-data"*|' '"wget --NOPE"*|'
mut az-invoke-status hooks/pr-gate.sh gate '*status*) deny_status "az devops invoke" ;;' 'NOPE) deny_status "az devops invoke" ;;'
mut az-rest-status hooks/pr-gate.sh gate 'http_path statuses "$w" && deny_status "az rest"' 'true'
mut admin-merge hooks/pr-gate.sh gate 'has_word --admin "$@" && deny_policy "gh pr merge --admin"' 'true'
mut bypass-policy hooks/pr-gate.sh gate 'case "$v" in true|True|TRUE) deny_policy' 'case "$v" in NOPE) deny_policy'
mut mcp-bypass hooks/pr-gate.sh gate '[ "$(prq_field '"'"'.tool_input.bypassPolicy'"'"')" = true ] && deny_policy' 'false && deny_policy'
mut mcp-ado-create hooks/pr-gate.sh gate '  mcp__*repo_pull_request_write)' '  mcp__*NOPE)'
mut mcp-status hooks/pr-gate.sh gate '  mcp__*create_commit_status*)' '  mcp__*NOPE*)'
mut ado-repo hooks/pr-gate.sh gate 'if [ -n "$repo" ] && [ "$(ado_lc "$repo")" != "$(ado_lc "$PRQ_ADO_REPO")" ]; then' 'if false; then'
mut ado-guid hooks/pr-gate.sh gate '????????-????-????-????-????????????) prq_deny' 'NOPE) prq_deny'
mut ado-project hooks/pr-gate.sh gate 'if [ -n "$proj" ] && [ "$(ado_lc "$proj")" != "$(ado_lc "$PRQ_ADO_PROJECT")" ]; then' 'if false; then'
mut ado-org hooks/pr-gate.sh gate '[ "$o" = "$(ado_lc "$PRQ_ADO_ORG")" ] || prq_deny' 'true || prq_deny'
mut ado-decode hooks/_lib.sh merge 'PRQ_ADO_REPO="$(prq_urldecode "$repo")"' 'PRQ_ADO_REPO="$repo"'
mut mc-default-on hooks/merge-check-lib.sh merge '"") [ "$file" = true ] && PRQ_MC=on ;;' '"") PRQ_MC=on ;;'
mut mc-env-off hooks/merge-check-lib.sh merge 'off) PRQ_MC=off; [ "$file" = true ] && PRQ_MC_OVERRIDE=1 ;;' 'off) [ "$file" = true ] && PRQ_MC=on ;;'
mut mc-override hooks/merge-check-lib.sh merge 'off) PRQ_MC=off; [ "$file" = true ] && PRQ_MC_OVERRIDE=1 ;;' 'off) PRQ_MC=off ;;'
mut mc-bad-value hooks/merge-check-lib.sh merge 'bad) PRQ_MC=error;' 'bad) PRQ_MC=on;'
mut mc-repo-binding hooks/merge-check-lib.sh merge '|| [ "$(jq -r '"'"'.repo // ""'"'"' "$pass")" != "$PRQ_ORIGIN" ]; then' '; then'
mut mc-remote-base hooks/merge-check-lib.sh merge 'if [ -z "$cur" ] || [ "$cur" != "$pid" ]; then' 'if false; then'
mut mc-fetch hooks/merge-check-lib.sh merge 'if ! git cat-file -e "${R}^{commit}" 2>/dev/null; then' 'if false; then'
mut mc-dedupe hooks/merge-check-lib.sh merge 'prq_mc_seen "$ghkey" && { prq_mc_set skip ""; return 0; }' ':'
mut mc-422 hooks/merge-check-lib.sh merge '*"HTTP 422"*) prq_mc_set notyet' '*"NOPE"*) prq_mc_set notyet'
mut mc-target-filter hooks/merge-check-lib.sh merge '&searchCriteria.targetRefName=${tgt}' ''
mut mc-iteration hooks/merge-check-lib.sh merge '[.value[]? | select(.sourceRefCommit.commitId == $h) | .id] | max' '[.value[]? | .id] | max'
mut mc-token-argv hooks/merge-check-lib.sh merge '| curl -sS --max-time 15 -K -' '| curl -sS --max-time 15 -H "Authorization: $PRQ_ADO_AUTH" -K -'
mut mc-ado-dedupe hooks/merge-check-lib.sh merge 'if [ "$state" = succeeded ] && prq_mc_seen "ado:${api}:${id}:${it}"; then' 'if false; then'
mut mc-pending skills/quiz/scripts/pr-quiz merge '      prq_mc_run pending' '      :'
mut mc-at-pass hooks/quiz-post.sh merge '  prq_mc_run success' '  :'
# Codex code review round 3.
mut pass1-off hooks/pr-gate.sh gate $'    cmd="$(prq_field \'.tool_input.command\')"\n    check_command 0 "$cmd"' $'    cmd="$(prq_field \'.tool_input.command\')"\n    :'
mut pass2-off hooks/pr-gate.sh gate 'PRQ_QUOTED=1; check_command 0 "$cmd"' ':'
mut eval-persist hooks/pr-gate.sh gate '[ "$depth" -lt 4 ] && check_command "$((depth + 1))" "$*"
          return 0 ;;
        watch)' '[ "$depth" -lt 4 ] && { saved="$EFF_DIR"; check_command "$((depth + 1))" "$*"; EFF_DIR="$saved"; }
          return 0 ;;
        watch)'
mut eval-join hooks/pr-gate.sh gate '[ "$depth" -lt 4 ] && check_command "$((depth + 1))" "$*"
          return 0 ;;
        watch)' '[ "$depth" -lt 4 ] && check_command "$((depth + 1))" "$1"
          return 0 ;;
        watch)'
mut shell-c hooks/pr-gate.sh gate '-*c*|+*c*) found=1 ;;' 'NOPE) found=1 ;;'
mut http-get hooks/pr-gate.sh gate '""|GET|HEAD|OPTIONS) return 1 ;;' 'NOPE) return 1 ;;'
mut recap-explained hooks/quiz-post.sh quiz 'select(.verdict != "ok" and .verdict != "idk" and .verdict != "other")' 'select(.verdict != "ok")'
mut mc-head-captured hooks/merge-check-lib.sh merge 'cur="$(prq_patch_id "$R" "$PRQ_HEAD")"' 'cur="$(prq_patch_id "$R" HEAD)"'
mut mc-dedupe-repo hooks/merge-check-lib.sh merge 'ghkey="github:${PRQ_GH_HOST:-}/${PRQ_GH_REPO:-}:${PRQ_HEAD}"' 'ghkey="github:${PRQ_HEAD}"'
mut pass-scope hooks/quiz-post.sh merge "scope=\"\$(jq -r '.mb // .base_ref' \"\$round\")\"" "scope=\"\$(jq -r '.base_ref' \"\$round\")\""
mut trigger-cd hooks/merge-check.sh merge '[ -d "$t" ] && dir="$(cd "$t" && pwd)"' ':'
mut redirect-sed-quoted hooks/pr-gate.sh gate 'if [ "${PRQ_QUOTED:-0}" != 1 ]; then' 'if true; then'
mut redirect-skip hooks/_lib.sh gate $'      \'<\'|\'>\')\n        t="$seg"' $'      \'NOPE\')\n        t="$seg"'
mut child-gh-repo hooks/pr-gate.sh gate 'EFF_DIR="$saved"; GH_REPO_CUR="$saved_repo"; }
        return 0 ;;' 'EFF_DIR="$saved"; }
        return 0 ;;'
mut eval-dashdash hooks/pr-gate.sh gate '[ "${1:-}" = "--" ] && shift' ':'
mut trigger-dir hooks/merge-check.sh merge 'target="$dir" ;; esac' ': ;; esac'
mut trigger-segments hooks/merge-check.sh merge 'done < <(quoted_segments "$cmd")' 'done < <(printf "%s\036" "$cmd" | tr ";&|()" "\036\036\036\036\036")'
mut trigger-words hooks/merge-check.sh merge $'      *push*|*pr*create*|*pr*new*|*pull-request*) ;;' $'      *push*|*"pr create"*|*"pr new"*) ;;'
mut idk-option hooks/quiz-pre.sh quiz '(($k.options + [$idk]) | sort)' '([$q.options[]?.label] | sort)'
mut prefilled hooks/quiz-pre.sh quiz '(if ($in.answers // {} | length) > 0' '(if false'
mut multiselect hooks/quiz-pre.sh quiz '(if ($q.multiSelect // false) then' '(if false then'
mut key-freeze hooks/quiz-pre.sh quiz '[ -z "$frozen" ] || [ "$frozen" = "$sha" ] ||' 'true ||'
mut head-moved hooks/quiz-pre.sh quiz '[ "$(jq -r .head "$round")" = "$PRQ_HEAD" ] ||' 'true ||'
mut retry-topics skills/quiz/scripts/pr-quiz quiz '(if ([$qs[].topic] | sort) != ($topics | sort)' '(if false'
mut key-evidence skills/quiz/scripts/pr-quiz quiz '($files | index($q.evidence | evpath)) == null' 'false'
mut state-path hooks/state-guard.sh guard '*/.git/*pr-quiz*|.git/*pr-quiz*) prq_deny' '*/NOPE/*) prq_deny'
mut plugin-disable hooks/state-guard.sh guard '(disable|uninstall|remove|rm)' '(NOPE)'
for p in $pids; do wait "$p" || fails=$((fails + 1)); done
for n in $names; do cat "${work}/${n}.result"; done
printf '\nmutation.sh: %d mutants, %d not killed\n' "$ran" "$fails"
[ "$ran" -gt 0 ] && [ "$fails" = 0 ]
