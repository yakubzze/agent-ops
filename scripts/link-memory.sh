#!/usr/bin/env bash
#
# agent-ops · link-memory
#
# Copy a project's legacy/default memory directory into a stable store, retain
# the original as a timestamped backup, and put a verified symlink in its place.
# Every directory entry counts as content; no filename or extension is ignored.
#
# Exit codes:
#   0  linked, already linked and verified, or successful dry run
#   1  safety refusal or operational failure
#   2  usage/configuration error
#
# Usage:
#   ./link-memory.sh --project SLUG --store DIR [--name NAME]
#                    [--projects-dir DIR] [--dry-run]

set -euo pipefail

PROJECTS_DIR="${HOME}/.claude/projects"
PROJECT=""
STORE=""
NAME=""
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: link-memory.sh --project SLUG --store DIR [options]

Options:
  --project SLUG      Project directory name in the legacy/default layout
  --store DIR         Stable store (may be a relative path)
  --name NAME         Directory name within the store (default: SLUG)
  --projects-dir DIR  Legacy/default projects directory
  --dry-run           Validate and describe changes without writing
  -h, --help          Show this help
EOF
}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  printf 'Try --help for usage.\n' >&2
  exit 2
}

safety_error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

operation_error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

need_value() {
  # shellcheck disable=SC2015  # B is a pure test; C only runs when A fails.
  [ "$#" -ge 2 ] && [ -n "$2" ] || usage_error "$1 requires a non-empty value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --project)
      need_value "$@"
      PROJECT=$2
      shift 2
      ;;
    --store)
      need_value "$@"
      STORE=$2
      shift 2
      ;;
    --name)
      need_value "$@"
      NAME=$2
      shift 2
      ;;
    --projects-dir)
      need_value "$@"
      PROJECTS_DIR=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

[ -n "$PROJECT" ] || usage_error "--project is required (find it with memory-doctor.sh)"
[ -n "$STORE" ] || usage_error "--store is required"
[ -n "$NAME" ] || NAME=$PROJECT

