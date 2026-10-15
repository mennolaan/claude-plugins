#!/usr/bin/env bash
# shellcheck disable=SC2034  # sourced library: the callers read these variables
# pr-quiz shared library: hook I/O, repo context, scope and pass validity.
# Sourced by the hooks and by skills/quiz/scripts/pr-quiz.
# Needs bash 3.2+, git 2.39+ (patch-id --verbatim) and jq.

PRQ_IDK="I don't know, explain this to me"
PRQ_FULL_COUNT=10
PRQ_DELTA_COUNT=3
PRQ_TAG="pr-quiz"
PRQ_SKILL="pr-quiz:quiz"
# A quiz question carries the header "Q3/10" (round 1) or "R2 Q1/3" (retry round).
PRQ_IS_QUIZ='[.tool_input.questions[]?.header // ""] | any(test("^(R[0-9]+ )?Q[0-9]+/[0-9]+$"))'

# Hook output ---------------------------------------------------------------

# prq_deny <reason>: block the tool call; Claude sees the reason. Exits.
prq_deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
  fi
  printf '%s\n' "$1" >&2
  exit 2
}

# prq_context <event> <text>: add context for Claude after a tool call.
prq_context() {
  jq -cn --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
}

prq_require_tools() {
  command -v jq >/dev/null 2>&1 || prq_deny "pr-quiz: jq is not installed. Install jq (macOS: brew install jq. Debian or Ubuntu: apt-get install jq). The PR gate stays closed until jq is available."
  git patch-id --verbatim </dev/null >/dev/null 2>&1 || prq_deny "pr-quiz: git $(git --version 2>/dev/null | cut -d' ' -f3) has no 'patch-id --verbatim'. Install git 2.39 or later. The PR gate stays closed until then."
}

prq_read_input() { PRQ_IN="$(cat)"; }

# prq_field <jq filter>: one raw value from the hook input, empty when null.
prq_field() { printf '%s' "${PRQ_IN}" | jq -r "($1) // empty"; }

# split_words <segment>: sets WORDS to the shell words of one segment, with the
# quotes and backslashes removed. A quoted value with spaces stays one word.
split_words() {
  local s="$1" w="" c q="" i n have=0 tab=$'\t'
  WORDS=()
  case "$s" in
    *[\"\'\\]*) ;;
    *) read -r -a WORDS <<< "$s" || true; return 0 ;;
  esac
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ -n "$q" ]; then
      if [ "$c" = "$q" ]; then q=""
      elif [ "$q" = '"' ] && [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then i=$((i + 1)); w="${w}${s:i:1}"
      else w="${w}${c}"; fi
      continue
    fi
    case "$c" in
      '"'|"'") q="$c"; have=1 ;;
      '\') i=$((i + 1)); w="${w}${s:i:1}"; have=1 ;;
      ' '|"$tab") [ "$have" = 1 ] && WORDS+=("$w"); w=""; have=0 ;;
      *) w="${w}${c}"; have=1 ;;
    esac
  done
  [ "$have" = 1 ] && WORDS+=("$w")
  return 0
}

