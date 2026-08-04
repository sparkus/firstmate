#!/usr/bin/env bash
# shellcheck disable=SC2034
# Shared completion-triggered refill, concurrency-floor signalling, and refill
# supervision ownership.
#
# Completion and floor events only signal the normal claim-and-dispatch path.
# They never spawn, claim, or bypass pickup checks, exclusions, holds, or parks.
# A home remains supervision-active while a refill wake is queued, a completion
# or floor refill remains unhandled, a completion receipt is pending, or an
# enabled concurrency floor is below target.

_FM_REFILL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_REFILL_LIB_DIR/fm-wake-lib.sh"

FM_REFILL_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_REFILL_REASON=
FM_REFILL_HAZARD=

fm_refill_backend_load() {
  if declare -F fm_backend_of_meta >/dev/null \
    && declare -F fm_backend_target_of_meta >/dev/null \
    && declare -F fm_backend_target_exists >/dev/null \
    && declare -F fm_backend_agent_state >/dev/null; then
    return 0
  fi
  [ -f "$_FM_REFILL_LIB_DIR/fm-backend.sh" ] \
    && [ ! -L "$_FM_REFILL_LIB_DIR/fm-backend.sh" ] || return 1
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_REFILL_LIB_DIR/fm-backend.sh"
}

fm_refill_task_id_valid() {
  local id=$1
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

fm_refill_normalize_count() {
  local value=$1
  value=${value#"${value%%[!0]*}"}
  [ -n "$value" ] || value=0
  printf '%s\n' "$value"
}

fm_refill_count_below_target() {
  local live floor
  live=$(fm_refill_normalize_count "$1")
  floor=$(fm_refill_normalize_count "$2")
  [ "${#live}" -lt "${#floor}" ] && return 0
  [ "${#live}" -gt "${#floor}" ] && return 1
  [[ "$live" < "$floor" ]]
}

fm_refill_concurrency_floor() {
  local config=${1:-$FM_REFILL_CONFIG} f line lines
  f="$config/concurrency-floor"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    printf '0\n'
    return 0
  fi
  lines=$(awk 'END { print NR + 0 }' "$f" 2>/dev/null) || lines=0
  [ "$lines" = 1 ] || { printf '0\n'; return 0; }
  line=$(head -n 1 "$f" 2>/dev/null) || line=
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  case "$line" in
    ''|0|*[!0-9]*) printf '0\n' ;;
    *) fm_refill_normalize_count "$line" ;;
  esac
}

fm_refill_live_ship_count() {
  local state=${1:-$STATE} meta id kind backend target agent_state verdict n=0
  local reader=${FM_CREW_STATE_BIN:-$_FM_REFILL_LIB_DIR/fm-crew-state.sh}
  if ! fm_refill_backend_load; then
    printf '0\n'
    return 0
  fi
  shopt -s nullglob
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_refill_task_id_valid "$id" || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    fm_backend_target_exists "$backend" "$target" "fm-$id" || continue
    agent_state=$(fm_backend_agent_state "$backend" "$target") || agent_state=unreadable
    case "$agent_state" in dead|missing) continue ;; esac
    verdict=$(FM_HOME="$(dirname "$state")" FM_STATE_OVERRIDE="$state" \
      FM_CREW_STATE_NM_TIMEOUT="${FM_REFILL_CREW_STATE_NM_TIMEOUT:-2}" \
      "$reader" "$id" 2>/dev/null) || verdict=
    case "$verdict" in
      'state: working · '*) n=$((n + 1)) ;;
    esac
  done
  shopt -u nullglob
  printf '%s\n' "$n"
}

