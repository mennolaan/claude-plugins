#!/usr/bin/env bash
# pr-quiz gate. PreToolUse on Bash and on MCP pull-request tools.
# Denies PR creation until the developer holds a quiz pass for the branch,
# base and repo that the PR uses. Heuristic shell parsing: a command defined
# elsewhere and run by name is out of reach (README, Limits); what it cannot
# resolve (dynamic program names or directories) it denies.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
. "${here}/_lib.sh"

GATED_PROGS=" gh glab az hub tea curl wget "
SHELL_PROGS=" bash sh zsh dash ksh eval watch "
WRAPPERS=" bash sh zsh dash ksh eval xargs env nohup time timeout gtimeout sudo nice watch caffeinate exec command builtin "

prq_read_input
case "$PRQ_IN" in
  *gh*|*glab*|*az*|*hub*|*tea*|*curl*|*wget*|*mcp__*|*pr*|*pull*|*mr*|*statuses*|*'$'*) ;;
  *) exit 0 ;;
esac
prq_require_tools

tool="$(prq_field '.tool_name')"
hook_cwd="$(prq_field '.cwd')"
[ -n "$hook_cwd" ] || hook_cwd="$PWD"


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
  [ -n "$dir" ] || prq_deny "pr-quiz: cannot tell which checkout ${label} runs in (a cd or pushd with a variable or an option, cd -, or popd). Run ${label} from the checkout without a dynamic directory change."
  prq_repo_ctx "$dir" || prq_deny "pr-quiz: ${label} runs outside a git checkout (${dir}). Run it from the checkout of the PR branch, so that pr-quiz can check the quiz pass."
  [ -n "$PRQ_BRANCH" ] || prq_deny "pr-quiz: HEAD is detached in ${PRQ_TOP}. Check out the PR branch, then run ${label} again."
  head="${head#refs/heads/}"; head="${head##*:}"
  if [ -n "$head" ] && [ "$head" != "$PRQ_BRANCH" ]; then
    prq_deny "pr-quiz: the PR head is ${head}, but the checkout is on ${PRQ_BRANCH}. The quiz covers the checked-out branch only. Check out ${head} (or open a worktree for it), pass its quiz, and run ${label} there."
  fi
  if [ -n "$repo" ]; then
    r="$(prq_norm_repo "$repo")"
    prq_same_repo "$r" "$PRQ_ORIGIN" || prq_deny "pr-quiz: the PR repo is ${r}, but origin is ${PRQ_ORIGIN:-not set}. pr-quiz checks PRs to the origin repo only. Remove the repo option, or open this PR in your own terminal."
  fi
  base="${base#refs/heads/}"
  [ -n "$base" ] || base="$(prq_pr_base)"
  [ -n "$base" ] || prq_deny "pr-quiz: cannot find the default branch of origin. Add the base branch option to ${label}, for example --base main."
  prq_base_ref "$base" >/dev/null || prq_deny "pr-quiz: base branch ${base} is not known in this checkout. Run: git fetch origin ${base}. Then run ${label} again."
  prq_need "$base"
  [ "$PRQ_NEED" = ok ] && return 0
  prq_deny "pr-quiz: PR creation is blocked. ${PRQ_WHY} Invoke the skill ${PRQ_SKILL} now (mode ${PRQ_NEED}, ${PRQ_COUNT} questions, base ${base}). When the quiz reports PASS, run ${label} again."
}

deny_raw() {
  prq_deny "pr-quiz: ${1} creates a pull request through the raw API. pr-quiz cannot check its head and base. Use gh pr create (or glab mr create) instead."
}

deny_status() {
  prq_deny "pr-quiz: ${1} writes a commit or pull request status. Only the pr-quiz helper posts the merge check status, after a quiz pass. Run the quiz (${PRQ_SKILL}), or run its helper with publish."
}

deny_policy() {
  prq_deny "pr-quiz: ${1} skips the branch rules or policies that the merge check depends on. Merge without it, or do it yourself in your own terminal."
}

