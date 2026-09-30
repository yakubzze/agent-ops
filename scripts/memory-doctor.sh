#!/usr/bin/env bash
#
# agent-ops · memory doctor
#
# Audits Claude Code's legacy/default per-project memory layout, and reads the
# .claude settings of --project-dir to report a declared autoMemoryDirectory that
# cannot work as written. It still does not reproduce settings precedence, so use
# /memory (or /context) in Claude Code to confirm the path active for a session.
#
# A link whose target exists and is a directory, but whose content cannot be
# fully read - a permission error, or a cloud placeholder that failed to
# download - is UNREADABLE: not missing, and never to be recreated.
#
# Exit codes (without --hook):
#   0  every discovered link was verified under --stable-root
#   1  content needs attention, a link is unverified or unreadable, or a path
#      is invalid
#   2  usage/configuration error
#
# --hook is for a session-start hook. It implies --quiet, prints nothing when
# the result is healthy, and otherwise prints a compact report whose last line
# names the exit code a manual run returns. It always exits 0: Claude Code adds
# a SessionStart hook's plain-text stdout to the agent's context only on exit 0
# (Claude Code 2.1.283 hooks reference, read 2026-09-30), so a non-zero code
# would drop the very diagnosis the hook exists to deliver.
#
# Usage:
#   ./memory-doctor.sh [--projects-dir DIR] [--stable-root DIR] [--quiet]
#                      [--project-dir DIR]... [--skip-settings-check] [--hook]

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
STABLE_ROOT=""
QUIET=0
HOOK=0
SKIP_SETTINGS=0
PROJECT_DIRS=()
# The arguments that reproduce this audit without --hook/--quiet.
REPORT_ARGS=()
# Hook mode holds every line back and decides at exit: see hook_finish.
HOOK_LINES=()
HOOK_SUMMARY=()
HOOK_LEGEND=()
HOOK_SECTION=""
ENTRY_SECTION=""

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || SCRIPT_DIR=""
if [ -n "$SCRIPT_DIR" ]; then
  SCRIPT_PATH=$SCRIPT_DIR/${0##*/}
else
  SCRIPT_PATH=$0
fi

usage() {
  cat <<'EOF'
Usage: memory-doctor.sh [options]

Audit Claude Code's legacy/default <projects-dir>/<slug>/memory layout.

Options:
  --projects-dir DIR      Legacy/default projects directory to scan
  --stable-root DIR       Verify that link targets are contained in this directory
  --project-dir DIR       Project whose .claude settings to inspect (repeatable;
                          defaults to the current directory)
  --skip-settings-check   Audit the on-disk layout only
  --quiet                 Print only entries that need attention
  --hook                  For a session-start hook: print nothing when healthy,
                          a compact report otherwise, and always exit 0
  -h, --help              Show this help

This command reports a declared autoMemoryDirectory that cannot work, but it
does not resolve settings precedence. Use /memory (or /context) in Claude Code
to confirm the memory path active for a session.
EOF
}

# Errors go to stderr, except in hook mode, where they join the report: stderr
# of a hook that exits 0 never reaches the agent.
report_error() {
  if [ "$HOOK" -eq 1 ]; then
    HOOK_LINES+=("$1")
  else
    printf '%s\n' "$1" >&2
  fi
}

usage_error() {
  report_error "error: $1"
  report_error 'Try --help for usage.'
  exit 2
}

# Lines that need attention go through here. Hook mode keeps them for the
# compact report, exactly as --quiet prints them; a section header travels with
# the first line under it.
entry() {
  local line
  # shellcheck disable=SC2059  # every caller passes a literal format string
  printf -v line "$@"
  if [ "$HOOK" -eq 0 ]; then
    printf '%s\n' "$line"
    return 0
  fi
  if [ -n "$ENTRY_SECTION" ] && [ "$ENTRY_SECTION" != "$HOOK_SECTION" ]; then
    HOOK_LINES+=("$ENTRY_SECTION")
    HOOK_SECTION=$ENTRY_SECTION
  fi
  HOOK_LINES+=("$line")
}

# Invoked by hook_finish, which runs through the EXIT trap.
# shellcheck disable=SC2329,SC2317
shell_quote() {
  case $1 in
    '' | *[!A-Za-z0-9_./:=@%+,-]*)
      printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# Invoked by hook_finish, which runs through the EXIT trap.
# shellcheck disable=SC2329,SC2317
full_report_command() {
  local command arg
  command="bash $(shell_quote "$SCRIPT_PATH")"
  for arg in "${REPORT_ARGS[@]+"${REPORT_ARGS[@]}"}"; do
    command="$command $(shell_quote "$arg")"
  done
  printf '%s\n' "$command"
}

# The hook report lands in the context of every session, and Claude Code 2.1.283
# keeps a hook's plain stdout whole only up to 10,000 characters (hooks
# reference, read 2026-09-30); past that, Claude gets a 2,000-character preview.
# This many problem lines keeps even long paths well inside the limit; the full
# report lists the rest.
HOOK_MAX_LINES=12

# The only way out in hook mode: every exit, including an argument error or an
# unexpected failure under `set -e`, arrives here through the EXIT trap. Claude
# Code adds a SessionStart hook's plain-text stdout to the agent's context only
# on exit 0; on any other code the report is dropped and at most a one-line hook
# error remains. Measured on 2026-09-30: the doctor exited 1 at every session
# start, correctly, and dangling memory links still went unnoticed for weeks.
# shellcheck disable=SC2329,SC2317
hook_finish() {
  local status=$1 line shown=0 hidden=0
  trap - EXIT
  exec 1>&3 3>&-
  if [ "$status" -ne 0 ]; then
    if [ "$status" -eq 2 ]; then
      printf 'agent-ops memory doctor: agent memory needs attention; the audit could not run.\n'
    else
      printf 'agent-ops memory doctor: agent memory needs attention.\n'
    fi
    for line in "${HOOK_LINES[@]+"${HOOK_LINES[@]}"}"; do
      if [ "$shown" -lt "$HOOK_MAX_LINES" ]; then
        printf '%s\n' "$line"
        shown=$((shown + 1))
      else
        hidden=$((hidden + 1))
      fi
    done
    if [ "$hidden" -gt 0 ]; then
      printf '... and %s more line(s); the full report lists every entry.\n' "$hidden"
    fi
    # No summary means the audit never reached its end: a failure under `set -e`
    # whose message went to stderr, which Claude Code drops on exit 0.
    if [ "$status" -ne 2 ] && [ "${#HOOK_SUMMARY[@]}" -eq 0 ]; then
      printf 'error: the audit stopped early (exit %s); the full report shows why.\n' "$status"
    fi
    for line in "${HOOK_SUMMARY[@]+"${HOOK_SUMMARY[@]}"}" \
      "${HOOK_LEGEND[@]+"${HOOK_LEGEND[@]}"}"; do
      printf '%s\n' "$line"
    done
    printf 'A manual run exits %s. Full report: %s\n' "$status" "$(full_report_command)"
  fi
  exit 0
}

# Look for --hook before parsing, so an argument error in front of it is still
# reported the hook's way instead of vanishing with exit 2.
for arg; do
  case $arg in
    --) break ;;
    --hook) HOOK=1 ;;
  esac
