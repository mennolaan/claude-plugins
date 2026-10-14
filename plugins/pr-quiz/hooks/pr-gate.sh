#!/usr/bin/env bash
# pr-quiz gate. PreToolUse on Bash and on MCP pull-request tools.
# Denies PR creation until the developer holds a quiz pass for the branch,
# base and repo that the PR uses. Heuristic shell parsing: a command inside a
# script file or a shell function is out of reach (README, Limits).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

GATED_PROGS=" gh glab az hub tea curl "
WRAPPERS=" bash sh zsh dash ksh eval xargs env nohup time timeout gtimeout sudo nice watch caffeinate exec command builtin "

prq_read_input
case "$PRQ_IN" in
  *gh*|*glab*|*az*|*hub*|*tea*|*curl*|*mcp__*) ;;
  *) exit 0 ;;
esac
prq_require_tools

tool="$(prq_field '.tool_name')"
hook_cwd="$(prq_field '.cwd')"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"

unquote() { local w="$1"; w="${w//\"/}"; w="${w//\'/}"; printf '%s' "${w#\\}"; }

# flag_value <short> <long> <words...>: the last value of a flag, or empty.
flag_value() {
  local s="$1" l="$2" v="" w
  shift 2
  while [ $# -gt 0 ]; do
    w="$1"; shift
    if { [ -n "$s" ] && [ "$w" = "$s" ]; } || [ "$w" = "$l" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; continue; fi
    case "$w" in "$l="*) v="${w#"$l="}"; continue ;; esac
    if [ -n "$s" ]; then case "$w" in "$s"?*) v="${w#"$s"}" ;; esac; fi
  done
  printf '%s' "$v"
}

has_word() { local n="$1" w; shift; for w in "$@"; do [ "$w" = "$n" ] && return 0; done; return 1; }

# decide <label> <head> <base> <repo> <dir>: allow (return) or deny (exit).
decide() {
  local label="$1" head="$2" base="$3" repo="$4" dir="$5" r
  prq_repo_ctx "$dir" || prq_deny "pr-quiz: ${label} runs outside a git checkout (${dir}). Run it from the checkout of the PR branch, so that pr-quiz can check the quiz pass."
  [ -n "$PRQ_BRANCH" ] || prq_deny "pr-quiz: HEAD is detached in ${PRQ_TOP}. Check out the PR branch, then run ${label} again."
  head="${head#refs/heads/}"; head="${head##*:}"
  if [ -n "$head" ] && [ "$head" != "$PRQ_BRANCH" ]; then
    prq_deny "pr-quiz: the PR head is ${head}, but the checkout is on ${PRQ_BRANCH}. The quiz covers the checked-out branch only. Check out ${head} (or open a worktree for it), pass its quiz, and run ${label} there."
  fi
  if [ -n "$repo" ]; then
    r="$(prq_norm_repo "$repo")"
    [ "$r" = "$PRQ_ORIGIN" ] || prq_deny "pr-quiz: the PR repo is ${r}, but origin is ${PRQ_ORIGIN:-not set}. pr-quiz checks PRs to the origin repo only. Remove the repo option, or open this PR in your own terminal."
  fi
  base="${base#refs/heads/}"
  [ -n "$base" ] || base="$(prq_default_base)"
  [ -n "$base" ] || prq_deny "pr-quiz: cannot find the default branch of origin. Add the base branch option to ${label}, for example --base main."
  prq_base_ref "$base" >/dev/null || prq_deny "pr-quiz: base branch ${base} is not known in this checkout. Run: git fetch origin ${base}. Then run ${label} again."
  prq_need "$base"
  [ "$PRQ_NEED" = ok ] && return 0
  prq_deny "pr-quiz: PR creation is blocked. ${PRQ_WHY} Invoke the skill ${PRQ_SKILL} now (mode ${PRQ_NEED}, ${PRQ_COUNT} questions, base ${base}). When the quiz reports PASS, run ${label} again."
}

deny_raw() {
  prq_deny "pr-quiz: ${1} creates a pull request through the raw API. pr-quiz cannot check its head and base. Use gh pr create (or glab mr create) instead."
}