# api_call <words after 'api'>: sets API_METHOD (upper case; POST when a field
# implies it) and API_ENDPOINT.
api_call() {
  local w method="" endpoint="" implied=0
  while [ $# -gt 0 ]; do
    w="$1"; shift
    case "$w" in
      -X|--method) method="${1:-}"; [ $# -gt 0 ] && shift ;;
      -X?*) method="${w#-X}" ;;
      -[a-zA-Z]*X) method="${1:-}"; [ $# -gt 0 ] && shift ;;
      -[a-zA-Z]*X?*) method="${w#*X}" ;;
      --method=*) method="${w#--method=}" ;;
      -f|-F|--field|--raw-field|--input) implied=1; [ $# -gt 0 ] && shift ;;
      -f?*|-F?*|--field=*|--raw-field=*|--input=*) implied=1 ;;
      -H|--header|-q|--jq|-t|--template|-p|--preview|--hostname|--cache) [ $# -gt 0 ] && shift ;;
      -*) ;;
      *) [ -z "$endpoint" ] && endpoint="$w" ;;
    esac
  done
  API_METHOD="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"
  [ -z "$API_METHOD" ] && [ "$implied" = 1 ] && API_METHOD=POST
  API_ENDPOINT="$endpoint"
}

# api_posts_pr <words after 'api'>: true when the call creates a PR or MR.
api_posts_pr() {
  case " $* " in *createPullRequest*|*createMergeRequest*|*mergeRequestCreate*) return 0 ;; esac
  api_call "$@"
  case "$API_ENDPOINT" in
    *pulls|*pulls/|*pulls\?*|*merge_requests|*merge_requests/|*merge_requests\?*|*pullrequests|*pullrequests\?*) ;;
    *) return 1 ;;
  esac
  [ "$API_METHOD" = POST ]
}

# api_posts_status <words after 'api'>: true when the call writes a status.
api_posts_status() {
  api_call "$@"
  case "$API_ENDPOINT" in *statuses|*statuses/*|*statuses\?*) ;; *) return 1 ;; esac
  [ "$API_METHOD" = POST ] || [ "$API_METHOD" = PATCH ]
}

# http_writes <curl | wget> <words>: true when the request sends data or sets a method.
http_writes() {
  local prog="$1" w m="" data=0 next=0
  shift
  for w in "$@"; do
    if [ "$next" = 1 ]; then m="$w"; next=0; continue; fi
    case "$prog $w" in
      "curl --request-target"*) ;;
      "curl --request="*) m="${w#--request=}" ;;
      "curl --request") next=1 ;;
      "curl --data"*|"curl --json"*|"curl --form"*|"curl --upload-file"*) data=1 ;;
      "curl --"*) ;;
      "curl -"*X) next=1; case "$w" in -*[dFT]*X) data=1 ;; esac ;;
      "curl -"*X?*) m="${w#*X}"; case "${w%%X*}" in *[dFT]*) data=1 ;; esac ;;
      "curl -"*d*|"curl -"*F*|"curl -"*T*) data=1 ;;
      "wget --method="*) m="${w#--method=}" ;;
      "wget --method") next=1 ;;
      "wget --post-data"*|"wget --post-file"*|"wget --body-data"*|"wget --body-file"*) data=1 ;;
    esac
  done
  [ "$data" = 1 ] && return 0
  case "$(printf '%s' "$m" | tr '[:lower:]' '[:upper:]')" in ""|GET|HEAD|OPTIONS) return 1 ;; esac
  return 0
}

# http_path <pulls | statuses> <words>: true when any word has that API path: a URL
# with or without a scheme, or a curl --request-target value.
http_path() {
  local kind="$1" w
  shift
  for w in "$@"; do
    case "$kind $w" in
      "pulls "*/pulls|"pulls "*/pulls/|"pulls "*/pulls\?*|"pulls "*/merge_requests|"pulls "*/merge_requests\?*|"pulls "*/pullrequests|"pulls "*/pullrequests\?*|"pulls "*/pullRequests|"pulls "*/pullRequests\?*) return 0 ;;
      "statuses "*/statuses|"statuses "*/statuses/*|"statuses "*/statuses\?*) return 0 ;;
    esac
  done
  return 1
}

