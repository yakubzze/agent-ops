#!/usr/bin/env bash

# Self-contained regression tests for the Bash memory tools. No test framework
# is required; run from any directory with: bash tests/bash/run-tests.sh

set -euo pipefail

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd -P)
REPO_ROOT=$(CDPATH='' cd -P -- "$SCRIPT_DIR/../.." && pwd -P)
LINKER=$REPO_ROOT/scripts/link-memory.sh
DOCTOR=$REPO_ROOT/scripts/memory-doctor.sh

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/agent-ops-bash-tests.XXXXXX") || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

FAKE_BIN=$TEST_ROOT/fake-bin
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env sh\nprintf "Linux\\n"\n' >"$FAKE_BIN/uname"
chmod +x "$FAKE_BIN/uname"

PASSED=0
FAILED=0
SKIPPED=0
CASE_NUMBER=0
STATUS=0
OUTPUT=""

linker() {
  PATH="$FAKE_BIN:$PATH" "$LINKER" "$@"
}

doctor() {
  "$DOCTOR" "$@"
}

run_cmd() {
  set +e
  OUTPUT=$("$@" 2>&1)
  STATUS=$?
  set -e
  return 0
}

new_case() {
  CASE_NUMBER=$((CASE_NUMBER + 1))
  CASE_DIR=$TEST_ROOT/case-$CASE_NUMBER
  mkdir -p "$CASE_DIR"
}

assert_status() {
  if [ "$STATUS" -ne "$1" ]; then
    printf '    expected status %s, got %s\n%s\n' "$1" "$STATUS" "$OUTPUT" >&2
    return 1
  fi
}

assert_contains() {
  case "$OUTPUT" in
    *"$1"*) return 0 ;;
    *) printf '    output did not contain: %s\n%s\n' "$1" "$OUTPUT" >&2; return 1 ;;
  esac
}

assert_not_contains() {
  case "$OUTPUT" in
    *"$1"*) printf '    output unexpectedly contained: %s\n%s\n' "$1" "$OUTPUT" >&2; return 1 ;;
    *) return 0 ;;
  esac
}

assert_real_dir() {
  # shellcheck disable=SC2015  # Both tests are pure; the block only runs when the first fails.
  [ -d "$1" ] && [ ! -L "$1" ] || {
    printf '    expected a real directory: %s\n' "$1" >&2
    return 1
  }
}

test_argument_errors_are_exit_2() {
  run_cmd linker --project
  assert_status 2 || return 1
  assert_contains 'requires a non-empty value' || return 1
  run_cmd doctor --projects-dir
  assert_status 2 || return 1
  run_cmd linker --project p --store /tmp extra
  assert_status 2 || return 1
}

test_relative_dry_run_is_read_only() {
  new_case
  mkdir -p "$CASE_DIR/projects/my project/memory"
  printf 'opaque\n' >"$CASE_DIR/projects/my project/memory/data.bin"
  (
    cd "$CASE_DIR" || exit 1
    run_cmd linker --projects-dir ./projects --project 'my project' --store './stable store' --name 'Pamięć' --dry-run
    assert_status 0 && assert_contains 'Dry run complete.' && [ ! -e "$CASE_DIR/stable store" ]
  ) || return 1
  assert_real_dir "$CASE_DIR/projects/my project/memory" || return 1
}

test_every_entry_causes_conflict_refusal() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store/p/empty-directory"
  printf 'source\n' >"$CASE_DIR/projects/p/memory/no-extension"
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'both sides contain directory entries' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -d "$CASE_DIR/store/p/empty-directory" ] || return 1
}

test_destination_file_is_never_overwritten() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store"
  printf 'source\n' >"$CASE_DIR/projects/p/memory/source.txt"
  printf 'keep me\n' >"$CASE_DIR/store/p"
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'destination exists but is not a directory' || return 1
  [ "$(command cat "$CASE_DIR/store/p")" = 'keep me' ] || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
}

