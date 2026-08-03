#!/usr/bin/env bash
# Shared completion-triggered refill and concurrency-floor signalling.
#
# OWNERSHIP: this library is the single owner of:
#   - durable completion-refill wakes (kind=check, key=refill:<task-id>)
#   - concurrency-floor top-up wakes (kind=check, key=refill-floor)
#   - per-task completion idempotence markers (state/.refill-completion-<id>)
#   - config/concurrency-floor parsing
#   - the pre-lease parked-unpushed hazard probe used before top-up dispatch
#
# PROBLEM: continuous refill was a rule the supervising agent had to remember
# mid-turn. Long single turns that landed work never reached claim-next, so the
# queue starved. Completion events already existed (merge-poll wake, teardown
# backlog reminder) but neither emitted a durable signal the agent must act on.
#
# CONTRACT:
#   - Emits durable wake-queue records only. Never spawns, claims, or edits the
#     backlog. The supervising agent still runs the normal claim-and-dispatch
#     procedure (verify-at-pickup, atomic claim, exclusions, held/parked).
#   - Completion emit is idempotent per task id: a second delivery of the same
#     completion event (merge re-fire, teardown retry, afk re-escalation) does
#     not enqueue a second refill wake.
#   - Floor emit is independent of completion: when live ship count is below
#     config/concurrency-floor, one top-up wake is enqueued (wake-queue key
#     dedupe collapses duplicates still pending). Absent/0/invalid config = off.
#   - Until ship worktree leases land (fix-lease-ship-worktrees), dispatch must
#     hold while any live ship worktree has unpushed commits; this library only
#     probes that hazard and never reimplements pool leasing.
#
# Usage (source from bin/ scripts):
#   . "$SCRIPT_DIR/fm-refill-lib.sh"
#   fm_refill_emit_completion <task-id>   # 0 if newly emitted, 1 if deduped/skip
#   fm_refill_emit_floor_if_needed        # 0 if newly emitted, 1 if no top-up
#   fm_refill_concurrency_floor           # prints non-negative integer target
#   fm_refill_live_ship_count             # prints current live ship meta count
#   fm_refill_has_parked_unpushed         # 0 when hazard present, 1 when clear
#
# FM_REFILL_REASON is set to the wake payload when an emit returns 0.

_FM_REFILL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$_FM_REFILL_LIB_DIR/fm-wake-lib.sh"

# Prefer the caller's FM_CONFIG_OVERRIDE; otherwise the home's config dir.
# wake-lib already resolved FM_HOME/STATE for this process.
FM_REFILL_CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Set to the wake payload when an emit returns 0; callers (fm-watch.sh) read it.
# shellcheck disable=SC2034 # External consumer reads this after a successful emit.
FM_REFILL_REASON=

fm_refill_task_id_valid() {
  local id=$1
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 64 ]
}

# Print the configured concurrency floor (live ships target). Absent file,
# unreadable path, symlink, empty, zero, or non-digits → 0 (feature off).
fm_refill_concurrency_floor() {
  local f line
  f="$FM_REFILL_CONFIG/concurrency-floor"
  if [ ! -f "$f" ] || [ -L "$f" ]; then
    printf '0\n'
    return 0
  fi
  line=$(head -n 1 "$f" 2>/dev/null | tr -d '[:space:]') || line=
  case "$line" in
    ''|0|*[!0-9]*)
      printf '0\n'
      ;;
    *)
      printf '%s\n' "$line"
      ;;
  esac
}

# Count live ship workers from state/<id>.meta. Missing kind defaults to ship
# (spawn's historical default). Scouts and secondmates do not count.
fm_refill_live_ship_count() {
  local meta id kind n=0
  shopt -s nullglob
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_refill_task_id_valid "$id" || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    case "$kind" in
      ship) n=$((n + 1)) ;;
    esac
  done
  shopt -u nullglob
  printf '%s\n' "$n"
}