done
if [ "$HOOK" -eq 1 ]; then
  QUIET=1
  exec 3>&1
  trap 'hook_finish "$?"' EXIT
fi

need_value() {
  # shellcheck disable=SC2015  # B is a pure test; C only runs when A fails.
  [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 requires a non-empty value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --projects-dir)
      need_value "$@"
      PROJECTS_DIR=$2
      REPORT_ARGS+=("$1" "$2")
      shift 2
      ;;
    --stable-root)
      need_value "$@"
      STABLE_ROOT=$2
      REPORT_ARGS+=("$1" "$2")
      shift 2
      ;;
    --project-dir)
      need_value "$@"
      PROJECT_DIRS+=("$2")
      REPORT_ARGS+=("$1" "$2")
      shift 2
      ;;
    --skip-settings-check)
      SKIP_SETTINGS=1
      REPORT_ARGS+=("$1")
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --hook)
      # Already applied by the scan above.
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      [ "$#" -eq 0 ] || usage_error "unexpected positional argument: $1"
      ;;
    *)
      usage_error "unknown argument: $1"
      ;;
  esac
done

# Default AFTER parsing, and never leave the array empty: `"${arr[@]}"` on an
# empty array is an unbound-variable error under `set -u` in Bash 3.2, which is
# still what macOS ships as /bin/bash.
if [ "${#PROJECT_DIRS[@]}" -eq 0 ]; then
  PROJECT_DIRS=(".")