test_traversal_and_nesting_are_rejected() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store"
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store/../escape" --dry-run
  assert_status 2 || return 1
  assert_contains 'parent traversal' || return 1
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project ../p --store "$CASE_DIR/store" --dry-run
  assert_status 2 || return 1
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/projects/p" --name memory --dry-run
  assert_status 1 || return 1
  assert_contains 'same path' || return 1
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/projects/p/memory" --name child --dry-run
  assert_status 1 || return 1
  assert_contains 'contain one another' || return 1
}

test_ln_failure_rolls_back_source_and_destination() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store" "$CASE_DIR/fail-bin"
  printf 'important\n' >"$CASE_DIR/projects/p/memory/.hidden-state"
  printf '#!/usr/bin/env sh\nexit 77\n' >"$CASE_DIR/fail-bin/ln"
  chmod +x "$CASE_DIR/fail-bin/ln"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  failing_linker() {
    PATH="$CASE_DIR/fail-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }
  run_cmd failing_linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'Rollback complete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/.hidden-state" ] || return 1
  [ ! -e "$CASE_DIR/store/p" ] && [ ! -L "$CASE_DIR/store/p" ] || return 1
  shopt -s nullglob
  local backups=("$CASE_DIR/projects/p/memory.backup-"*)
  local stages=("$CASE_DIR/store/.agent-ops-"*)
  shopt -u nullglob
  [ "${#backups[@]}" -eq 0 ] && [ "${#stages[@]}" -eq 0 ] || return 1
}

test_empty_destination_hold_restores_exact_shape() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store/p" "$CASE_DIR/fail-bin"
  printf 'important\n' >"$CASE_DIR/projects/p/memory/state.bin"
  printf '#!/usr/bin/env sh\nexit 77\n' >"$CASE_DIR/fail-bin/ln"
  chmod +x "$CASE_DIR/fail-bin/ln"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  failing_linker_with_empty_dest() {
    PATH="$CASE_DIR/fail-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }

  run_cmd failing_linker_with_empty_dest --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'Rollback complete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
  assert_real_dir "$CASE_DIR/store/p" || return 1
  [ -z "$(find "$CASE_DIR/store/p" -mindepth 1 -print -quit)" ] || return 1
  shopt -s nullglob
  local artifacts=("$CASE_DIR/store/.agent-ops-"*)
  shopt -u nullglob
  [ "${#artifacts[@]}" -eq 0 ] || return 1
}

test_interrupted_mv_rolls_back_after_the_rename() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store" "$CASE_DIR/interrupt-bin"
  printf 'must survive\n' >"$CASE_DIR/projects/p/memory/state.bin"
  local real_mv
  real_mv=$(command -v mv) || return 1
  cat >"$CASE_DIR/interrupt-bin/mv" <<'EOF'
#!/usr/bin/env sh
"$AGENT_OPS_REAL_MV" "$@" || exit $?
case "$1:$2" in
  */memory:*.backup-*/memory) kill -TERM "$PPID" ;;
esac
exit 0
EOF
  chmod +x "$CASE_DIR/interrupt-bin/mv"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  interrupting_linker() {
    AGENT_OPS_REAL_MV=$real_mv PATH="$CASE_DIR/interrupt-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }
  run_cmd interrupting_linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  [ "$STATUS" -eq 143 ] || {
    printf '    expected signal status 143, got %s\n%s\n' "$STATUS" "$OUTPUT" >&2
    return 1
  }
  assert_contains 'Rollback complete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
  [ ! -e "$CASE_DIR/store/p" ] && [ ! -L "$CASE_DIR/store/p" ] || return 1
}

test_source_change_before_backup_is_preserved_and_refused() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store" "$CASE_DIR/change-bin"
  printf 'initial\n' >"$CASE_DIR/projects/p/memory/state.bin"
  local real_mv
  real_mv=$(command -v mv) || return 1
  cat >"$CASE_DIR/change-bin/mv" <<'EOF'
#!/usr/bin/env sh
case "$1" in
  */memory) printf 'late write\n' >"$1/late-write.bin" ;;