# quoted_segments <command>: the segments of a command, split at unquoted ; & |
# ` ( ) and newlines, each followed by \036. "(" and ")" become marker segments.
# Unquoted redirections (2>&1, > file, <<'EOF') and their targets are dropped.
quoted_segments() {
  local s="$1" seg="" c q="" i=0 n t rs=$'\036' nl=$'\n' tab=$'\t'
  n=${#s}
  while [ "$i" -lt "$n" ]; do
    c="${s:i:1}"
    if [ -n "$q" ]; then
      seg="${seg}${c}"
      if [ "$c" = "$q" ]; then q=""
      elif [ "$q" = '"' ] && [ "$c" = '\' ]; then i=$((i + 1)); seg="${seg}${s:i:1}"; fi
      i=$((i + 1)); continue
    fi
    case "$c" in
      '"'|"'") q="$c"; seg="${seg}${c}" ;;
      '\') i=$((i + 1)); seg="${seg}${c}${s:i:1}" ;;
      '<'|'>')
        t="$seg"
        while case "$t" in *[0-9]) true ;; *) false ;; esac; do t="${t%?}"; done
        case "$t" in ""|*" "|*"$tab") seg="$t" ;; esac
        while [ "$i" -lt "$n" ]; do case "${s:i:1}" in '<'|'>'|'&'|'|'|'-') i=$((i + 1)) ;; *) break ;; esac; done
        while [ "$i" -lt "$n" ]; do case "${s:i:1}" in ' '|"$tab") i=$((i + 1)) ;; *) break ;; esac; done
        while [ "$i" -lt "$n" ]; do
          c="${s:i:1}"
          if [ -n "$q" ]; then [ "$c" = "$q" ] && q=""; i=$((i + 1)); continue; fi
          case "$c" in
            '"'|"'") q="$c" ;;
            ' '|"$tab"|';'|'&'|'|'|'`'|'('|')'|'<'|'>'|"$nl") break ;;
          esac
          i=$((i + 1))
        done
        seg="${seg} "; continue ;;
      ';'|'&'|'|'|'`'|"$nl") printf '%s%s' "$seg" "$rs"; seg="" ;;
      '(') printf '%s%s__PRQ_OPEN__%s' "$seg" "$rs" "$rs"; seg="" ;;
      ')') printf '%s%s__PRQ_CLOSE__%s' "$seg" "$rs" "$rs"; seg="" ;;
      *) seg="${seg}${c}" ;;
    esac
    i=$((i + 1))
  done
  printf '%s%s' "$seg" "$rs"
}

# Repo context --------------------------------------------------------------

# prq_norm_repo <url | OWNER/REPO | HOST/OWNER/REPO>: prints lowercase
# host/owner/repo, or owner/repo when the input names no host.
prq_norm_repo() {
  local u="$1" host
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    *://*) u="${u#*://}"; u="${u#*@}"; host="${u%%/*}"; u="${host%%:*}/${u#*/}" ;;
    *@*:*) u="${u#*@}"; u="${u%%:*}/${u#*:}" ;;
  esac
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

# prq_same_repo <a> <b>: normalized repos match. The host counts when both name one.
prq_same_repo() {
  local a="$1" b="$2"
  case "${a%%/*}" in *.*) case "${b%%/*}" in *.*) [ "$a" = "$b" ]; return ;; esac ;; esac
  case "${a%%/*}" in *.*) a="${a#*/}" ;; esac
  case "${b%%/*}" in *.*) b="${b#*/}" ;; esac
  [ "$a" = "$b" ]
}

# prq_urldecode <text>: decodes %XX escapes.
prq_urldecode() {
  local s="$1" out="" pre hex
  while :; do
    case "$s" in *%[0-9A-Fa-f][0-9A-Fa-f]*) ;; *) break ;; esac
    pre="${s%%\%[0-9A-Fa-f][0-9A-Fa-f]*}"
    hex="${s:${#pre}+1:2}"
    s="${s:${#pre}+3}"
    # shellcheck disable=SC2059  # the format is the octal escape
    out="${out}${pre}$(printf "\\$(printf '%03o' "0x${hex}")")"
  done
  printf '%s' "${out}${s}"
}