fi

# From here on, hook mode prints only what hook_finish assembles.
if [ "$HOOK" -eq 1 ]; then
  exec >/dev/null
fi

canonical_dir() {
  [ -d "$1" ] || return 1
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# Directory names used by the consumer sync clients. A settings file living under
# one of these is copied to every other machine verbatim, so an absolute path
# written into it can only ever be correct on the machine that wrote it.
# Split on / with parameter expansion only. Word-splitting the path on IFS would
# also glob it, so a directory literally named * could match anything.
path_looks_synced() {
  local segment rest=$1
  while [ -n "$rest" ]; do
    segment=${rest%%/*}
    if [ "$segment" = "$rest" ]; then
      rest=""
    else
      rest=${rest#*/}
    fi
    [ -n "$segment" ] || continue
    case $segment in
      iCloud~*|'Mobile Documents'|'com~apple~CloudDocs'|iCloudDrive|'iCloud Drive') return 0 ;;
      Dropbox|OneDrive|'Google Drive'|GoogleDrive|Nextcloud|ownCloud|'Sync.com'|pCloudDrive|Syncthing) return 0 ;;
    esac
  done
  return 1
}

expand_home() {
  # shellcheck disable=SC2088  # The tilde is DATA here - a literal prefix inside
  # a settings value we are inspecting, matched and stripped on purpose. Letting
  # the shell expand it would defeat the check.
  case $1 in
    '~/'*) printf '%s\n' "${HOME}/${1#'~/'}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# Pull one top-level string field out of a settings file. jq when it is present,
# otherwise a POSIX-BRE extractor that handles a flat "key": "value" pair with
# JSON escapes.
#
# Exit status is the contract, because "the key is absent" and "this file is
# broken" must not collapse into the same silence:
#   0  value printed
#   1  the key is not declared
#   2  the file or the value cannot be parsed
json_string_field() {
  local file=$1 key=$2 raw
  if [ "${AGENT_OPS_FORCE_JSON_FALLBACK:-0}" != 1 ] && command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null 2>&1 || return 2
    jq -e --arg k "$key" 'has($k)' "$file" >/dev/null 2>&1 || return 1
    raw=$(jq -r --arg k "$key" 'if (.[$k] | type) == "string" then .[$k] else "" end' "$file" 2>/dev/null) || return 2
    [ -n "$raw" ] || return 2
    printf '%s\n' "$raw"
    return 0
  fi
  # Without jq the file cannot be validated, only searched. Naming the key and
  # then failing to yield a value is still reported rather than swallowed.
  grep -q "\"$key\"" "$file" 2>/dev/null || return 1
  raw=$(
    tr -d '\n' <"$file" 2>/dev/null |
      sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"\\]*\(\\.[^"\\]*\)*\)".*/\1/p'
  ) || return 2
  [ -n "$raw" ] || return 2
  printf '%s\n' "$raw" | sed -e 's/\\\\/\\/g' -e 's/\\"/"/g' -e 's|\\/|/|g'
}

PROJECTS_CANON=$(canonical_dir "$PROJECTS_DIR") || {
  report_error "error: no readable legacy/default projects directory at: $PROJECTS_DIR"
  report_error 'Point at the right one with --projects-dir.'
  exit 2
}
PROJECTS_DIR=$PROJECTS_CANON
command ls -A -- "$PROJECTS_DIR" >/dev/null 2>&1 || {
  report_error "error: legacy/default projects directory cannot be enumerated: $PROJECTS_DIR"
  exit 2
}