esac
exec "$AGENT_OPS_REAL_MV" "$@"
EOF
  chmod +x "$CASE_DIR/change-bin/mv"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  changing_linker() {
    AGENT_OPS_REAL_MV=$real_mv PATH="$CASE_DIR/change-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }
  run_cmd changing_linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'source changed between copy verification and backup' || return 1
  assert_contains 'Rollback complete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
  [ -f "$CASE_DIR/projects/p/memory/late-write.bin" ] || return 1
  [ ! -e "$CASE_DIR/store/p" ] && [ ! -L "$CASE_DIR/store/p" ] || return 1
}

test_doctor_counts_arbitrary_content() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory/empty-only"
  run_cmd doctor --projects-dir "$CASE_DIR/projects"
  assert_status 1 || return 1
  assert_contains 'AT RISK' || return 1
  assert_contains '1 item(s)' || return 1
  assert_contains 'legacy/default-layout scan' || return 1
  assert_contains '/memory (or /context)' || return 1
}

test_doctor_relative_empty_layout() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory"
  (
    cd "$CASE_DIR" || exit 1
    run_cmd doctor --projects-dir ./projects
    assert_status 0 && assert_contains 'empty legacy/default directory'
  )
}

test_linker_rejects_unreadable_regular_file() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store"
  printf 'secret bytes\n' >"$CASE_DIR/projects/p/memory/unreadable.bin"
  chmod 000 "$CASE_DIR/projects/p/memory/unreadable.bin" || return 77
  if command cat "$CASE_DIR/projects/p/memory/unreadable.bin" >/dev/null 2>&1; then
    chmod 600 "$CASE_DIR/projects/p/memory/unreadable.bin" || true
    return 77
  fi
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store" --dry-run
  chmod 600 "$CASE_DIR/projects/p/memory/unreadable.bin" || true
  assert_status 1 || return 1
  assert_contains 'cannot inspect all source content' || return 1
}

test_linker_rejects_uninspectable_project_directory() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store"
  printf 'state\n' >"$CASE_DIR/projects/p/memory/state.bin"
  chmod 000 "$CASE_DIR/projects/p" || return 77
  if command ls -A "$CASE_DIR/projects/p" >/dev/null 2>&1; then
    chmod 700 "$CASE_DIR/projects/p" || true
    return 77
  fi
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store" --dry-run
  chmod 700 "$CASE_DIR/projects/p" || true
  assert_status 2 || return 1
  assert_contains 'project directory cannot be inspected' || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
}

test_doctor_rejects_uninspectable_projects_root() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory"
  chmod 000 "$CASE_DIR/projects" || return 77
  if command ls -A "$CASE_DIR/projects" >/dev/null 2>&1; then
    chmod 700 "$CASE_DIR/projects" || true
    return 77
  fi
  run_cmd doctor --projects-dir "$CASE_DIR/projects"
  chmod 700 "$CASE_DIR/projects" || true
  assert_status 2 || return 1
  assert_contains 'no readable legacy/default projects directory' || return 1
}

test_linker_rejects_nested_symbolic_links() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/projects/p/shared" "$CASE_DIR/store"
  printf 'must remain here\n' >"$CASE_DIR/projects/p/shared/state.txt"
  ln -s ../shared "$CASE_DIR/projects/p/memory/topic-link" || return 1

  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'nested symbolic links are not migrated automatically' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -L "$CASE_DIR/projects/p/memory/topic-link" ] || return 1
  [ -f "$CASE_DIR/projects/p/memory/topic-link/state.txt" ] || return 1
  [ ! -e "$CASE_DIR/store/p" ] && [ ! -L "$CASE_DIR/store/p" ] || return 1
}

# Probe actual symlink semantics. Git Bash commonly copies directories for
# `ln -s`; link-dependent tests are skipped there while dry-run/refusal and
# rollback tests still run.
NATIVE_LINKS=0
mkdir -p "$TEST_ROOT/link-probe-target"
if ln -s "$TEST_ROOT/link-probe-target" "$TEST_ROOT/link-probe" 2>/dev/null && [ -L "$TEST_ROOT/link-probe" ]; then
  NATIVE_LINKS=1
fi
rm -rf "$TEST_ROOT/link-probe" "$TEST_ROOT/link-probe-target"