# check_http <curl | wget> <words after the program>
check_http() {
  local prog="$1"
  shift
  case " $* " in *createPullRequest*|*createMergeRequest*) deny_raw "$prog" ;; esac
  http_writes "$prog" "$@" || return 0
  http_path pulls "$@" && deny_raw "$prog"
  http_path statuses "$@" && deny_status "$prog"
  return 0
}

# check_az <words after az>
check_az() {
  local w v
  case "${1:-} ${2:-} ${3:-}" in
    "repos pr create"|"repos pr update")
      for w in "$@"; do case "$w" in --bypass-policy=[Tt]rue|--bypass-policy=TRUE) deny_policy "az repos pr ${3} --bypass-policy" ;; esac; done
      v="$(flag_value "" --bypass-policy "$@")"
      case "$v" in true|True|TRUE) deny_policy "az repos pr ${3} --bypass-policy" ;; esac
      ;;
  esac
  case "${1:-} ${2:-} ${3:-}" in
    "repos pr create")
      shift 3
      ado_target_check "az repos pr create" "$(flag_value -r --repository "$@")" "$(flag_value -p --project "$@")" "$(flag_value "" --org "$@")$(flag_value "" --organization "$@")"
      decide "az repos pr create" "$(flag_value -s --source-branch "$@")" "$(flag_value -t --target-branch "$@")" "" "$EFF_DIR"
      return 0
      ;;
  esac
  case "${1:-} ${2:-}" in
    "devops invoke")
      shift 2
      v="$(flag_value "" --http-method "$@" | tr '[:lower:]' '[:upper:]')"
      case "$v" in POST|PATCH) ;; *) return 0 ;; esac
      case "$(flag_value "" --resource "$@" | tr '[:upper:]' '[:lower:]')" in
        *status*) deny_status "az devops invoke" ;;
        pullrequests|pullrequest) deny_raw "az devops invoke" ;;
      esac
      ;;
    "rest "*)
      shift
      v="$(flag_value -m --method "$@" | tr '[:lower:]' '[:upper:]')"
      case "$v" in POST|PATCH) ;; *) return 0 ;; esac
      w="$(flag_value -u --uri "$@")$(flag_value "" --url "$@")"
      http_path statuses "$w" && deny_status "az rest"
      http_path pulls "$w" && deny_raw "az rest"
      ;;
  esac
  return 0
}