# api_posts_pr <words after 'api'>: true when the call creates a PR or MR.
api_posts_pr() {
  local w method="" endpoint="" implied=0 all=" $* "
  case "$all" in *createPullRequest*|*createMergeRequest*|*mergeRequestCreate*) return 0 ;; esac
  while [ $# -gt 0 ]; do
    w="$1"; shift
    case "$w" in
      -X|--method) method="${1:-}"; [ $# -gt 0 ] && shift ;;
      -X?*) method="${w#-X}" ;;
      --method=*) method="${w#--method=}" ;;
      -f|-F|--field|--raw-field|--input) implied=1; [ $# -gt 0 ] && shift ;;
      -f?*|-F?*|--field=*|--raw-field=*|--input=*) implied=1 ;;
      -H|--header|-q|--jq|-t|--template|-p|--preview|--hostname|--cache) [ $# -gt 0 ] && shift ;;
      -*) ;;
      *) [ -z "$endpoint" ] && endpoint="$w" ;;
    esac
  done
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  case "$endpoint" in
    *pulls|*pulls/|*pulls\?*|*merge_requests|*merge_requests/|*merge_requests\?*|*pullrequests|*pullrequests\?*) ;;
    *) return 1 ;;
  esac
  [ "$method" = POST ] || { [ -z "$method" ] && [ "$implied" = 1 ]; }
}

curl_posts_pr() {
  local all=" $* " w url=0 post=0
  case "$all" in *createPullRequest*|*createMergeRequest*) return 0 ;; esac
  for w in "$@"; do
    case "$w" in
      http*://*/pulls|http*://*/pulls/|http*://*/pulls\?*|http*://*/merge_requests|http*://*/merge_requests\?*|http*://*/pullrequests|http*://*/pullrequests\?*) url=1 ;;
    esac
  done
  case "$all" in
    *" -X POST "*|*" -XPOST "*|*" --request POST "*|*" --request=POST "*|*" -d "*|*" -d"*|*" --data"*|*" --json "*|*" -F "*|*" --form "*) post=1 ;;
  esac
  [ "$url" = 1 ] && [ "$post" = 1 ]
}

# check_gh <depth> <words after 'gh'>
check_gh() {
  local depth="$1" sub exp rest repo w prev ready_base
  shift
  sub="${1:-}"
  case "$sub" in
    pr)
      case "${2:-}" in
        create|new)
          shift 2
          repo="$(flag_value -R --repo "$@")"; [ -n "$repo" ] || repo="$GH_REPO_CUR"
          decide "gh pr create" "$(flag_value -H --head "$@")" "$(flag_value -B --base "$@")" "$repo" "$EFF_DIR"
          ;;
        ready)
          shift 2
          has_word --undo "$@" && return 0
          prev=""
          for w in "$@"; do
            case "$prev" in -R|--repo) prev=""; continue ;; esac
            case "$w" in -*) prev="$w" ;; *) prq_deny "pr-quiz: gh pr ready ${w} names a PR that pr-quiz cannot map to a checkout. Run gh pr ready without a number from the PR branch checkout." ;; esac
          done
          ready_base=""
          prq_repo_ctx "$EFF_DIR" && [ -f "${PRQ_STATE}/pass.json" ] && ready_base="$(jq -r '.base // ""' "${PRQ_STATE}/pass.json")"
          repo="$(flag_value -R --repo "$@")"; [ -n "$repo" ] || repo="$GH_REPO_CUR"
          decide "gh pr ready" "" "$ready_base" "$repo" "$EFF_DIR"
          ;;
      esac
      ;;
    api)
      shift
      api_posts_pr "$@" && deny_raw "gh api"
      ;;
    alias)
      case "${2:-}" in
        set)
          shift 2
          case " $* " in
            *"pr create"*|*"pr new"*|*"pr ready"*|*" api "*|*"api "*|*pull-request*|*"mr create"*) prq_deny "pr-quiz: this gh alias would create or ready a pull request outside the gate. Add such aliases in your own terminal." ;;
          esac
          ;;
        import) prq_deny "pr-quiz: gh alias import is blocked while pr-quiz is on, because pr-quiz cannot read the imported aliases. Run it in your own terminal." ;;
      esac
      ;;
    ""|-*) ;;
    *)
      [ "$depth" -lt 3 ] || return 0
      exp="$(gh alias list 2>/dev/null | awk -v n="$sub" 'index($0, n ": ") == 1 { print substr($0, length(n) + 3); exit }')"
      [ -n "$exp" ] || return 0
      exp="${exp#\'}"; exp="${exp%\'}"
      shift
      rest="$*"
      case "$exp" in
        !*) check_command "$((depth + 1))" "${exp#!} ${rest}" ;;
        *) # shellcheck disable=SC2086  # an alias expansion is a word list
           check_gh "$((depth + 1))" $exp "$@" ;;
      esac
      ;;
  esac
}