test_success_spaces_unicode_and_idempotency() {
  new_case
  mkdir -p "$CASE_DIR/projects/projekt ą/memory/empty-dir" "$CASE_DIR/store with space/pamięć Ω"
  printf 'binary-ish\n' >"$CASE_DIR/projects/projekt ą/memory/.hidden"
  printf 'anything\n' >"$CASE_DIR/projects/projekt ą/memory/state.dat"
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project 'projekt ą' --store "$CASE_DIR/store with space" --name 'pamięć Ω'
  assert_status 0 || return 1
  [ -L "$CASE_DIR/projects/projekt ą/memory" ] || return 1
  [ -f "$CASE_DIR/store with space/pamięć Ω/.hidden" ] || return 1
  [ -d "$CASE_DIR/store with space/pamięć Ω/empty-dir" ] || return 1
  shopt -s nullglob
  local backups=("$CASE_DIR/projects/projekt ą/memory.backup-"*)
  shopt -u nullglob
  [ "${#backups[@]}" -eq 1 ] || return 1
  [ -f "${backups[0]}/memory/state.dat" ] || return 1
  run_cmd linker --projects-dir "$CASE_DIR/projects" --project 'projekt ą' --store "$CASE_DIR/store with space" --name 'pamięć Ω'
  assert_status 0 || return 1
  assert_contains 'Already linked' || return 1
}

test_existing_link_rejects_nested_symbolic_links() {
  new_case
  mkdir -p "$CASE_DIR/projects/p" "$CASE_DIR/store/p" "$CASE_DIR/store/shared"
  printf 'must remain here\n' >"$CASE_DIR/store/shared/state.txt"
  ln -s ../shared "$CASE_DIR/store/p/topic-link" || return 1
  ln -s "$CASE_DIR/store/p" "$CASE_DIR/projects/p/memory" || return 1

  run_cmd linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'nested symbolic links are not accepted automatically' || return 1
  [ -L "$CASE_DIR/projects/p/memory" ] || return 1
  [ -L "$CASE_DIR/store/p/topic-link" ] || return 1
  [ -f "$CASE_DIR/store/p/topic-link/state.txt" ] || return 1
}

test_interrupted_ln_after_creation_rolls_back() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store" "$CASE_DIR/interrupt-bin"
  printf 'must survive too\n' >"$CASE_DIR/projects/p/memory/state.bin"
  local real_ln
  real_ln=$(command -v ln) || return 1
  cat >"$CASE_DIR/interrupt-bin/ln" <<'EOF'
#!/usr/bin/env sh
"$AGENT_OPS_REAL_LN" "$@" || exit $?
kill -TERM "$PPID"
exit 0
EOF
  chmod +x "$CASE_DIR/interrupt-bin/ln"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  interrupting_linker() {
    AGENT_OPS_REAL_LN=$real_ln PATH="$CASE_DIR/interrupt-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }
  run_cmd interrupting_linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  [ "$STATUS" -eq 143 ] || {
    printf '    expected signal status 143, got %s\n%s\n' "$STATUS" "$OUTPUT" >&2
    return 1
  }
  assert_contains 'Rollback complete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
  [ ! -e "$CASE_DIR/store/p" ] && [ ! -L "$CASE_DIR/store/p" ] || return 1
}

test_destination_write_during_failure_is_preserved() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory" "$CASE_DIR/store" "$CASE_DIR/change-bin"
  printf 'original\n' >"$CASE_DIR/projects/p/memory/state.bin"
  local real_ln
  real_ln=$(command -v ln) || return 1
  cat >"$CASE_DIR/change-bin/ln" <<'EOF'