# prq_ado_parse <remote url>: for an Azure DevOps remote, sets PRQ_ADO_BASE (REST
# base up to the project), PRQ_ADO_ORG, PRQ_ADO_PROJECT and PRQ_ADO_REPO (decoded)
# and PRQ_ADO_REPO_ENC (for URL paths). Returns 1 for any other remote. Sets
# PRQ_ADO_ERR for an Azure DevOps remote that has no REST mapping.
prq_ado_parse() {
  local u="$1" scheme host path org proj repo
  PRQ_ADO_ERR=""
  u="${u%/}"; u="${u%.git}"
  case "$u" in
    git@ssh.dev.azure.com:v3/*|*@vs-ssh.visualstudio.com:v3/*|ssh://*ssh.dev.azure.com*/v3/*|ssh://*vs-ssh.visualstudio.com*/v3/*)
      path="${u#*v3/}"
      org="${path%%/*}"; path="${path#*/}"; proj="${path%%/*}"; repo="${path#*/}"
      PRQ_ADO_BASE="https://dev.azure.com/${org}/${proj}"
      ;;
    https://*/_git/*|http://*/_git/*)
      scheme="${u%%://*}"
      host="${u#*://}"; host="${host#*@}"; path="${host#*/}"; host="${host%%/*}"
      repo="${path##*/_git/}"; path="${path%%/_git/*}"
      case "$host" in
        dev.azure.com) org="${path%%/*}"; proj="${path#*/}" ;;
        *.visualstudio.com) org="${host%%.*}"; proj="${path##*/}" ;;
        *) org="${host}/${path%/*}"; proj="${path##*/}" ;;
      esac
      PRQ_ADO_BASE="${scheme}://${host}/${path}"
      ;;
    *)
      case "$u" in
        *dev.azure.com*|*visualstudio.com*|*/_git/*) PRQ_ADO_ERR="origin ${1} is an Azure DevOps remote that pr-quiz cannot map to the REST API. Use an https remote." ;;
      esac
      return 1
      ;;
  esac
  case "$repo" in */*|"") PRQ_ADO_ERR="cannot read the repo name from origin ${1}."; return 1 ;; esac
  PRQ_ADO_BASE="${PRQ_ADO_BASE// /%20}"
  PRQ_ADO_REPO_ENC="${repo// /%20}"
  PRQ_ADO_ORG="$(prq_urldecode "$org")"
  PRQ_ADO_PROJECT="$(prq_urldecode "$proj")"
  PRQ_ADO_REPO="$(prq_urldecode "$repo")"
}

# prq_repo_ctx <dir>: cd into the repo and set PRQ_TOP, PRQ_GITDIR, PRQ_BRANCH,
# PRQ_HEAD, PRQ_ORIGIN and PRQ_STATE. Returns 1 outside a work tree.
prq_repo_ctx() {
  cd "$1" 2>/dev/null || return 1
  PRQ_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$PRQ_TOP" ] || return 1
  cd "$PRQ_TOP" || return 1
  PRQ_GITDIR="$(git rev-parse --absolute-git-dir)"
  PRQ_BRANCH="$(git symbolic-ref -q --short HEAD)" || PRQ_BRANCH=""
  PRQ_HEAD="$(git rev-parse -q --verify HEAD)" || PRQ_HEAD=""
  PRQ_ORIGIN="$(prq_norm_repo "$(git remote get-url origin 2>/dev/null)")"
  PRQ_STATE="${PRQ_GITDIR}/pr-quiz/$(printf '%s' "$PRQ_BRANCH" | git hash-object --stdin | cut -c1-16)"
}

