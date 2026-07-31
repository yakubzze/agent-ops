#!/usr/bin/env bash
#
# agent-ops · memory doctor
#
# Audits Claude Code's legacy/default per-project memory layout. This does not
# read Claude settings and therefore cannot discover a configured
# autoMemoryDirectory. Use /memory (or /context) in Claude Code to confirm the
# path that is active for the current session.
#
# Exit codes:
#   0  every discovered link was verified under --stable-root
#   1  content needs attention, a link is unverified, or a path is invalid
#   2  usage/configuration error
#
# Usage:
#   ./memory-doctor.sh [--projects-dir DIR] [--stable-root DIR] [--quiet]

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
STABLE_ROOT=""
QUIET=0

usage() {
  cat <<'EOF'
Usage: memory-doctor.sh [options]

Audit Claude Code's legacy/default <projects-dir>/<slug>/memory layout.

Options:
  --projects-dir DIR  Legacy/default projects directory to scan
  --stable-root DIR   Verify that link targets are contained in this directory
  --quiet             Print only entries that need attention
  -h, --help          Show this help

This command does not read Claude settings. Use /memory (or /context) in
Claude Code to confirm the memory path active for a session.
EOF
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'Try --help for usage.\n' >&2
  exit 2
}

need_value() {
  # shellcheck disable=SC2015  # B is a pure test; C only runs when A fails.
  [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 requires a non-empty value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --projects-dir)
      need_value "$@"
      PROJECTS_DIR=$2
      shift 2
      ;;
    --stable-root)
      need_value "$@"
      STABLE_ROOT=$2
      shift 2
      ;;
    --quiet)
      QUIET=1
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