#!/usr/bin/env sh
"$AGENT_OPS_REAL_LN" "$@" || exit $?
printf 'external write\n' >"$2/external-write.txt"
exit 75
EOF
  chmod +x "$CASE_DIR/change-bin/ln"
  # Passed by name to run_cmd.
  # shellcheck disable=SC2329,SC2317
  changing_linker() {
    AGENT_OPS_REAL_LN=$real_ln PATH="$CASE_DIR/change-bin:$FAKE_BIN:$PATH" "$LINKER" "$@"
  }

  run_cmd changing_linker --projects-dir "$CASE_DIR/projects" --project p --store "$CASE_DIR/store"
  assert_status 1 || return 1
  assert_contains 'destination changed after creation; preserved' || return 1
  assert_contains 'automatic rollback was incomplete' || return 1
  assert_real_dir "$CASE_DIR/projects/p/memory" || return 1
  [ -f "$CASE_DIR/projects/p/memory/state.bin" ] || return 1
  [ -f "$CASE_DIR/store/p/external-write.txt" ] || return 1
  [ -f "$CASE_DIR/store/p/state.bin" ] || return 1
}

test_doctor_verification_orphan_and_invalid() {
  new_case
  mkdir -p "$CASE_DIR/projects/linked" "$CASE_DIR/projects/orphan" "$CASE_DIR/projects/file-target" "$CASE_DIR/store/linked"
  printf 'x\n' >"$CASE_DIR/store/linked/data.weird"
  printf 'not a directory\n' >"$CASE_DIR/target-file"
  ln -s "$CASE_DIR/store/linked" "$CASE_DIR/projects/linked/memory" || return 1
  ln -s "$CASE_DIR/missing" "$CASE_DIR/projects/orphan/memory" || return 1
  ln -s "$CASE_DIR/target-file" "$CASE_DIR/projects/file-target/memory" || return 1

  run_cmd doctor --projects-dir "$CASE_DIR/projects"
  assert_status 1 || return 1
  assert_contains 'LINKED' || return 1
  assert_contains 'stability not verified' || return 1
  assert_contains 'ORPHAN' || return 1
  assert_contains 'INVALID' || return 1

  rm "$CASE_DIR/projects/orphan/memory" "$CASE_DIR/projects/file-target/memory"
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --stable-root "$CASE_DIR/store"
  assert_status 0 || return 1
  assert_contains 'OK' || return 1
}

test_doctor_internal_link_is_always_at_risk() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/internal" "$CASE_DIR/projects/p"
  printf 'x\n' >"$CASE_DIR/projects/p/internal/data"
  ln -s "$CASE_DIR/projects/p/internal" "$CASE_DIR/projects/p/memory" || return 1
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --stable-root "$CASE_DIR/projects"
  assert_status 1 || return 1
  assert_contains 'inside legacy tree' || return 1
  assert_not_contains '  OK' || return 1
}

test_doctor_never_okays_an_unreadable_file() {
  new_case
  mkdir -p "$CASE_DIR/projects/p" "$CASE_DIR/store/p"
  printf 'secret bytes\n' >"$CASE_DIR/store/p/unreadable.bin"
  ln -s "$CASE_DIR/store/p" "$CASE_DIR/projects/p/memory" || return 1
  chmod 000 "$CASE_DIR/store/p/unreadable.bin" || return 77
  if command cat "$CASE_DIR/store/p/unreadable.bin" >/dev/null 2>&1; then
    chmod 600 "$CASE_DIR/store/p/unreadable.bin" || true
    return 77
  fi
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --stable-root "$CASE_DIR/store"
  chmod 600 "$CASE_DIR/store/p/unreadable.bin" || true
  assert_status 1 || return 1
  assert_contains 'INVALID' || return 1
  assert_not_contains '  OK' || return 1
}

run_test() {
  local name=$1 result
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    printf 'ok %s - %s\n' "$PASSED" "$name"
  else
    result=$?
    if [ "$result" -eq 77 ]; then
      SKIPPED=$((SKIPPED + 1))
      printf 'ok - %s # SKIP filesystem does not enforce test permissions\n' "$name"
    else
      FAILED=$((FAILED + 1))
      printf 'not ok - %s\n' "$name" >&2
    fi
  fi
}