# check_words <depth> <words of one simple command>
check_words() {
  local depth="$1" prog w i
  shift
  # Skip assignments and transparent prefixes; record GH_REPO.
  while [ $# -gt 0 ]; do
    case "$1" in
      GH_REPO=*) GH_REPO_CUR="${1#GH_REPO=}"; shift ;;
      [A-Za-z_]*=*) shift ;;
      if|then|else|elif|do|while|until|'!') shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  prog="${1##*/}"
  if [ "$prog" = cd ]; then
    local t="${2:-$HOME}"
    case "$t" in \~) t="$HOME" ;; \~/*) t="${HOME}/${t#\~/}" ;; esac
    case "$t" in /*) ;; *) t="${EFF_DIR}/${t}" ;; esac
    [ -d "$t" ] && EFF_DIR="$(cd "$t" && pwd)"
    return 0
  fi
  if [ "$prog" = export ]; then
    for w in "$@"; do case "$w" in GH_REPO=*) GH_REPO_CUR="${w#GH_REPO=}" ;; esac; done
    return 0
  fi
  case "$WRAPPERS" in
    *" $prog "*)
      shift; i=0
      for w in "$@"; do
        case "$GATED_PROGS" in *" ${w##*/} "*) shift "$i"; check_words "$((depth + 1))" "$@"; return 0 ;; esac
        i=$((i + 1))
      done
      return 0
      ;;
  esac
  shift
  case "$prog" in
    gh) check_gh "$depth" "$@" ;;
    glab)
      case "${1:-} ${2:-}" in
        "mr create"|"mr new") shift 2; decide "glab mr create" "$(flag_value -s --source-branch "$@")" "$(flag_value -b --target-branch "$@")" "$(flag_value -R --repo "$@")" "$EFF_DIR" ;;
        api*) shift; api_posts_pr "$@" && deny_raw "glab api" ;;
      esac
      ;;
    hub)
      case "${1:-}" in
        pull-request) shift; decide "hub pull-request" "$(flag_value -h --head "$@")" "$(flag_value -b --base "$@")" "" "$EFF_DIR" ;;
        api) shift; api_posts_pr "$@" && deny_raw "hub api" ;;
      esac
      ;;
    tea)
      case "${1:-} ${2:-}" in
        "pulls create"|"pull create"|"pr create"|"pulls c"|"pull c"|"pr c") shift 2; decide "tea pr create" "$(flag_value "" --head "$@")" "$(flag_value "" --base "$@")" "$(flag_value -r --repo "$@")" "$EFF_DIR" ;;
      esac
      ;;
    az)
      case "${1:-} ${2:-} ${3:-}" in
        "repos pr create") shift 3; decide "az repos pr create" "$(flag_value -s --source-branch "$@")" "$(flag_value -t --target-branch "$@")" "" "$EFF_DIR" ;;
      esac
      ;;
    curl) curl_posts_pr "$@" && deny_raw "curl" ;;
  esac
  return 0
}

# check_command <depth> <command string>
check_command() {
  local depth="$1" seg w
  local -a words raw
  case "$2" in *createPullRequest*|*createMergeRequest*|*mergeRequestCreate*) deny_raw "a GraphQL mutation" ;; esac
  while IFS= read -r seg; do
    words=()
    read -r -a raw <<< "$seg" || true
    for w in ${raw[@]+"${raw[@]}"}; do words+=("$(unquote "$w")"); done
    [ ${#words[@]} -gt 0 ] && check_words "$depth" "${words[@]}"
  done < <(printf '%s\n' "$2" | tr ';&|(){}`' '\n\n\n\n\n\n\n\n')
}

EFF_DIR="$hook_cwd"
GH_REPO_CUR="${GH_REPO:-}"

case "$tool" in
  Bash)
    check_command 0 "$(prq_field '.tool_input.command')"
    ;;
  mcp__*)
    head="$(prq_field '.tool_input.head // .tool_input.source_branch // .tool_input.sourceRefName // .tool_input.source_ref')"
    base="$(prq_field '.tool_input.base // .tool_input.target_branch // .tool_input.targetRefName // .tool_input.target_ref')"
    repo="$(prq_field 'if (.tool_input.owner and .tool_input.repo) then "\(.tool_input.owner)/\(.tool_input.repo)" else empty end')"
    decide "${tool}" "$head" "$base" "$repo" "$EFF_DIR"
    ;;
esac
exit 0
