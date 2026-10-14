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
mut redirections hooks/pr-gate.sh gate "-e 's/[0-9]*(>>?|<)[&|]?[[:space:]]*[^[:space:]]*/ /g'" ''
mut subshell-scope hooks/pr-gate.sh gate '*__PRQ_CLOSE__*) [ ${#dirs[@]} -gt 0 ] && {' '*__PRQ_CLOSE__*) false && {'
mut gh-flag-values hooks/pr-gate.sh gate '--?*|-?) lead+=("${w[$i]}" "${w[$((i + 1))]:-}"); i=$((i + 2)) ;;' '--?*|-?) lead+=("${w[$i]}"); i=$((i + 1)) ;;'
mut curl-combined hooks/pr-gate.sh gate '-*X*|-*d*|-*F*|-*T*) post=1 ;;' '-X|-d|-F|-T) post=1 ;;'
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