if [ -n "$STABLE_ROOT" ]; then
  STABLE_CANON=$(canonical_dir "$STABLE_ROOT") || {
    report_error "error: --stable-root is not a readable directory: $STABLE_ROOT"
    exit 2
  }
  STABLE_ROOT=$STABLE_CANON
  command ls -A -- "$STABLE_ROOT" >/dev/null 2>&1 || {
    report_error "error: --stable-root cannot be enumerated: $STABLE_ROOT"
    exit 2
  }
fi

directory_contains_path() {
  local wanted=$1 parent entry
  parent=${wanted%/*}
  command ls -A -- "$parent" >/dev/null 2>&1 || return 2
  (
    shopt -s dotglob nullglob
    for entry in "$parent"/*; do
      [ "$entry" = "$wanted" ] && exit 0
    done
    exit 1
  )
}

path_within() {
  local candidate=$1 root=$2
  if [ "$root" = / ]; then
    return 0
  fi
  [ "$candidate" = "$root" ] || case "$candidate" in
    "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Traverse the entire tree and actually open every regular file. Any entry is
# content: hidden files, arbitrary extensions, symlinks and empty directories
# all matter. A partial find or unreadable file must never produce an OK.
# On failure INSPECT_ERROR says what could not be read.
INSPECT_COUNT=0
INSPECT_ERROR=""
inspect_directory() {
  local root=$1 output
  INSPECT_ERROR=""
  if output=$(
    find -H "$root" -mindepth 1 -print0 2>/dev/null |
      {
        count=0
        while IFS= read -r -d '' item; do
          count=$((count + 1))
          if [ -L "$item" ]; then
            readlink "$item" >/dev/null 2>&1 || {
              printf 'cannot read link: %s\n' "$item"
              exit 1
            }
          elif [ -f "$item" ]; then
            error=$(command cat "$item" 2>&1 >/dev/null) || {
              printf '%s\n' "${error:-cannot read: $item}"
              exit 1
            }
          fi
        done
        printf '%s\n' "$count"
      }
  ); then
    INSPECT_COUNT=$output
    return 0
  fi
  # A listing that stopped early still reaches the counter, which then prints a
  # bare number: that is a failed walk, not one failed file.
  case $output in
    '' | *[!0-9]*) INSPECT_ERROR=${output:-cannot inspect every entry} ;;
    *) INSPECT_ERROR='cannot list every entry' ;;
  esac
  return 1
}

at_risk=0
orphans=0
unreadable=0
invalid=0
unverified=0
verified=0
empty=0
total=0

printf 'agent-ops · memory doctor\n'
printf 'legacy/default-layout scan: %s\n' "$PROJECTS_DIR"
if [ -n "$STABLE_ROOT" ]; then
  printf 'verified stable root       : %s\n' "$STABLE_ROOT"
else
  printf 'stable-root verification  : not requested\n'
fi
printf 'active path source         : check /memory (or /context) in Claude Code\n\n'

shopt -s dotglob nullglob
project_dirs=("$PROJECTS_DIR"/*/)
shopt -u dotglob nullglob

# An empty projects directory leaves an empty array, and expanding one under
# `set -u` is an unbound-variable error in Bash 3.2 — still what macOS ships.
# `${arr[@]+...}` is the portable guard; a fresh install has nothing to scan yet
# and must report that, not abort.
for project_dir in "${project_dirs[@]+"${project_dirs[@]}"}"; do
  [ -d "$project_dir" ] || continue
  slug=$(basename "$project_dir")
  mem="${project_dir%/}/memory"
  total=$((total + 1))
  if ! command ls -A -- "$project_dir" >/dev/null 2>&1; then
    invalid=$((invalid + 1))
    entry '  %-11s %-40s project directory cannot be enumerated' "INVALID" "$slug"
    continue
  fi
  mem_listed=0
  if directory_contains_path "$mem"; then
    mem_listed=1
  else
    status=$?
    if [ "$status" -eq 2 ]; then
      invalid=$((invalid + 1))
      entry '  %-11s %-40s memory path cannot be inspected' "INVALID" "$slug"
      continue
    fi
  fi
  if [ "$mem_listed" -eq 1 ] && [ ! -e "$mem" ] && [ ! -L "$mem" ]; then
    invalid=$((invalid + 1))
    entry '  %-11s %-40s memory path is listed but cannot be inspected' "INVALID" "$slug"
    continue
  fi

  if [ -L "$mem" ]; then
    target=$(readlink "$mem" 2>/dev/null || printf '<unreadable>')
    if [ ! -e "$mem" ]; then
      orphans=$((orphans + 1))
      entry '  %-11s %-40s → %s (target missing)' "ORPHAN" "$slug" "$target"
      continue
    fi
    if [ ! -d "$mem" ]; then
      invalid=$((invalid + 1))
      entry '  %-11s %-40s → %s (target is not a directory)' "INVALID" "$slug" "$target"
      continue
    fi
    # From here on the target is there and is a directory. A read failure inside
    # it - one iCloud file that failed to hydrate, measured 2026-09-30 - is not a
    # missing target, and must not be reported in a way that invites recreating it.
    resolved=$(canonical_dir "$mem") || resolved=""
    if [ -z "$resolved" ]; then
      unreadable=$((unreadable + 1))
      entry '  %-11s %-40s → %s (%s)' "UNREADABLE" "$slug" "$target" "cannot enter the target directory"
      continue
    fi
    if ! inspect_directory "$mem"; then
      unreadable=$((unreadable + 1))
      entry '  %-11s %-40s → %s (%s)' "UNREADABLE" "$slug" "$target" "$INSPECT_ERROR"
      continue
    fi
    count=$INSPECT_COUNT
    if path_within "$resolved" "$PROJECTS_DIR"; then
      at_risk=$((at_risk + 1))
      entry '  %-11s %-40s → %s (%s item(s); inside legacy tree)' "AT RISK" "$slug" "$target" "$count"
    elif [ -z "$STABLE_ROOT" ]; then
      unverified=$((unverified + 1))
      entry '  %-11s %-40s → %s (%s item(s); stability not verified)' "LINKED" "$slug" "$target" "$count"
    elif path_within "$resolved" "$STABLE_ROOT"; then
      verified=$((verified + 1))
      [ "$QUIET" -eq 1 ] || printf '  %-11s %-40s → %s (%s item(s))\n' "OK" "$slug" "$target" "$count"
    else
      unverified=$((unverified + 1))
      entry '  %-11s %-40s → %s (%s item(s); outside stable root)' "UNVERIFIED" "$slug" "$target" "$count"
    fi
  elif [ -e "$mem" ]; then
    if [ ! -d "$mem" ]; then
      invalid=$((invalid + 1))
      entry '  %-11s %-40s legacy/default path is not a directory' "INVALID" "$slug"
    elif ! inspect_directory "$mem"; then
      invalid=$((invalid + 1))
      entry '  %-11s %-40s legacy/default directory cannot be inspected' "INVALID" "$slug"
    else
      count=$INSPECT_COUNT
      if [ "$count" -gt 0 ]; then
        at_risk=$((at_risk + 1))
        entry '  %-11s %-40s legacy/default directory, %s item(s)' "AT RISK" "$slug" "$count"
      else
        empty=$((empty + 1))
        [ "$QUIET" -eq 1 ] || printf '  %-11s %-40s empty legacy/default directory\n' "empty" "$slug"
      fi
    fi
  else
    empty=$((empty + 1))
    [ "$QUIET" -eq 1 ] || printf '  %-11s %-40s no legacy/default memory path\n' "-" "$slug"
  fi
done

settings_issues=0
ENTRY_SECTION='declared memory directory (.claude settings):'
if [ "$SKIP_SETTINGS" -eq 0 ]; then
  settings_header=0
  for project_candidate in "${PROJECT_DIRS[@]}"; do
    [ -n "$project_candidate" ] || continue
    project_canon=$(canonical_dir "$project_candidate") || project_canon=""
    if [ -z "$project_canon" ]; then
      settings_issues=$((settings_issues + 1))
      [ "$settings_header" -eq 1 ] || { printf '\ndeclared memory directory (.claude settings):\n'; settings_header=1; }
      entry '  %-11s %-40s project path is not a readable directory' "INVALID" "$project_candidate"
      continue
    fi

    found_declaration=0
    for settings_name in settings.json settings.local.json; do
      settings_file="$project_canon/.claude/$settings_name"
      [ -f "$settings_file" ] || continue
      command cat "$settings_file" >/dev/null 2>&1 || {
        found_declaration=1
        settings_issues=$((settings_issues + 1))
        [ "$settings_header" -eq 1 ] || { printf '\ndeclared memory directory (.claude settings):\n'; settings_header=1; }
        entry '  %-11s %-40s settings file cannot be read' "INVALID" "$settings_name"
        continue
      }
      declared=$(json_string_field "$settings_file" autoMemoryDirectory) && json_status=0 || json_status=$?
      if [ "$json_status" -eq 1 ]; then
        continue
      fi
      found_declaration=1
      if [ "$json_status" -ne 0 ]; then
        settings_issues=$((settings_issues + 1))
        [ "$settings_header" -eq 1 ] || { printf '\ndeclared memory directory (.claude settings):\n'; settings_header=1; }
        entry '  %-11s %-40s autoMemoryDirectory cannot be read as a JSON string' "INVALID" "$settings_name"
        continue
      fi
      [ "$settings_header" -eq 1 ] || { printf '\ndeclared memory directory (.claude settings):\n'; settings_header=1; }

      # A relative value is not a different location - the agent discards it and
      # silently falls back to the path-derived layout this tool is auditing.
      # shellcheck disable=SC2088  # literal prefix of a value being classified
      case $declared in
        /*|'~/'*) ;;
        *)
          settings_issues=$((settings_issues + 1))
          entry '  %-11s %-40s relative value "%s" is ignored; memory falls back to the derived layout' \
            "AT RISK" "$settings_name" "$declared"
          continue
          ;;
      esac

      # The trap this check exists for: the settings file syncs, the path does not.
      # shellcheck disable=SC2088  # literal prefix of a value being classified
      case $declared in
        '~/'*) ;;
        *)
          if path_looks_synced "$settings_file"; then
            settings_issues=$((settings_issues + 1))
            entry '  %-11s %-40s absolute path in a SYNCED settings file; it cannot be right on two machines' \
              "AT RISK" "$settings_name"
            continue
          fi
          ;;
      esac

      declared_expanded=$(expand_home "$declared")
      declared_canon=$(canonical_dir "$declared_expanded") || declared_canon=""
      if [ -z "$declared_canon" ]; then
        settings_issues=$((settings_issues + 1))
        entry '  %-11s %-40s → %s (declared directory does not exist)' \
          "AT RISK" "$settings_name" "$declared_expanded"
        continue
      fi
      if [ -n "$STABLE_ROOT" ] && ! path_within "$declared_canon" "$STABLE_ROOT"; then
        settings_issues=$((settings_issues + 1))
        entry '  %-11s %-40s → %s (outside stable root)' "AT RISK" "$settings_name" "$declared_canon"
        continue
      fi
      [ "$QUIET" -eq 1 ] || printf '  %-11s %-40s → %s\n' "OK" "$settings_name" "$declared_canon"
    done

    if [ "$found_declaration" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
      [ "$settings_header" -eq 1 ] || { printf '\ndeclared memory directory (.claude settings):\n'; settings_header=1; }
      printf '  %-11s %-40s no autoMemoryDirectory declared\n' "-" "$project_canon"
    fi
  done
fi

printf -v summary '%s project(s): %s verified, %s linked/unverified, %s at risk, %s orphaned, %s unreadable, %s invalid.' \
  "$total" "$verified" "$unverified" "$at_risk" "$orphans" "$unreadable" "$invalid"
HOOK_SUMMARY+=("$summary")
printf '\n%s\n' "$summary"
if [ "$settings_issues" -gt 0 ]; then
  HOOK_SUMMARY+=("$settings_issues declared memory directory issue(s).")
  printf '%s declared memory directory issue(s).\n' "$settings_issues"
fi

# The paragraphs are for a person reading a full report. Hook mode gets one line
# per category instead, because it lands in the context of every session.
if [ "$at_risk" -gt 0 ]; then
  cat <<'EOF'

AT RISK — content was found in the path-derived legacy/default layout, or a
link resolves back inside that layout. Moving or renaming a checkout can make
path-derived memory appear to vanish. Confirm the active path with /memory (or
/context) before migrating anything.
EOF
  HOOK_LEGEND+=('AT RISK: memory sits in the path-derived layout or links back into it, so moving the checkout can strand it; /memory shows which path is active.')
fi

if [ "$unverified" -gt 0 ]; then
  if [ -z "$STABLE_ROOT" ]; then
    cat <<'EOF'

LINKED — the target is an inspectable directory, but this scan cannot call it
stable without a trust boundary. Re-run with --stable-root DIR to verify that
the canonical target is contained there.
EOF
    HOOK_LEGEND+=('LINKED: the target is an inspectable directory, but no stable root was supplied, so its stability is not verified; a run with --stable-root verifies it.')
  else
    cat <<'EOF'

UNVERIFIED — the canonical target is outside --stable-root. Check the target
and choose the correct stable root before treating this link as safe.
EOF
    HOOK_LEGEND+=('UNVERIFIED: the canonical target is outside --stable-root, so the link is not known to be safe.')
  fi
fi

if [ "$orphans" -gt 0 ]; then
  cat <<'EOF'

ORPHAN — a link target is missing. Reconnect or mount the store before letting
an agent write memory at that project path.
EOF
  HOOK_LEGEND+=('ORPHAN: the link target is missing, so memory cannot be read or written through the link until the store is reconnected or mounted.')
fi

if [ "$unreadable" -gt 0 ]; then
  cat <<'EOF'

UNREADABLE — the link target exists and is a directory, but some of its content
could not be read: a permission error, or a cloud placeholder that failed to
download. It is not missing and must not be recreated. Retry once sync settles,
and keep the store always available offline.
EOF
  HOOK_LEGEND+=('UNREADABLE: the target exists but some content could not be read (e.g. a cloud placeholder that failed to download); a retry once sync settles is the fix. It is not missing and must not be recreated.')
fi

if [ "$invalid" -gt 0 ]; then
  cat <<'EOF'

INVALID — a memory path or link target is not an inspectable directory. It is
not safe to report that project as linked.
EOF
  HOOK_LEGEND+=('INVALID: a memory path or link target is not an inspectable directory, so the project is not safely linked.')
fi

if [ "$settings_issues" -gt 0 ]; then
  cat <<'EOF'

DECLARED MEMORY DIRECTORY — a .claude setting names a memory location that
cannot work as written. This does not tell you which setting Claude Code
actually applied; it tells you this one would fail if it were applied. A settings
file inside a synced folder is the sharp case: it travels to your other machine,
where an absolute path from this one does not resolve. Prefer a link there, or a
path that is valid on every machine.
EOF
  HOOK_LEGEND+=('DECLARED MEMORY DIRECTORY: a .claude autoMemoryDirectory cannot work as written (relative, missing, or an absolute path in a synced settings file).')
fi

if [ "$at_risk" -gt 0 ] || [ "$orphans" -gt 0 ] || [ "$unreadable" -gt 0 ] || [ "$invalid" -gt 0 ] ||
  [ "$unverified" -gt 0 ] || [ "$settings_issues" -gt 0 ]; then
  exit 1
fi

exit 0