# ado_lc <text>: lower case.
ado_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ado_target_check <label> <repository> <project> <org>: the Azure DevOps target
# must be the origin repo. Names compare case-insensitively; a GUID is refused.
ado_target_check() {
  local label="$1" repo="$2" proj="$3" org="$4" url o
  [ -n "$repo$proj$org" ] || return 0
  [ -n "$EFF_DIR" ] || return 0
  prq_repo_ctx "$EFF_DIR" || return 0
  url="$(git config --get remote.origin.url 2>/dev/null)"
  prq_ado_parse "$url" || prq_deny "pr-quiz: ${label} targets Azure DevOps, but origin (${url:-not set}) is not an Azure DevOps https remote. pr-quiz checks PRs to the origin repo only. Open this PR in your own terminal."
  case "$repo" in
    ????????-????-????-????-????????????) prq_deny "pr-quiz: ${label} names the repository by GUID (${repo}). pr-quiz compares names. Use the repository name: ${PRQ_ADO_REPO}." ;;
  esac
  if [ -n "$repo" ] && [ "$(ado_lc "$repo")" != "$(ado_lc "$PRQ_ADO_REPO")" ]; then
    prq_deny "pr-quiz: ${label} targets repository ${repo}, but origin is ${PRQ_ADO_REPO}. pr-quiz checks PRs to the origin repo only."
  fi
  if [ -n "$proj" ] && [ "$(ado_lc "$proj")" != "$(ado_lc "$PRQ_ADO_PROJECT")" ]; then
    prq_deny "pr-quiz: ${label} targets project ${proj}, but origin is in project ${PRQ_ADO_PROJECT}. pr-quiz checks PRs to the origin repo only."
  fi
  if [ -n "$org" ]; then
    o="$(ado_lc "$org")"; o="${o%/}"; o="${o#*://}"
    case "$o" in dev.azure.com/*) o="${o#dev.azure.com/}" ;; *.visualstudio.com) o="${o%%.visualstudio.com}" ;; esac
    [ "$o" = "$(ado_lc "$PRQ_ADO_ORG")" ] || prq_deny "pr-quiz: ${label} targets organization ${org}, but origin is in ${PRQ_ADO_ORG}. pr-quiz checks PRs to the origin repo only."
  fi
}

# gh_normalize <words after gh>: sets GH_WORDS. gh accepts flags before the
# subcommand and between "pr" and its action ("gh --repo x pr create");
# they move to the end, so that $1 is the subcommand and $2 the action.
gh_normalize() {
  local -a w=("$@") lead=() out=()
  local n=$# i=0 level
  for level in subcommand action; do
    while [ "$i" -lt "$n" ]; do
      # Like gh's command lookup: a bare --flag or -x takes the next word as its value.
      case "${w[$i]}" in
        --help|-h|--*=*|-?*=*) lead+=("${w[$i]}"); i=$((i + 1)) ;;
        --?*|-?) lead+=("${w[$i]}" "${w[$((i + 1))]:-}"); i=$((i + 2)) ;;
        -*) lead+=("${w[$i]}"); i=$((i + 1)) ;;
        *) break ;;
      esac
    done
    [ "$i" -lt "$n" ] || break
    out+=("${w[$i]}"); i=$((i + 1))
    [ "$level" = subcommand ] && [ "${out[0]}" = pr ] || break
  done
  while [ "$i" -lt "$n" ]; do out+=("${w[$i]}"); i=$((i + 1)); done
  GH_WORDS=(${out[@]+"${out[@]}"} ${lead[@]+"${lead[@]}"})
}

# check_gh <depth> <words after 'gh'>
check_gh() {
  local depth="$1" sub exp rest repo w prev ready_base
  shift
  gh_normalize "$@"
  set -- ${GH_WORDS[@]+"${GH_WORDS[@]}"}
  sub="${1:-}"
  case "$sub" in
    pr)
      case "${2:-}" in
        merge)
          shift 2
          has_word --admin "$@" && deny_policy "gh pr merge --admin"
          ;;
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
      api_posts_status "$@" && deny_status "gh api"
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
  local depth="$1" prog w i saved saved_repo
  shift
  # Skip assignments and transparent prefixes; record GH_REPO.
  while [ $# -gt 0 ]; do
    case "$1" in
      GH_REPO=*) GH_REPO_CUR="${1#GH_REPO=}"; shift ;;
      [A-Za-z_]*=*) shift ;;
      if|then|else|elif|do|while|until|'!'|'{'|'}') shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  prog="${1##*/}"
  case "$prog ${2:-}" in
    "pr create"|"pr new"|"pr ready"|"mr create"|"mr new")
      prq_deny "pr-quiz: cannot resolve the program name in front of ${prog} ${2:-} (a command substitution or a variable). Use a literal program name, for example gh pr create." ;;
  esac
  case "$prog" in
    *'$'*)
      case " $* " in
        *" pr create"*|*" pr new"*|*" pr ready"*|*" mr create"*|*" mr new"*|*pull-request*)
          prq_deny "pr-quiz: cannot resolve the program name ${1}, and the command looks like it creates a pull request. Use a literal program name, for example gh pr create." ;;
      esac
      return 0 ;;
  esac
  if [ "$prog" = popd ]; then EFF_DIR=""; return 0; fi
  if [ "$prog" = cd ] || [ "$prog" = pushd ]; then
    local t="${2:-$HOME}"
    case "$t" in \~) t="$HOME" ;; \~/*) t="${HOME}/${t#\~/}" ;; esac
    case "$t" in *'$'*|-*|+*) EFF_DIR=""; return 0 ;; esac
    case "$t" in /*) ;; *) [ -n "$EFF_DIR" ] || return 0; t="${EFF_DIR}/${t}" ;; esac
    if [ -d "$t" ]; then EFF_DIR="$(cd "$t" && pwd)"; else EFF_DIR=""; fi
    return 0
  fi
  if [ "$prog" = export ]; then
    for w in "$@"; do case "$w" in GH_REPO=*) GH_REPO_CUR="${w#GH_REPO=}" ;; esac; done
    return 0
  fi
  case "$WRAPPERS" in
    *" $prog "*)
      shift
      case "$prog" in
        eval)
          # eval joins its words and runs them in this shell, so a cd persists.
          [ "${1:-}" = "--" ] && shift
          [ "$depth" -lt 4 ] && check_command "$((depth + 1))" "$*"
          return 0 ;;
        watch)
          while [ $# -gt 0 ]; do case "$1" in -n|--interval) shift 2 ;; -*) shift ;; *) break ;; esac; done
          [ "$depth" -lt 4 ] && { saved="$EFF_DIR"; saved_repo="$GH_REPO_CUR"; check_command "$((depth + 1))" "$*"; EFF_DIR="$saved"; GH_REPO_CUR="$saved_repo"; }
          return 0 ;;
        bash|sh|zsh|dash|ksh) shell_c "$depth" "$@"; return 0 ;;
      esac
      i=0
      for w in "$@"; do
        case "$GATED_PROGS$SHELL_PROGS" in *" ${w##*/} "*) shift "$i"; check_words "$((depth + 1))" "$@"; return 0 ;; esac
        case "$w" in GH_REPO=*) GH_REPO_CUR="${w#GH_REPO=}" ;; esac
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
        api) shift; api_posts_pr "$@" && deny_raw "hub api"; api_posts_status "$@" && deny_status "hub api" ;;
      esac
      ;;
    tea)
      case "${1:-} ${2:-}" in
        "pulls create"|"pull create"|"pr create"|"pulls c"|"pull c"|"pr c") shift 2; decide "tea pr create" "$(flag_value "" --head "$@")" "$(flag_value "" --base "$@")" "$(flag_value -r --repo "$@")" "$EFF_DIR" ;;
      esac
      ;;
    az) check_az "$@" ;;
    curl|wget) check_http "$prog" "$@" ;;
  esac
  return 0
}