make_settings_project() {
  # $1 = declared value, $2 = parent directory name (a sync-client name makes the
  # settings file "synced"), $3 = optional raw JSON payload
  local value=$1 parent=${2:-plain-parent} raw=${3:-}
  local project=$CASE_DIR/$parent/my-app
  mkdir -p "$project/.claude" "$CASE_DIR/projects"
  if [ -n "$raw" ]; then
    printf '%s\n' "$raw" >"$project/.claude/settings.local.json"
  else
    printf '{ "autoMemoryDirectory": "%s" }\n' "$value" >"$project/.claude/settings.local.json"
  fi
  printf '%s\n' "$project"
}

test_doctor_handles_an_empty_projects_directory() {
  new_case
  # A fresh install has nothing to scan. Expanding the empty glob array under
  # `set -u` aborts on Bash 3.2, which macOS still ships, so this reports zero
  # projects rather than crashing.
  mkdir -p "$CASE_DIR/projects"
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --skip-settings-check
  assert_status 0 || return 1
  assert_contains '0 project(s)' || return 1
  assert_not_contains 'unbound variable' || return 1
}

test_linker_rejects_the_filesystem_root_without_crashing() {
  new_case
  mkdir -p "$CASE_DIR/projects/p/memory"
  # Same Bash 3.2 empty-array trap on the linker's path canonicaliser: "/" has
  # no components. The caller must get the normal refusal, not a crash.
  run_cmd linker --project p --projects-dir "$CASE_DIR/projects" --store / --dry-run
  assert_not_contains 'unbound variable' || return 1
}

test_doctor_flags_absolute_declaration_in_synced_settings() {
  new_case
  mkdir -p "$CASE_DIR/store"
  # The failure this check exists for: the settings file travels to the other
  # machine, where an absolute path written on this one cannot resolve.
  project=$(make_settings_project "$CASE_DIR/store" Dropbox)
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 1 || return 1
  assert_contains 'SYNCED settings file' || return 1
  assert_contains 'declared memory directory issue(s)' || return 1
}

test_doctor_allows_absolute_declaration_outside_sync() {
  new_case
  mkdir -p "$CASE_DIR/store"
  project=$(make_settings_project "$CASE_DIR/store")
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 0 || return 1
  assert_contains '  OK' || return 1
}

test_doctor_treats_tilde_declaration_as_portable() {
  new_case
  # ~/ resolves per machine, so it is the one absolute-ish form that survives
  # syncing. It must not be read as relative, nor as the synced-path trap.
  # shellcheck disable=SC2088  # the tilde is the literal value under test
  project=$(make_settings_project '~/agent-memory/my-app' OneDrive)
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_not_contains 'relative value' || return 1
  assert_not_contains 'SYNCED settings file' || return 1
}

test_doctor_flags_relative_declaration() {
  new_case
  project=$(make_settings_project 'notes/memory')
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 1 || return 1
  assert_contains 'relative value' || return 1
}

test_doctor_flags_missing_declared_directory() {
  new_case
  project=$(make_settings_project "$CASE_DIR/never-created")
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 1 || return 1
  assert_contains 'does not exist' || return 1
}

test_doctor_skips_settings_on_request() {
  new_case
  project=$(make_settings_project 'notes/memory')
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project" --skip-settings-check
  assert_status 0 || return 1
  assert_not_contains 'declared memory directory' || return 1
}

test_doctor_reports_unparseable_settings() {
  new_case
  # Names the key and then fails to yield a value: both the jq path and the sed
  # fallback must report it rather than read it as "nothing declared".
  project=$(make_settings_project '' plain-parent '{ "autoMemoryDirectory": }')
  run_cmd doctor --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 1 || return 1
  assert_contains 'INVALID' || return 1
}

test_doctor_settings_check_survives_without_jq() {
  new_case
  mkdir -p "$CASE_DIR/store"
  project=$(make_settings_project "$CASE_DIR/store" Dropbox)
  # Exercise the sed fallback explicitly, so the path used on machines without
  # jq is covered even when CI happens to have it installed.
  run_cmd env AGENT_OPS_FORCE_JSON_FALLBACK=1 "$DOCTOR" \
    --projects-dir "$CASE_DIR/projects" --project-dir "$project"
  assert_status 1 || return 1
  assert_contains 'SYNCED settings file' || return 1
}