fm_refill_has_parked_unpushed() {
  local state=${1:-$STATE} meta id kind verdict wt unpushed
  local reader=${FM_CREW_STATE_BIN:-$_FM_REFILL_LIB_DIR/fm-crew-state.sh}
  FM_REFILL_HAZARD=
  shopt -s nullglob
  for meta in "$state"/*.meta; do
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      FM_REFILL_HAZARD="unreadable metadata state for $(basename "$meta" .meta)"
      shopt -u nullglob
      return 0
    fi
    id=$(basename "$meta" .meta)
    if ! fm_refill_task_id_valid "$id"; then
      FM_REFILL_HAZARD="unreadable lifecycle state for $id"
      shopt -u nullglob
      return 0
    fi
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || continue
    verdict=$(FM_HOME="$(dirname "$state")" FM_STATE_OVERRIDE="$state" \
      FM_CREW_STATE_NM_TIMEOUT="${FM_REFILL_CREW_STATE_NM_TIMEOUT:-2}" \
      "$reader" "$id" 2>/dev/null) || verdict=
    case "$verdict" in
      'state: parked · '*) ;;
      'state: working · '*|'state: done · '*|'state: blocked · '*|\
        'state: paused · '*|'state: failed · '*) continue ;;
      *)
        FM_REFILL_HAZARD="unreadable lifecycle state for $id"
        shopt -u nullglob
        return 0
        ;;
    esac
    wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then
      FM_REFILL_HAZARD="unknown worktree state for $(basename "$meta" .meta)"
      shopt -u nullglob
      return 0
    fi
    if ! unpushed=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null); then
      FM_REFILL_HAZARD="unreadable git state for $(basename "$meta" .meta)"
      shopt -u nullglob
      return 0
    fi
    if [ -n "$unpushed" ]; then
      FM_REFILL_HAZARD="unpushed commits in $(basename "$meta" .meta)"
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

fm_refill_hold_suffix() {
  local state=${1:-$STATE}
  if fm_refill_has_parked_unpushed "$state"; then
    printf '%s' "; HOLD: parked ship worktree safety is not proven ($FM_REFILL_HAZARD) - do not pool-dispatch until leases protect ship worktrees or the state is proven clear"
  fi
}

fm_refill_handled_suffix() {
  printf '%s' '; after the claim-and-dispatch attempt, a successful ship spawn clears any completion need automatically; otherwise run bin/fm-refill-complete.sh <no-ready|no-eligible|held-only>'
}

fm_refill_completion_marker() {
  printf '%s/.refill-completion-%s\n' "${2:-$STATE}" "$1"
}

fm_refill_completion_needed_marker() {
  printf '%s/.refill-needed-completion\n' "${1:-$STATE}"
}

fm_refill_floor_needed_marker() {
  printf '%s/.refill-needed-floor\n' "${1:-$STATE}"
}

fm_refill_atomic_write() {
  local path=$1 value=$2 dir tmp
  dir=$(dirname "$path")
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$dir/.refill-write.XXXXXX") || return 1
  if ! (umask 077; printf '%s\n' "$value" > "$tmp") || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
}

fm_refill_mark_needed() {
  fm_refill_atomic_write "$1" "needed $(date +%s)"
}

fm_refill_marker_state() {
  local marker=$1 value
  [ -e "$marker" ] || { printf 'absent\n'; return 0; }
  [ -f "$marker" ] && [ ! -L "$marker" ] || { printf 'pending\n'; return 0; }
  value=$(head -n 1 "$marker" 2>/dev/null || true)
  case "$value" in
    pending*) printf 'pending\n' ;;
    committed*) printf 'committed\n' ;;
    ''|*[!0-9]*) printf 'pending\n' ;;
    *) printf 'committed\n' ;;
  esac
}

fm_refill_queue_payload_locked() {
  local key=$1 queue=${2:-$FM_WAKE_QUEUE}
  awk -F '\t' -v key="$key" '$3 == "check" && $4 == key { payload = $5 } END { if (payload != "") print payload; else exit 1 }' \
    "$queue" 2>/dev/null
}

fm_refill_queue_any_payload_locked() {
  local queue=${1:-$FM_WAKE_QUEUE}
  awk -F '\t' '$3 == "check" && $4 ~ /^refill([:-]|$)/ { payload = $5 } END { if (payload != "") print payload; else exit 1 }' \
    "$queue" 2>/dev/null
}

fm_refill_commit_completion_marker() {
  local id=$1 state=${2:-$STATE}
  fm_refill_atomic_write "$(fm_refill_completion_marker "$id" "$state")" "committed $(date +%s)"
}

fm_refill_finalize_completion_receipts() {
  local queue=${1:-$FM_WAKE_QUEUE} state=${2:-$STATE} key id
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    id=${key#refill:}
    fm_refill_task_id_valid "$id" || return 1
    fm_refill_commit_completion_marker "$id" "$state" || return 1
    fm_refill_mark_needed "$(fm_refill_completion_needed_marker "$state")" || return 1
  done < <(awk -F '\t' '$3 == "check" && $4 ~ /^refill:/ && !seen[$4]++ { print $4 }' "$queue" 2>/dev/null)
}

fm_refill_recover_pending_completions() {
  local state=${1:-$STATE} marker id
  shopt -s nullglob
  for marker in "$state"/.refill-completion-*; do
    [ "$(fm_refill_marker_state "$marker")" = pending ] || continue
    id=${marker##*/.refill-completion-}
    fm_refill_task_id_valid "$id" || continue
    fm_refill_emit_completion "$id" >/dev/null 2>&1 || true
  done
  shopt -u nullglob
}

fm_refill_emit_floor_if_needed() {
  local state=${1:-$STATE} config=${2:-$FM_REFILL_CONFIG} floor live payload existing status=1
  FM_REFILL_REASON=
  floor=$(fm_refill_concurrency_floor "$config")
  case "$floor" in
    ''|0|*[!0-9]*)
      fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
      rm -f "$(fm_refill_floor_needed_marker "$state")" 2>/dev/null || true
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
      ;;
  esac
  live=$(fm_refill_live_ship_count "$state")
  case "$live" in ''|*[!0-9]*) live=0 ;; esac
  if ! fm_refill_count_below_target "$live" "$floor"; then
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    rm -f "$(fm_refill_floor_needed_marker "$state")" 2>/dev/null || true
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  payload="check: refill floor: live ships $live below target $floor; run normal claim-and-dispatch (tasks-axi ready, date gates, exclusions, held and parked); do not blind-spawn$(fm_refill_handled_suffix)$(fm_refill_hold_suffix "$state")"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  fm_refill_mark_needed "$(fm_refill_floor_needed_marker "$state")" || {
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  }
  existing=$(fm_refill_queue_payload_locked refill-floor 2>/dev/null || true)
  if [ -n "$existing" ]; then
    FM_REFILL_REASON=$existing
  elif fm_wake_append_locked check refill-floor "$payload"; then
    FM_REFILL_REASON=$payload
    status=0
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return "$status"
}