# 0 when any live ship worktree still has commits not on any remote (the
# pre-lease pool-recycle hazard). local-only ships are excluded: they land via
# local main rather than a remote push. Returns 1 when clear or unreadable.
# Coordinate with fix-lease-ship-worktrees: once ship worktrees are leased, the
# supervising agent can stop treating this probe as a hard hold.
fm_refill_has_parked_unpushed() {
  local meta id kind mode wt unpushed
  shopt -s nullglob
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    fm_refill_task_id_valid "$id" || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || continue
    mode=$(grep '^mode=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$mode" ] || mode=no-mistakes
    [ "$mode" != local-only ] || continue
    wt=$(grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$wt" ] && [ -d "$wt" ] || continue
    unpushed=$(git -C "$wt" log --oneline HEAD --not --remotes -- 2>/dev/null) || continue
    if [ -n "$unpushed" ]; then
      shopt -u nullglob
      return 0
    fi
  done
  shopt -u nullglob
  return 1
}

fm_refill_completion_marker() {
  local id=$1
  printf '%s/.refill-completion-%s\n' "$STATE" "$id"
}

# Claim exclusive right to emit one completion refill for <task-id>.
# Uses noclobber create so concurrent and re-fired deliveries race safely.
# Returns 0 on fresh claim, 1 if already claimed or id invalid.
fm_refill_claim_completion() {
  local id=$1 marker
  fm_refill_task_id_valid "$id" || return 1
  marker=$(fm_refill_completion_marker "$id")
  mkdir -p "$STATE" || return 1
  if (
    set -C
    umask 077
    : >"$marker"
  ) 2>/dev/null; then
    printf '%s\n' "$(date +%s)" >"$marker" || true
    return 0
  fi
  return 1
}

fm_refill_release_completion_claim() {
  local id=$1 marker
  fm_refill_task_id_valid "$id" || return 0
  marker=$(fm_refill_completion_marker "$id")
  rm -f -- "$marker" 2>/dev/null || true
}

# Emit one durable completion-refill wake for <task-id>.
# Idempotent: a second call for the same id is a no-op (return 1).
# Does not spawn. On success sets FM_REFILL_REASON and returns 0.
fm_refill_emit_completion() {
  local id=$1 key payload
  # shellcheck disable=SC2034 # Cleared for callers that read FM_REFILL_REASON after emit.
  FM_REFILL_REASON=
  fm_refill_task_id_valid "$id" || return 1
  fm_refill_claim_completion "$id" || return 1
  key="refill:$id"
  payload="check: refill completion $id: run normal claim-and-dispatch (tasks-axi ready, date gates, exclusions, held and parked); do not blind-spawn"
  if ! fm_wake_append check "$key" "$payload"; then
    fm_refill_release_completion_claim "$id"
    return 1
  fi
  # shellcheck disable=SC2034 # Public result consumed by fm-watch.sh after a successful emit.
  FM_REFILL_REASON=$payload
  return 0
}

# Emit one durable floor top-up wake when live ships are below the configured
# target. Absent/zero floor → no-op. At or above target → no-op. Pending queue
# key refill-floor collapses duplicates until drained; a later drop below the
# floor after drain can emit again (independent safety net).
# Returns 0 when newly enqueued, 1 when no top-up is needed or enqueue fails.
fm_refill_emit_floor_if_needed() {
  local floor live payload
  # shellcheck disable=SC2034 # Cleared for callers that read FM_REFILL_REASON after emit.
  FM_REFILL_REASON=
  floor=$(fm_refill_concurrency_floor)
  case "$floor" in
    ''|0|*[!0-9]*) return 1 ;;
  esac
  live=$(fm_refill_live_ship_count)
  case "$live" in
    ''|*[!0-9]*) live=0 ;;
  esac
  [ "$live" -lt "$floor" ] || return 1
  payload="check: refill floor: live ships $live below target $floor; run normal claim-and-dispatch (tasks-axi ready, date gates, exclusions, held and parked); do not blind-spawn"
  if fm_refill_has_parked_unpushed; then
    payload="$payload; HOLD: parked ship worktree has unpushed commits - do not pool-dispatch until leases protect ship worktrees or unpushed work is cleared"
  fi
  fm_wake_append check refill-floor "$payload" || return 1
  # shellcheck disable=SC2034 # Public result consumed by fm-watch.sh after a successful emit.
  FM_REFILL_REASON=$payload
  return 0
}