# check_command <depth> <command string>

# check_command <depth> <command string>. The first pass splits segments at every
# ; & | ` ( ) and newline, quoted or not, so that text after an unbalanced quote
# (an apostrophe in a heredoc) is still read. With PRQ_QUOTED=1 (the second pass)
# only unquoted separators split, so that a quoted title with ";" or "(" cannot
# hide the flags after it.
check_command() {
  local depth="$1" seg cont=$'\\\n' cmd="$2"
  local -a dirs=()
  cmd="${cmd//"$cont"/ }"
  # ${...} becomes one dynamic word. The first pass drops redirections and their
  # targets with sed, also inside quotes; the second drops only unquoted ones.
  cmd="$(printf '%s' "$cmd" | sed -E -e 's/[$][{][^}]*[}]/$DYN/g')"
  if [ "${PRQ_QUOTED:-0}" != 1 ]; then
    cmd="$(printf '%s' "$cmd" | sed -E -e 's/[0-9]*(>>?|<)[&|]?[[:space:]]*[^[:space:]]*/ /g')"
  fi
  case "$2" in *createPullRequest*|*createMergeRequest*|*mergeRequestCreate*) deny_raw "a GraphQL mutation" ;; esac
  while IFS= read -r -d $'\036' seg; do
    case "$seg" in
      *__PRQ_OPEN__*) dirs+=("$EFF_DIR"); continue ;;
      *__PRQ_CLOSE__*) [ ${#dirs[@]} -gt 0 ] && { EFF_DIR="${dirs[$((${#dirs[@]} - 1))]}"; unset "dirs[$((${#dirs[@]} - 1))]"; }; continue ;;
    esac
    split_words "$seg"
    [ ${#WORDS[@]} -gt 0 ] && check_words "$depth" "${WORDS[@]}"
  done < <(
    if [ "${PRQ_QUOTED:-0}" = 1 ]; then quoted_segments "$cmd"
    else printf '%s\n' "$cmd" | sed -e 's/(/;__PRQ_OPEN__;/g' -e 's/)/;__PRQ_CLOSE__;/g' | tr ';&|`\n' '\036\036\036\036\036'
    fi)
}

# shell_c <depth> <words after a shell>: parses the -c command string. It runs in
# a new shell, so a cd inside does not leak. A script file is out of reach.
shell_c() {
  local depth="$1" w found=0 saved saved_repo
  shift
  while [ $# -gt 0 ]; do
    w="$1"; shift
    case "$w" in
      -o|-O|+o|+O) [ $# -gt 0 ] && shift ;;
      --*) ;;
      -*c*|+*c*) found=1 ;;
      -*|+*) ;;
      *)
        [ "$found" = 1 ] && [ "$depth" -lt 4 ] && { saved="$EFF_DIR"; saved_repo="$GH_REPO_CUR"; check_command "$((depth + 1))" "$w"; EFF_DIR="$saved"; GH_REPO_CUR="$saved_repo"; }
        return 0 ;;
    esac
  done
  return 0
}