# prq_default_base: the origin default branch name, else main or master.
prq_default_base() {
  local b c
  b="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  b="${b#origin/}"
  if [ -z "$b" ]; then
    for c in main master; do
      if git show-ref -q --verify "refs/remotes/origin/$c" || git show-ref -q --verify "refs/heads/$c"; then b="$c"; break; fi
    done
  fi
  printf '%s' "$b"
}

# prq_pr_base: the base gh uses when none is given: the branch's gh-merge-base
# config, else the origin default branch.
prq_pr_base() {
  local b
  b="$(git config --get "branch.${PRQ_BRANCH}.gh-merge-base" 2>/dev/null)"
  [ -n "$b" ] || b="$(prq_default_base)"
  printf '%s' "$b"
}

# prq_base_ref <name>: the ref to compare against: origin/<name>, else <name>.
prq_base_ref() {
  if git show-ref -q --verify "refs/remotes/origin/$1"; then printf 'origin/%s' "$1"
  elif git show-ref -q --verify "refs/heads/$1"; then printf '%s' "$1"
  else return 1
  fi
}

# prq_patch_id <base ref> <rev>: whitespace-sensitive patch-id of merge-base..rev.
prq_patch_id() {
  local mb id
  mb="$(git merge-base "$1" "$2")" || return 1
  id="$(git diff --no-color --no-ext-diff --no-textconv "$mb" "$2" | git patch-id --verbatim | cut -d' ' -f1)"
  printf '%s' "${id:-empty}"
}

# Scope ---------------------------------------------------------------------

# prq_scope_files <base ref> <mode> <from>: files a question may cite, one per line.
# Full: merge-base..HEAD. Delta: files changed since <from> that are also branch
# files (this drops base changes that a merge brought in); when none are, as after
# a revert, every file changed since <from>.
prq_scope_files() {
  local mb files
  mb="$(git merge-base "$1" HEAD)" || return 1
  if [ "$2" = delta ]; then
    files="$(comm -12 <(git diff --name-only "$3" HEAD | sort -u) <(git diff --name-only "$mb" HEAD | sort -u))"
    [ -n "$files" ] || files="$(git diff --name-only "$3" HEAD | sort -u)"
    printf '%s\n' "$files"
  else
    git diff --name-only "$mb" HEAD | sort -u
  fi
}

# Pass validity -------------------------------------------------------------

# prq_need <base name>: sets PRQ_NEED (ok | full | delta), PRQ_COUNT, PRQ_FROM, PRQ_WHY.
prq_need() {
  local base="$1" pass="${PRQ_STATE}/pass.json" p_branch p_repo p_base p_head p_pid cur base_ref
  PRQ_NEED="full"; PRQ_COUNT=$PRQ_FULL_COUNT; PRQ_FROM=""
  if [ ! -f "$pass" ]; then PRQ_WHY="No quiz pass exists for branch ${PRQ_BRANCH}."; return 0; fi
  p_branch="$(jq -r '.branch // ""' "$pass")"; p_repo="$(jq -r '.repo // ""' "$pass")"
  p_base="$(jq -r '.base // ""' "$pass")"; p_head="$(jq -r '.head // ""' "$pass")"; p_pid="$(jq -r '.patch_id // ""' "$pass")"
  if [ "$p_branch" != "$PRQ_BRANCH" ] || [ "$p_repo" != "$PRQ_ORIGIN" ]; then
    PRQ_WHY="The quiz pass is for ${p_repo:-no remote} branch ${p_branch}, not ${PRQ_ORIGIN:-no remote} branch ${PRQ_BRANCH}."; return 0
  fi
  if [ "$p_base" != "$base" ]; then PRQ_WHY="The quiz pass is for base ${p_base}. This PR targets base ${base}."; return 0; fi
  if [ "$p_head" = "$PRQ_HEAD" ]; then PRQ_NEED="ok"; return 0; fi
  base_ref="$(prq_base_ref "$base")" || { PRQ_WHY="Base ${base} is not a known branch."; return 0; }
  cur="$(prq_patch_id "$base_ref" HEAD)" || cur=""
  if [ -n "$cur" ] && [ "$cur" = "$p_pid" ]; then PRQ_NEED="ok"; return 0; fi
  if git merge-base --is-ancestor "$p_head" HEAD 2>/dev/null; then
    PRQ_NEED="delta"; PRQ_COUNT=$PRQ_DELTA_COUNT; PRQ_FROM="$p_head"
    PRQ_WHY="The branch has new changes since the quiz pass at ${p_head:0:7}."
    return 0
  fi
  # A rebase rewrites the passed commit. Find its copy by patch-id (50 commits max).
  local c mb
  mb="$(git merge-base "$base_ref" HEAD)" || mb=""
  if [ -n "$mb" ]; then
    for c in $(git rev-list --first-parent -n 50 "${mb}..HEAD"); do
      if [ "$(prq_patch_id "$base_ref" "$c")" = "$p_pid" ]; then
        PRQ_NEED="delta"; PRQ_COUNT=$PRQ_DELTA_COUNT; PRQ_FROM="$c"
        PRQ_WHY="The branch has new changes since the quiz pass (rebased to ${c:0:7})."
        return 0
      fi
    done
  fi
  PRQ_WHY="The branch history changed since the quiz pass at ${p_head:0:7}."
}

# prq_write_json <file>: atomic write of stdin.
prq_write_json() {
  local tmp
  mkdir -p "$(dirname "$1")"
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  cat > "$tmp" && mv -f "$tmp" "$1"
}