run_test 'argument errors use exit 2' test_argument_errors_are_exit_2
run_test 'relative dry run is read-only' test_relative_dry_run_is_read_only
run_test 'every destination entry causes refusal' test_every_entry_causes_conflict_refusal
run_test 'destination file is not overwritten' test_destination_file_is_never_overwritten
run_test 'traversal and nesting are rejected' test_traversal_and_nesting_are_rejected
run_test 'ln failure rolls the transaction back' test_ln_failure_rolls_back_source_and_destination
run_test 'empty destination rollback restores the exact directory shape' test_empty_destination_hold_restores_exact_shape
run_test 'interrupted mv rolls back after rename' test_interrupted_mv_rolls_back_after_the_rename
run_test 'source changes before backup are preserved and refused' test_source_change_before_backup_is_preserved_and_refused
run_test 'doctor counts arbitrary content' test_doctor_counts_arbitrary_content
run_test 'doctor supports relative empty layout' test_doctor_relative_empty_layout
run_test 'linker rejects unreadable regular files' test_linker_rejects_unreadable_regular_file
run_test 'linker rejects an uninspectable project directory' test_linker_rejects_uninspectable_project_directory
run_test 'doctor rejects an uninspectable projects root' test_doctor_rejects_uninspectable_projects_root
run_test 'doctor handles an empty projects directory' test_doctor_handles_an_empty_projects_directory
run_test 'linker refuses the filesystem root without crashing' test_linker_rejects_the_filesystem_root_without_crashing
run_test 'doctor flags an absolute declaration in a synced settings file' test_doctor_flags_absolute_declaration_in_synced_settings
run_test 'doctor allows an absolute declaration outside a synced folder' test_doctor_allows_absolute_declaration_outside_sync
run_test 'doctor treats a ~/ declaration as portable' test_doctor_treats_tilde_declaration_as_portable
run_test 'doctor flags a relative declaration as ignored' test_doctor_flags_relative_declaration
run_test 'doctor flags a declared directory that does not exist' test_doctor_flags_missing_declared_directory
run_test 'doctor skips the settings check on request' test_doctor_skips_settings_on_request
run_test 'doctor reports unparseable settings' test_doctor_reports_unparseable_settings
run_test 'doctor settings check works without jq' test_doctor_settings_check_survives_without_jq

if [ "$NATIVE_LINKS" -eq 1 ]; then
  run_test 'nested symbolic links are refused without mutation' test_linker_rejects_nested_symbolic_links
  run_test 'success handles spaces/Unicode and is idempotent' test_success_spaces_unicode_and_idempotency
  run_test 'existing links are rechecked for nested symbolic links' test_existing_link_rejects_nested_symbolic_links
  run_test 'interrupted ln rolls back after link creation' test_interrupted_ln_after_creation_rolls_back
  run_test 'a concurrent destination write is preserved during rollback' test_destination_write_during_failure_is_preserved
  run_test 'doctor distinguishes unverified, orphan, invalid and verified' test_doctor_verification_orphan_and_invalid
  run_test 'doctor rejects links inside the projects tree' test_doctor_internal_link_is_always_at_risk
  run_test 'doctor never reports OK for an unreadable file' test_doctor_never_okays_an_unreadable_file
else
  SKIPPED=$((SKIPPED + 8))
  printf 'ok - nested symbolic-link refusal # SKIP native symlinks unavailable\n'
  printf 'ok - success handles spaces/Unicode and is idempotent # SKIP native symlinks unavailable\n'
  printf 'ok - existing-link nested symbolic-link refusal # SKIP native symlinks unavailable\n'
  printf 'ok - interrupted ln rollback # SKIP native symlinks unavailable\n'
  printf 'ok - concurrent destination-write preservation # SKIP native symlinks unavailable\n'
  printf 'ok - doctor symlink classifications # SKIP native symlinks unavailable\n'
  printf 'ok - doctor internal-link refusal # SKIP native symlinks unavailable\n'
  printf 'ok - doctor unreadable-file refusal # SKIP native symlinks unavailable\n'
fi

printf '\n%s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