canonical_dir() {
  [ -d "$1" ] || return 1
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

PROJECTS_CANON=$(canonical_dir "$PROJECTS_DIR") || {
  printf 'error: no readable legacy/default projects directory at: %s\n' "$PROJECTS_DIR" >&2
  printf 'Point at the right one with --projects-dir.\n' >&2
  exit 2
}
PROJECTS_DIR=$PROJECTS_CANON
command ls -A -- "$PROJECTS_DIR" >/dev/null 2>&1 || {
  printf 'error: legacy/default projects directory cannot be enumerated: %s\n' "$PROJECTS_DIR" >&2
  exit 2
}

if [ -n "$STABLE_ROOT" ]; then
  STABLE_CANON=$(canonical_dir "$STABLE_ROOT") || {
    printf 'error: --stable-root is not a readable directory: %s\n' "$STABLE_ROOT" >&2
    exit 2
  }
  STABLE_ROOT=$STABLE_CANON
  command ls -A -- "$STABLE_ROOT" >/dev/null 2>&1 || {
    printf 'error: --stable-root cannot be enumerated: %s\n' "$STABLE_ROOT" >&2
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
INSPECT_COUNT=0
inspect_directory() {
  local root=$1 output
  output=$(
    find -H "$root" -mindepth 1 -print0 2>/dev/null |
      {
        count=0
        while IFS= read -r -d '' item; do
          count=$((count + 1))
          if [ -L "$item" ]; then
            readlink "$item" >/dev/null 2>&1 || exit 1
          elif [ -f "$item" ]; then
            command cat "$item" >/dev/null 2>&1 || exit 1
          fi
        done
        printf '%s\n' "$count"
      }
  ) || return 1
  INSPECT_COUNT=$output
}

at_risk=0
orphans=0
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

for project_dir in "${project_dirs[@]}"; do
  [ -d "$project_dir" ] || continue
  slug=$(basename "$project_dir")
  mem="${project_dir%/}/memory"
  total=$((total + 1))
  if ! command ls -A -- "$project_dir" >/dev/null 2>&1; then
    invalid=$((invalid + 1))
    printf '  %-11s %-40s project directory cannot be enumerated\n' "INVALID" "$slug"
    continue
  fi
  mem_listed=0
  if directory_contains_path "$mem"; then
    mem_listed=1
  else
    status=$?
    if [ "$status" -eq 2 ]; then
      invalid=$((invalid + 1))
      printf '  %-11s %-40s memory path cannot be inspected\n' "INVALID" "$slug"
      continue
    fi
  fi
  if [ "$mem_listed" -eq 1 ] && [ ! -e "$mem" ] && [ ! -L "$mem" ]; then
    invalid=$((invalid + 1))
    printf '  %-11s %-40s memory path is listed but cannot be inspected\n' "INVALID" "$slug"
    continue
  fi

  if [ -L "$mem" ]; then
    target=$(readlink "$mem" 2>/dev/null || printf '<unreadable>')
    if [ ! -e "$mem" ]; then
      orphans=$((orphans + 1))
      printf '  %-11s %-40s → %s (target missing)\n' "ORPHAN" "$slug" "$target"
      continue
    fi
    if [ ! -d "$mem" ]; then
      invalid=$((invalid + 1))
      printf '  %-11s %-40s → %s (target is not a directory)\n' "INVALID" "$slug" "$target"
      continue
    fi
    resolved=$(canonical_dir "$mem") || resolved=""
    if [ -z "$resolved" ] || ! inspect_directory "$mem"; then
      invalid=$((invalid + 1))
      printf '  %-11s %-40s → %s (target cannot be inspected)\n' "INVALID" "$slug" "$target"
      continue
    fi
    count=$INSPECT_COUNT
    if path_within "$resolved" "$PROJECTS_DIR"; then
      at_risk=$((at_risk + 1))
      printf '  %-11s %-40s → %s (%s item(s); inside legacy tree)\n' "AT RISK" "$slug" "$target" "$count"
    elif [ -z "$STABLE_ROOT" ]; then
      unverified=$((unverified + 1))
      printf '  %-11s %-40s → %s (%s item(s); stability not verified)\n' "LINKED" "$slug" "$target" "$count"
    elif path_within "$resolved" "$STABLE_ROOT"; then
      verified=$((verified + 1))
      [ "$QUIET" -eq 1 ] || printf '  %-11s %-40s → %s (%s item(s))\n' "OK" "$slug" "$target" "$count"
    else
      unverified=$((unverified + 1))
      printf '  %-11s %-40s → %s (%s item(s); outside stable root)\n' "UNVERIFIED" "$slug" "$target" "$count"
    fi
  elif [ -e "$mem" ]; then
    if [ ! -d "$mem" ]; then
      invalid=$((invalid + 1))
      printf '  %-11s %-40s legacy/default path is not a directory\n' "INVALID" "$slug"
    elif ! inspect_directory "$mem"; then
      invalid=$((invalid + 1))
      printf '  %-11s %-40s legacy/default directory cannot be inspected\n' "INVALID" "$slug"
    else
      count=$INSPECT_COUNT
      if [ "$count" -gt 0 ]; then
        at_risk=$((at_risk + 1))
        printf '  %-11s %-40s legacy/default directory, %s item(s)\n' "AT RISK" "$slug" "$count"
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

printf '\n%s project(s): %s verified, %s linked/unverified, %s at risk, %s orphaned, %s invalid.\n' \
  "$total" "$verified" "$unverified" "$at_risk" "$orphans" "$invalid"

if [ "$at_risk" -gt 0 ]; then
  cat <<'EOF'

AT RISK — content was found in the path-derived legacy/default layout, or a
link resolves back inside that layout. Moving or renaming a checkout can make
path-derived memory appear to vanish. Confirm the active path with /memory (or
/context) before migrating anything.
EOF
fi

if [ "$unverified" -gt 0 ]; then
  if [ -z "$STABLE_ROOT" ]; then
    cat <<'EOF'

LINKED — the target is an inspectable directory, but this scan cannot call it
stable without a trust boundary. Re-run with --stable-root DIR to verify that
the canonical target is contained there.
EOF
  else
    cat <<'EOF'

UNVERIFIED — the canonical target is outside --stable-root. Check the target
and choose the correct stable root before treating this link as safe.
EOF
  fi
fi

if [ "$orphans" -gt 0 ]; then
  cat <<'EOF'

ORPHAN — a link target is missing. Reconnect or mount the store before letting
an agent write memory at that project path.
EOF
fi

if [ "$invalid" -gt 0 ]; then
  cat <<'EOF'

INVALID — a memory path or link target is not an inspectable directory. It is
not safe to report that project as linked.
EOF
fi

if [ "$at_risk" -gt 0 ] || [ "$orphans" -gt 0 ] || [ "$invalid" -gt 0 ] || [ "$unverified" -gt 0 ]; then
  exit 1
fi

exit 0