valid_component() {
  case "$1" in
    ''|.|..|*/*|*\\*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_component "$PROJECT" || usage_error "--project must be one path component (no traversal or separators)"
valid_component "$NAME" || usage_error "--name must be one path component (no traversal or separators)"

# Git Bash / MSYS may copy a directory for `ln -s`, creating two stores that
# silently diverge. The PowerShell linker uses a junction and is the safe path.
case "$(uname -s 2>/dev/null || printf unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    cat >&2 <<'EOF'
This script cannot safely create links under Git Bash / MSYS on Windows.
Use the PowerShell version instead:

  pwsh ./scripts/link-memory.ps1 -Project <slug> -Store "$HOME\agent-memory"
EOF
    exit 2
    ;;
esac

contains_parent_traversal() {
  case "/$1/" in
    */../*) return 0 ;;
    *) return 1 ;;
  esac
}

# Canonicalize existing directory components and preserve a missing suffix.
# Parent traversal is deliberately rejected rather than interpreted, avoiding
# surprising results when an earlier component is itself a symlink.
canonicalize_directory_path() {
  local raw=$1 absolute=/ resolved=/ component candidate missing=0
  local -a components=()

  [ -n "$raw" ] || return 2
  contains_parent_traversal "$raw" && return 2
  case "$raw" in
    /*) absolute=$raw ;;
    *) absolute=$PWD/$raw ;;
  esac

  IFS=/ read -r -a components <<< "${absolute#/}"
  # A path of exactly "/" leaves no components, and expanding an empty array
  # under `set -u` aborts on Bash 3.2 (macOS). Guard it so the caller gets the
  # normal refusal instead of an unbound-variable crash.
  for component in "${components[@]+"${components[@]}"}"; do
    case "$component" in
      ''|.) continue ;;
      ..) return 2 ;;
    esac
    if [ "$resolved" = / ]; then
      candidate=/$component
    else
      candidate=$resolved/$component
    fi
    if [ "$missing" -eq 1 ]; then
      resolved=$candidate
      continue
    fi
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      [ -d "$candidate" ] || return 1
      resolved=$(CDPATH='' cd -P -- "$candidate" 2>/dev/null && pwd -P) || return 1
    else
      [ -x "$resolved" ] || return 1
      resolved=$candidate
      missing=1
    fi
  done
  REPLY=$resolved
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

canonical_existing_dir() {
  [ -d "$1" ] || return 1
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# Return 0 when the exact path is present in its parent's directory listing,
# 1 when absent, and 2 when the parent cannot be enumerated safely. This closes
# the gap where a failed stat could otherwise be mistaken for non-existence.
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

canonicalize_directory_path "$PROJECTS_DIR" || {
  case "$?" in
    2) usage_error "--projects-dir contains parent traversal" ;;
    *) usage_error "--projects-dir is not a directory: $PROJECTS_DIR" ;;
  esac
}
PROJECTS_DIR=$REPLY
[ "$PROJECTS_DIR" != / ] || usage_error "--projects-dir may not be the filesystem root"
[ -d "$PROJECTS_DIR" ] || usage_error "--projects-dir is not a directory: $PROJECTS_DIR"

PROJECT_PATH=$PROJECTS_DIR/$PROJECT
[ -d "$PROJECT_PATH" ] || usage_error "no such project: $PROJECT_PATH"
PROJECT_CANON=$(canonical_existing_dir "$PROJECT_PATH") || usage_error "project directory cannot be inspected: $PROJECT_PATH"
path_within "$PROJECT_CANON" "$PROJECTS_DIR" || safety_error "project directory resolves outside --projects-dir"
PROJECT_PATH=$PROJECT_CANON
AGENT_MEM=$PROJECT_PATH/memory

canonicalize_directory_path "$STORE" || {
  case "$?" in
    2) usage_error "--store contains parent traversal" ;;
    *) usage_error "--store has a non-directory or unreadable component: $STORE" ;;
  esac
}
STORE=$REPLY
[ "$STORE" != / ] || usage_error "--store may not be the filesystem root"
DEST=$STORE/$NAME

SOURCE_LISTED=0
if directory_contains_path "$AGENT_MEM"; then
  SOURCE_LISTED=1
else
  status=$?
  [ "$status" -ne 2 ] || safety_error "project directory cannot be enumerated safely: $PROJECT_PATH"
fi
if [ "$SOURCE_LISTED" -eq 1 ] && [ ! -e "$AGENT_MEM" ] && [ ! -L "$AGENT_MEM" ]; then
  safety_error "agent memory is listed but cannot be inspected: $AGENT_MEM"
fi

DEST_LISTED=0
if [ -d "$STORE" ]; then
  if directory_contains_path "$DEST"; then
    DEST_LISTED=1
  else
    status=$?
    [ "$status" -ne 2 ] || safety_error "store directory cannot be enumerated safely: $STORE"
  fi
  if [ "$DEST_LISTED" -eq 1 ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
    safety_error "destination is listed but cannot be inspected: $DEST"
  fi
fi

if [ "$DEST" = "$AGENT_MEM" ]; then
  safety_error "destination and agent memory are the same path"
fi
if path_within "$DEST" "$AGENT_MEM" || path_within "$AGENT_MEM" "$DEST"; then
  safety_error "source and destination may not contain one another"
fi
if path_within "$DEST" "$PROJECTS_DIR"; then
  safety_error "destination is inside the path-derived projects directory"
fi

if [ -L "$DEST" ]; then
  safety_error "destination is already a symlink; choose its real directory explicitly: $DEST"
fi
if [ -e "$DEST" ] && [ ! -d "$DEST" ]; then
  safety_error "destination exists but is not a directory: $DEST"
fi

INSPECT_COUNT=0
INSPECT_LINK_COUNT=0
inspect_tree() {
  local root=$1 output
  output=$(
    find -H "$root" -mindepth 1 -print0 2>/dev/null |
      {
        count=0
        link_count=0
        while IFS= read -r -d '' item; do
          count=$((count + 1))
          if [ -L "$item" ]; then
            readlink "$item" >/dev/null 2>&1 || exit 2
            link_count=$((link_count + 1))
          elif [ -f "$item" ]; then
            command cat "$item" >/dev/null 2>&1 || exit 2
          fi
        done
        printf '%s %s\n' "$count" "$link_count"
      }
  ) || return 2
  IFS=' ' read -r INSPECT_COUNT INSPECT_LINK_COUNT <<< "$output"
}

# Existing links are idempotent only when both the requested destination and
# the link target exist as directories, their canonical paths are equal, and
# the linked tree still satisfies the same no-nested-links safety policy used
# during an initial migration.
if [ -L "$AGENT_MEM" ]; then
  current=$(readlink "$AGENT_MEM" 2>/dev/null || printf '<unreadable>')
  if [ ! -e "$AGENT_MEM" ]; then
    safety_error "agent memory is a dangling link ($current); repair it deliberately"
  fi
  [ -d "$AGENT_MEM" ] || safety_error "agent memory link target is not a directory ($current)"
  [ -d "$DEST" ] || safety_error "requested destination is not an existing directory: $DEST"
  CURRENT_CANON=$(canonical_existing_dir "$AGENT_MEM") || safety_error "agent memory link target cannot be inspected"
  DEST_CANON=$(canonical_existing_dir "$DEST") || safety_error "requested destination cannot be inspected"
  if [ "$CURRENT_CANON" = "$DEST_CANON" ]; then
    inspect_tree "$AGENT_MEM" || safety_error "cannot inspect all linked content; permissions or filesystem errors may hide data"
    [ "$INSPECT_LINK_COUNT" -eq 0 ] || safety_error "nested symbolic links are not accepted automatically; inspect and replace them deliberately"
    printf 'agent-ops · link-memory\n'
    printf 'Already linked to the requested directory and verified. Nothing to do.\n'
    exit 0
  fi
  printf 'This memory is already a link, but it points somewhere else:\n' >&2
  printf '  current: %s\n  wanted : %s\n' "$current" "$DEST" >&2
  safety_error "re-pointing could strand content; inspect and merge first"
fi

if [ -e "$AGENT_MEM" ] && [ ! -d "$AGENT_MEM" ]; then
  safety_error "agent memory exists but is not a directory: $AGENT_MEM"
fi

COMPARE_LIST_A=""
COMPARE_LIST_B=""

# Compare every relative entry, its kind, symlink text, and regular-file bytes.
# Listings are NUL-delimited so spaces, Unicode and newlines remain unambiguous.
# The optional third argument names one root-level transaction marker to ignore.
trees_equal() {
  local left=$1 right=$2 ignored=${3:-}
  local item relative peer left_count=0 right_count=0 result=0

  COMPARE_LIST_A=$(mktemp "${TMPDIR:-/tmp}/agent-ops-inventory.XXXXXX") || return 2
  COMPARE_LIST_B=$(mktemp "${TMPDIR:-/tmp}/agent-ops-inventory.XXXXXX") || {
    rm "$COMPARE_LIST_A" 2>/dev/null || true
    COMPARE_LIST_A=""
    return 2
  }

  find -H "$left" -mindepth 1 -print0 >"$COMPARE_LIST_A" 2>/dev/null || result=2
  find -H "$right" -mindepth 1 -print0 >"$COMPARE_LIST_B" 2>/dev/null || result=2

  if [ "$result" -eq 0 ]; then
    while IFS= read -r -d '' item; do
      relative=${item#"$left"/}
      [ -n "$ignored" ] && [ "$relative" = "$ignored" ] && continue
      left_count=$((left_count + 1))
      peer=$right/$relative

      if [ -L "$item" ]; then
        if [ ! -L "$peer" ] || [ "$(readlink "$item" 2>/dev/null)" != "$(readlink "$peer" 2>/dev/null)" ]; then
          result=1
          break
        fi
      elif [ -d "$item" ]; then
        if [ ! -d "$peer" ] || [ -L "$peer" ]; then result=1; break; fi
      elif [ -f "$item" ]; then
        if [ ! -f "$peer" ] || [ -L "$peer" ] || ! cmp -s "$item" "$peer"; then result=1; break; fi
      elif [ -p "$item" ]; then
        if [ ! -p "$peer" ] || [ -L "$peer" ]; then result=1; break; fi
      elif [ -S "$item" ]; then
        if [ ! -S "$peer" ] || [ -L "$peer" ]; then result=1; break; fi
      elif [ -b "$item" ]; then
        if [ ! -b "$peer" ] || [ -L "$peer" ]; then result=1; break; fi
      elif [ -c "$item" ]; then
        if [ ! -c "$peer" ] || [ -L "$peer" ]; then result=1; break; fi
      else
        result=1
        break
      fi
    done <"$COMPARE_LIST_A"
  fi

  if [ "$result" -eq 0 ]; then
    while IFS= read -r -d '' item; do
      relative=${item#"$right"/}
      [ -n "$ignored" ] && [ "$relative" = "$ignored" ] && continue
      right_count=$((right_count + 1))
    done <"$COMPARE_LIST_B"
    [ "$left_count" -eq "$right_count" ] || result=1
  fi

  rm "$COMPARE_LIST_A" "$COMPARE_LIST_B" 2>/dev/null || result=2
  COMPARE_LIST_A=""
  COMPARE_LIST_B=""
  return "$result"
}

SOURCE_EXISTS=0
SOURCE_HAS_CONTENT=0
SOURCE_COUNT=0
DEST_EXISTS=0
DEST_HAS_CONTENT=0
DEST_COUNT=0

if [ -d "$AGENT_MEM" ]; then
  SOURCE_EXISTS=1
  inspect_tree "$AGENT_MEM" || safety_error "cannot inspect all source content: $AGENT_MEM"
  [ "$INSPECT_LINK_COUNT" -eq 0 ] || safety_error "nested symbolic links are not migrated automatically: $AGENT_MEM"
  SOURCE_COUNT=$INSPECT_COUNT
  [ "$SOURCE_COUNT" -eq 0 ] || SOURCE_HAS_CONTENT=1
fi

if [ -d "$DEST" ]; then
  DEST_EXISTS=1
  inspect_tree "$DEST" || safety_error "cannot inspect all destination content: $DEST"
  [ "$INSPECT_LINK_COUNT" -eq 0 ] || safety_error "nested symbolic links are not migrated automatically: $DEST"
  DEST_COUNT=$INSPECT_COUNT
  [ "$DEST_COUNT" -eq 0 ] || DEST_HAS_CONTENT=1
fi

if [ "$SOURCE_HAS_CONTENT" -eq 1 ] && [ "$DEST_HAS_CONTENT" -eq 1 ]; then
  cat >&2 <<EOF
REFUSING — both sides contain directory entries.

  $AGENT_MEM
      $SOURCE_COUNT item(s)
  $DEST
      $DEST_COUNT item(s)

No entry is assumed disposable, regardless of filename or extension. Merge the
two directories deliberately, make the destination empty, and re-run.
EOF
  exit 1
fi

BACKUP_PREVIEW=${AGENT_MEM}.backup-$(date +%Y%m%d-%H%M%S).XXXXXX/memory

printf 'agent-ops · link-memory\n'
printf '  agent memory : %s\n' "$AGENT_MEM"
printf '  store        : %s\n' "$DEST"
[ "$DRY_RUN" -eq 1 ] && printf '  (dry run — nothing will be changed)\n'
printf '\n'

print_command() {
  printf '  would run:'
  printf ' %q' "$@"
  printf '\n'
}

NEED_INSTALL=0
if [ "$DEST_EXISTS" -eq 0 ] || [ "$SOURCE_HAS_CONTENT" -eq 1 ]; then
  NEED_INSTALL=1
fi

if [ "$DRY_RUN" -eq 1 ]; then
  [ -d "$STORE" ] || print_command mkdir -p "$STORE"
  if [ "$NEED_INSTALL" -eq 1 ]; then
    printf '  would stage a new destination without overwriting existing content\n'
    [ "$SOURCE_HAS_CONTENT" -eq 1 ] && print_command cp -a "$AGENT_MEM/." '<transaction-stage>/'
    [ "$DEST_EXISTS" -eq 1 ] && printf '  would preserve and restore the existing empty destination transactionally\n'
  fi
  if [ "$SOURCE_EXISTS" -eq 1 ]; then
    print_command mv "$AGENT_MEM" "$BACKUP_PREVIEW"
    printf '  would keep the original at: %s\n' "$BACKUP_PREVIEW"
  fi
  print_command ln -s "$DEST" "$AGENT_MEM"
  printf '\nDry run complete.\n'
  exit 0
fi

STORE_EXISTED=0
[ -d "$STORE" ] && STORE_EXISTED=1
if [ "$STORE_EXISTED" -eq 0 ]; then
  mkdir -p "$STORE" || operation_error "could not create store: $STORE"
fi
STORE_AFTER=$(canonical_existing_dir "$STORE") || operation_error "store cannot be inspected after creation: $STORE"
[ "$STORE_AFTER" = "$STORE" ] || operation_error "store changed while preparing the transaction"

TXN_ACTIVE=1
TXN_COMMITTED=0
STAGE=""
HOLD=""
HOLD_CONTAINER=""
HOLD_COUNT=-1
HOLD_LINK_COUNT=-1
BACKUP=""
BACKUP_CONTAINER=""
MARKER_NAME=""
TOKEN=""

owned_directory() {
  local dir=$1 marker_value
  [ -n "$MARKER_NAME" ] && [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/$MARKER_NAME" ] || return 1
  marker_value=$(command cat "$dir/$MARKER_NAME" 2>/dev/null) || return 1
  [ "$marker_value" = "$TOKEN" ]
}

# A marker proves that this transaction created DEST, but not that another
# writer left it untouched. Delete it during rollback only when its complete
# user-visible tree still matches a transaction copy or the restored source.
# shellcheck disable=SC2329,SC2317  # Invoked by rollback(), which runs through a trap.
transaction_destination_unchanged() {
  owned_directory "$DEST" || return 1

  if [ -n "$STAGE" ] && owned_directory "$STAGE" &&
      trees_equal "$STAGE" "$DEST" "$MARKER_NAME"; then
    return 0
  fi
  if [ "$SOURCE_EXISTS" -eq 1 ] && [ -d "$AGENT_MEM" ] && [ ! -L "$AGENT_MEM" ] &&
      trees_equal "$AGENT_MEM" "$DEST" "$MARKER_NAME"; then
    return 0
  fi
  if [ "$SOURCE_EXISTS" -eq 0 ] && inspect_tree "$DEST" &&
      [ "$INSPECT_COUNT" -eq 1 ] && [ "$INSPECT_LINK_COUNT" -eq 0 ]; then
    return 0
  fi
  return 1
}

# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329,SC2317
rollback() {
  local status=$1 rollback_failed=0 source_safe=1 current=""
  local restore_count=-1 restore_link_count=-1
  trap - EXIT HUP INT TERM
  set +e
  [ "$TXN_ACTIVE" -eq 1 ] && [ "$TXN_COMMITTED" -eq 0 ] || return "$status"

  printf 'Transaction did not complete; rolling back.\n' >&2

  if [ -L "$AGENT_MEM" ]; then
    current=$(readlink "$AGENT_MEM" 2>/dev/null)
    if [ "$current" = "$DEST" ]; then
      if ! rm "$AGENT_MEM"; then
        rollback_failed=1
        source_safe=0
      fi
    else
      printf 'rollback warning: unexpected link left at %s\n' "$AGENT_MEM" >&2
      rollback_failed=1
      source_safe=0
    fi
  fi

  if [ -d "$BACKUP" ]; then
    if [ ! -e "$AGENT_MEM" ] && [ ! -L "$AGENT_MEM" ]; then
      if inspect_tree "$BACKUP"; then
        restore_count=$INSPECT_COUNT
        restore_link_count=$INSPECT_LINK_COUNT
      fi
      if ! mv "$BACKUP" "$AGENT_MEM"; then
        rollback_failed=1
        source_safe=0
      elif ! inspect_tree "$AGENT_MEM" ||
          [ "$restore_count" -lt 0 ] ||
          [ "$INSPECT_COUNT" -ne "$restore_count" ] ||
          [ "$INSPECT_LINK_COUNT" -ne "$restore_link_count" ]; then
        printf 'rollback warning: restored source inventory could not be verified\n' >&2
        rollback_failed=1
        source_safe=0
      fi
    else
      printf 'rollback warning: original remains safely at %s\n' "$BACKUP" >&2
      rollback_failed=1
      source_safe=0
    fi
  elif [ "$SOURCE_EXISTS" -eq 1 ] && { [ ! -d "$AGENT_MEM" ] || [ -L "$AGENT_MEM" ]; }; then
    printf 'rollback warning: the original source or its backup could not be found\n' >&2
    rollback_failed=1
    source_safe=0
  fi

  if [ "$source_safe" -eq 1 ] && [ -n "$BACKUP_CONTAINER" ] && [ -d "$BACKUP_CONTAINER" ]; then
    if [ -e "$BACKUP" ] || [ -L "$BACKUP" ]; then
      printf 'rollback warning: backup payload remains safely at %s\n' "$BACKUP" >&2
      rollback_failed=1
    else
      rmdir "$BACKUP_CONTAINER" || rollback_failed=1
    fi
  fi

  # Until the source has been restored, DEST may be the only complete copy.
  # Preserve every transaction artifact when source recovery is uncertain.
  if [ "$source_safe" -eq 1 ]; then
    if [ "$NEED_INSTALL" -eq 1 ] && { [ -e "$DEST" ] || [ -L "$DEST" ]; }; then
      if transaction_destination_unchanged; then
        rm -rf -- "$DEST" || rollback_failed=1
      else
        printf 'rollback warning: destination changed after creation; preserved at %s\n' "$DEST" >&2
        rollback_failed=1
      fi
    fi

    if [ -n "$HOLD" ] && [ -d "$HOLD" ]; then
      if [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
        if ! mv "$HOLD" "$DEST"; then
          rollback_failed=1
        elif ! inspect_tree "$DEST" ||
            [ "$HOLD_COUNT" -lt 0 ] ||
            [ "$INSPECT_COUNT" -ne "$HOLD_COUNT" ] ||
            [ "$INSPECT_LINK_COUNT" -ne "$HOLD_LINK_COUNT" ]; then
          printf 'rollback warning: restored destination inventory could not be verified\n' >&2
          rollback_failed=1
        fi
      else
        printf 'rollback warning: original empty destination remains at %s\n' "$HOLD" >&2
        rollback_failed=1
      fi
    elif [ "$DEST_EXISTS" -eq 1 ] && [ "$NEED_INSTALL" -eq 1 ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ]; then
      # A signal can arrive after the original empty HOLD was released but
      # before the ownership marker was removed. Restore its empty state.
      mkdir "$DEST" || rollback_failed=1
    fi

    if [ -n "$HOLD_CONTAINER" ] && [ -d "$HOLD_CONTAINER" ] &&
        { [ ! -e "$HOLD" ] && [ ! -L "$HOLD" ]; }; then
      rmdir "$HOLD_CONTAINER" || rollback_failed=1
    fi

    if [ -n "$STAGE" ] && owned_directory "$STAGE"; then
      rm -rf -- "$STAGE" || rollback_failed=1
    fi
  fi

  if [ -n "$COMPARE_LIST_A" ] && [ -f "$COMPARE_LIST_A" ]; then
    rm "$COMPARE_LIST_A" || rollback_failed=1
  fi
  if [ -n "$COMPARE_LIST_B" ] && [ -f "$COMPARE_LIST_B" ]; then
    rm "$COMPARE_LIST_B" || rollback_failed=1
  fi
  if [ "$source_safe" -eq 1 ] && [ "$STORE_EXISTED" -eq 0 ]; then
    rmdir "$STORE" 2>/dev/null || true
  fi

  if [ "$rollback_failed" -eq 0 ]; then
    printf 'Rollback complete; the original source state was restored.\n' >&2
  else
    printf 'rollback warning: automatic rollback was incomplete; inspect the paths above.\n' >&2
  fi
  return "$status"
}

trap 'rollback "$?"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$NEED_INSTALL" -eq 1 ]; then
  STAGE=$(mktemp -d "$STORE/.agent-ops-stage.XXXXXX") || operation_error "could not create transaction stage"
  TOKEN="agent-ops-$$-${RANDOM:-0}-$(date +%s)"
  MARKER_NAME=.agent-ops-transaction-$TOKEN
  while [ -e "$AGENT_MEM/$MARKER_NAME" ] || [ -L "$AGENT_MEM/$MARKER_NAME" ]; do
    TOKEN="agent-ops-$$-${RANDOM:-0}-$(date +%s)"
    MARKER_NAME=.agent-ops-transaction-$TOKEN
  done

  if [ "$SOURCE_HAS_CONTENT" -eq 1 ]; then
    cp -a "$AGENT_MEM/." "$STAGE/" || operation_error "copy into the transaction stage failed"
  fi
  printf '%s\n' "$TOKEN" >"$STAGE/$MARKER_NAME" || operation_error "could not mark the transaction stage"
  if [ "$SOURCE_HAS_CONTENT" -eq 1 ] && ! trees_equal "$AGENT_MEM" "$STAGE" "$MARKER_NAME"; then
    operation_error "staged copy does not exactly match the source"
  fi

  # Recheck immediately before preserving an empty destination. If it gained
  # content, moving it to HOLD still preserves that content and the later
  # rmdir will force a rollback rather than discard anything.
  if [ -d "$DEST" ]; then
    if ! inspect_tree "$DEST"; then
      operation_error "destination became unreadable during the transaction"
    elif [ "$INSPECT_COUNT" -gt 0 ]; then
      operation_error "destination gained content during the transaction; nothing was overwritten"
    fi
    HOLD_CONTAINER=$(mktemp -d "$STORE/.agent-ops-empty.XXXXXX") || operation_error "could not reserve destination rollback container"
    HOLD=$HOLD_CONTAINER/original
    mv "$DEST" "$HOLD" || operation_error "could not preserve the existing empty destination"
    inspect_tree "$HOLD" || operation_error "preserved destination cannot be fully inspected"
    HOLD_COUNT=$INSPECT_COUNT
    HOLD_LINK_COUNT=$INSPECT_LINK_COUNT
  elif [ -e "$DEST" ] || [ -L "$DEST" ]; then
    operation_error "destination appeared during the transaction; refusing to overwrite it"
  fi

  # mkdir is the no-clobber commit point: it fails atomically if any path has
  # appeared at DEST. Copy only after this transaction owns the new directory.
  mkdir "$DEST" || operation_error "destination appeared during the transaction; refusing to overwrite it"
  printf '%s\n' "$TOKEN" >"$DEST/$MARKER_NAME" || operation_error "could not mark the new destination"
  cp -a "$STAGE/." "$DEST/" || operation_error "could not install the staged destination"
  owned_directory "$DEST" || operation_error "staged destination was not installed at the expected path"
  if [ "$SOURCE_HAS_CONTENT" -eq 1 ] && ! trees_equal "$AGENT_MEM" "$DEST" "$MARKER_NAME"; then
    operation_error "destination verification failed before the source was changed"
  fi
fi

if [ "$SOURCE_EXISTS" -eq 1 ]; then
  BACKUP_CONTAINER=$(mktemp -d "${AGENT_MEM}.backup-$(date +%Y%m%d-%H%M%S).XXXXXX") || operation_error "could not reserve a backup container"
  BACKUP=$BACKUP_CONTAINER/memory
  printf 'Keeping the original at: %s\n' "$BACKUP"
  # shellcheck disable=SC2015  # Both tests are pure; C only runs when A fails.
  [ ! -e "$BACKUP" ] && [ ! -L "$BACKUP" ] || operation_error "reserved backup path was unexpectedly occupied"
  mv "$AGENT_MEM" "$BACKUP" || operation_error "could not move the original memory to its backup"
  inspect_tree "$BACKUP" || operation_error "the source backup cannot be inspected"
  BACKUP_COUNT=$INSPECT_COUNT
  [ "$INSPECT_LINK_COUNT" -eq 0 ] || operation_error "source gained a nested symbolic link before backup"
  if [ "$SOURCE_HAS_CONTENT" -eq 1 ]; then
    if ! trees_equal "$BACKUP" "$DEST" "$MARKER_NAME"; then
      operation_error "source changed between copy verification and backup; refusing an incomplete target"
    fi
  elif [ "$BACKUP_COUNT" -gt 0 ]; then
    operation_error "source gained content before backup; refusing an incomplete target"
  fi
fi

ln -s "$DEST" "$AGENT_MEM" || operation_error "could not create the memory symlink"

if [ ! -L "$AGENT_MEM" ] || [ ! -d "$AGENT_MEM" ]; then
  operation_error "the new path is not a symlink to an existing directory"
fi
LINK_CANON=$(canonical_existing_dir "$AGENT_MEM") || operation_error "the new link target cannot be inspected"
DEST_CANON=$(canonical_existing_dir "$DEST") || operation_error "the destination cannot be inspected"
[ "$LINK_CANON" = "$DEST_CANON" ] || operation_error "the new link resolves somewhere unexpected"
inspect_tree "$AGENT_MEM" || operation_error "content through the new link cannot be fully inspected"
[ "$INSPECT_LINK_COUNT" -eq 0 ] || operation_error "destination gained a nested symbolic link during the transaction"
LINKED_COUNT=$INSPECT_COUNT

if [ "$NEED_INSTALL" -eq 1 ] && owned_directory "$STAGE"; then
  rm -rf "$STAGE" || operation_error "could not remove the transaction stage"
fi
if [ -n "$HOLD" ] && [ -d "$HOLD" ]; then
  rmdir "$HOLD" || operation_error "could not release the preserved empty destination"
fi
if [ -n "$HOLD_CONTAINER" ] && [ -d "$HOLD_CONTAINER" ]; then
  rmdir "$HOLD_CONTAINER" || operation_error "could not release the destination rollback container"
fi
if [ "$NEED_INSTALL" -eq 1 ]; then
  rm "$DEST/$MARKER_NAME" || operation_error "could not remove the transaction marker"
fi

TXN_COMMITTED=1
trap - EXIT HUP INT TERM

printf '\nLinked. %s item(s) now reachable through the agent path.\n' "$LINKED_COUNT"
printf 'Verify with memory-doctor.sh --stable-root %q\n' "$STORE"
exit 0