EFF_DIR="$hook_cwd"
GH_REPO_CUR="${GH_REPO:-}"

case "$tool" in
  Bash)
    cmd="$(prq_field '.tool_input.command')"
    check_command 0 "$cmd"
    # The second pass costs about 1 s per 20 KB on bash 3.2: skipped above 32 KB (README, Limits).
    case "$cmd" in
      *[\"\']*)
        if [ "${#cmd}" -le 32768 ]; then EFF_DIR="$hook_cwd"; GH_REPO_CUR="${GH_REPO:-}"; PRQ_QUOTED=1; check_command 0 "$cmd"; fi ;;
    esac
    ;;
  mcp__*create_commit_status*)
    deny_status "${tool}"
    ;;
  mcp__*repo_pull_request_write)
    case "$(prq_field '.tool_input.action')" in
      create)
        ado_target_check "${tool}" "$(prq_field '.tool_input.repositoryId')" "$(prq_field '.tool_input.project')" ""
        decide "${tool}" "$(prq_field '.tool_input.sourceRefName')" "$(prq_field '.tool_input.targetRefName')" "" "$EFF_DIR"
        ;;
      update)
        [ "$(prq_field '.tool_input.bypassPolicy')" = true ] && deny_policy "${tool} with bypassPolicy"
        ;;
    esac
    ;;
  mcp__*)
    head="$(prq_field '.tool_input.head // .tool_input.source_branch // .tool_input.sourceRefName // .tool_input.source_ref')"
    base="$(prq_field '.tool_input.base // .tool_input.target_branch // .tool_input.targetRefName // .tool_input.target_ref')"
    repo="$(prq_field 'if (.tool_input.owner and .tool_input.repo) then "\(.tool_input.owner)/\(.tool_input.repo)" else empty end')"
    decide "${tool}" "$head" "$base" "$repo" "$EFF_DIR"
    ;;
esac
exit 0