fm_refill_emit_completion() {
  local id=$1 marker key payload existing marker_state status=1
  FM_REFILL_REASON=
  fm_refill_task_id_valid "$id" || return 1
  marker=$(fm_refill_completion_marker "$id")
  key="refill:$id"
  payload="check: refill completion $id: run normal claim-and-dispatch (tasks-axi ready, date gates, exclusions, held and parked); do not blind-spawn$(fm_refill_handled_suffix)$(fm_refill_hold_suffix "$STATE")"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  marker_state=$(fm_refill_marker_state "$marker")
  if [ "$marker_state" = committed ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    fm_refill_emit_floor_if_needed >/dev/null 2>&1 || true
    return 1
  fi
  if [ "$marker_state" = absent ]; then
    fm_refill_atomic_write "$marker" "pending $(date +%s)" || {
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    }
  fi
  fm_refill_mark_needed "$(fm_refill_completion_needed_marker)" || {
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  }
  if [ "${FM_REFILL_TEST_STOP_AFTER_PENDING:-0}" = 1 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 75
  fi
  existing=$(fm_refill_queue_payload_locked "$key" 2>/dev/null || true)
  if [ -n "$existing" ]; then
    fm_refill_commit_completion_marker "$id" || {
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    }
    FM_REFILL_REASON=$existing
  elif fm_wake_append_locked check "$key" "$payload"; then
    fm_refill_commit_completion_marker "$id" || {
      fm_lock_release "$FM_WAKE_QUEUE_LOCK"
      return 1
    }
    FM_REFILL_REASON=$payload
    status=0
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fm_refill_emit_floor_if_needed >/dev/null 2>&1 || true
  [ "$status" -ne 0 ] || FM_REFILL_REASON=$payload
  return "$status"
}

fm_refill_pending_marker_exists() {
  local state=${1:-$STATE} marker id
  [ -f "$(fm_refill_completion_needed_marker "$state")" ] && return 0
  [ -f "$(fm_refill_floor_needed_marker "$state")" ] && return 0
  shopt -s nullglob
  for marker in "$state"/.refill-completion-*; do
    [ "$(fm_refill_marker_state "$marker")" = pending ] || continue
    id=${marker##*/.refill-completion-}
    fm_refill_task_id_valid "$id" || continue
    shopt -u nullglob
    return 0
  done
  shopt -u nullglob
  return 1
}

fm_refill_supervision_needed() {
  local state=${1:-$STATE} config=${2:-$FM_REFILL_CONFIG} floor live
  fm_refill_queue_any_payload_locked "$state/.wake-queue" >/dev/null 2>&1 && return 0
  fm_refill_pending_marker_exists "$state" && return 0
  floor=$(fm_refill_concurrency_floor "$config")
  case "$floor" in ''|0|*[!0-9]*) return 1 ;; esac
  live=$(fm_refill_live_ship_count "$state")
  case "$live" in ''|*[!0-9]*) live=0 ;; esac
  fm_refill_count_below_target "$live" "$floor"
}

fm_refill_surface_pending_if_needed() {
  local payload existing
  FM_REFILL_REASON=
  fm_refill_recover_pending_completions "$STATE"
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  existing=$(fm_refill_queue_any_payload_locked 2>/dev/null || true)
  if [ -n "$existing" ]; then
    FM_REFILL_REASON=$existing
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  if ! fm_refill_pending_marker_exists "$STATE"; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 1
  fi
  payload="check: refill pending: run normal claim-and-dispatch (tasks-axi ready, date gates, exclusions, held and parked); do not blind-spawn$(fm_refill_handled_suffix)$(fm_refill_hold_suffix "$STATE")"
  if fm_wake_append_locked check refill-pending "$payload"; then
    FM_REFILL_REASON=$payload
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
    return 0
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  return 1
}

fm_refill_emit_pending_if_needed() {
  fm_refill_emit_floor_if_needed >/dev/null 2>&1 || true
  fm_refill_surface_pending_if_needed
}

fm_refill_dispatch_cycle_completed() {
  local state=${1:-$STATE} config=${2:-$FM_REFILL_CONFIG}
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
  rm -f "$(fm_refill_completion_needed_marker "$state")" 2>/dev/null || true
  fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fm_refill_emit_floor_if_needed "$state" "$config" >/dev/null 2>&1 || true
}
