#!/usr/bin/env bash
# tests/fm-refill.test.sh - completion-triggered refill and concurrency-floor
# guarantees: idempotent per-task completion emit, durable wake survival, floor
# below/at/above target, absent config = off, and no blind spawn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-refill-tests)

make_refill_home() {
  local name=$1 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/config" "$dir/state" "$dir/data"
  printf '%s\n' "$dir"
}

source_refill() {
  local home=$1
  # shellcheck disable=SC1090,SC1091
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    bash -c '
      set -e
      . "$1"
      shift
      "$@"
    ' _ "$ROOT/bin/fm-refill-lib.sh" "${@:2}"
}

queue_refill_rows() {
  local state=$1
  awk -F '\t' '$3 == "check" && $4 ~ /^refill/ { print }' "$state/.wake-queue" 2>/dev/null || true
}

count_refill_keys() {
  local state=$1 key=$2
  awk -F '\t' -v k="$key" '$3 == "check" && $4 == k { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || printf '0\n'
}

test_completion_double_fire_emits_once() {
  local home state n marker
  home=$(make_refill_home completion-once)
  state="$home/state"

  source_refill "$home" fm_refill_emit_completion task-a \
    || fail "first completion emit should succeed"
  source_refill "$home" fm_refill_emit_completion task-a \
    && fail "second completion emit for same id must be a no-op" || true

  n=$(count_refill_keys "$state" "refill:task-a")
  [ "$n" -eq 1 ] || fail "expected exactly one refill:task-a wake, got $n"
  marker="$state/.refill-completion-task-a"
  [ -f "$marker" ] || fail "completion marker missing after emit"
  grep -F 'check: refill completion task-a:' "$state/.wake-queue" >/dev/null \
    || fail "wake payload missing completion claim-next instruction"
  grep -F 'do not blind-spawn' "$state/.wake-queue" >/dev/null \
    || fail "wake payload must forbid blind-spawn"
  pass "double completion delivery produces exactly one refill signal"
}

test_completion_signal_is_durable_across_restart() {
  local home state drain_out n
  home=$(make_refill_home completion-durable)
  state="$home/state"

  source_refill "$home" fm_refill_emit_completion task-b \
    || fail "completion emit should succeed"
  # Simulate a process restart: re-source the lib and assert the queue still
  # holds the wake without a second emission for the same task.
  source_refill "$home" fm_refill_emit_completion task-b \
    && fail "restart re-fire must remain deduped" || true
  n=$(count_refill_keys "$state" "refill:task-b")
  [ "$n" -eq 1 ] || fail "queue must still hold exactly one durable refill after restart re-fire, got $n"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$home/drain.out" \
    || fail "drain of durable refill failed"
  drain_out=$(cat "$home/drain.out")
  printf '%s\n' "$drain_out" | grep -F $'\tcheck\trefill:task-b\t' >/dev/null \
    || fail "drained rows missing durable refill:task-b wake: $drain_out"
  [ ! -s "$state/.wake-queue" ] || fail "queue should be empty after drain"
  pass "completion refill signal is durable and survives restart re-fire"
}

test_distinct_tasks_each_get_one_signal() {
  local home state n
  home=$(make_refill_home completion-distinct)
  state="$home/state"

  source_refill "$home" fm_refill_emit_completion task-one || fail "emit one"
  source_refill "$home" fm_refill_emit_completion task-two || fail "emit two"
  n=$(awk -F '\t' '$3 == "check" && $4 ~ /^refill:/ { n++ } END { print n + 0 }' \
    "$state/.wake-queue")
  [ "$n" -eq 2 ] || fail "expected two distinct completion refills, got $n"
  pass "distinct completed tasks each produce one refill signal"
}

test_floor_below_target_emits_top_up() {
  local home state n live
  home=$(make_refill_home floor-below)
  state="$home/state"
  printf '2\n' > "$home/config/concurrency-floor"
  printf 'window=w1\nkind=ship\n' > "$state/ship-a.meta"

  source_refill "$home" fm_refill_emit_floor_if_needed \
    || fail "floor below target should emit"
  n=$(count_refill_keys "$state" refill-floor)
  [ "$n" -eq 1 ] || fail "expected one refill-floor wake, got $n"
  grep -F 'live ships 1 below target 2' "$state/.wake-queue" >/dev/null \
    || fail "floor payload missing live/target counts"
  live=$(source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "live ship count should be 1, got $live"
  pass "floor emits top-up when live ships are below target"
}

test_floor_at_or_above_target_silent() {
  local home state n
  home=$(make_refill_home floor-met)
  state="$home/state"
  printf '2\n' > "$home/config/concurrency-floor"
  printf 'window=w1\nkind=ship\n' > "$state/ship-a.meta"
  printf 'window=w2\nkind=ship\n' > "$state/ship-b.meta"

  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "floor at target must not emit" || true
  printf 'window=w3\nkind=ship\n' > "$state/ship-c.meta"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "floor above target must not emit" || true
  n=$(count_refill_keys "$state" refill-floor)
  [ "$n" -eq 0 ] || fail "expected no floor wake when at/above target, got $n"
  pass "floor is silent when live ships are at or above target"
}

test_absent_config_floor_off() {
  local home state n floor
  home=$(make_refill_home floor-absent)
  state="$home/state"
  # No config/concurrency-floor file. Zero ships would be below any positive
  # target, but absent config must keep the feature off.
  floor=$(source_refill "$home" fm_refill_concurrency_floor)
  [ "$floor" = 0 ] || fail "absent config must parse as 0, got $floor"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "absent config must not emit floor top-up" || true
  printf '0\n' > "$home/config/concurrency-floor"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "zero floor must not emit" || true
  printf 'nope\n' > "$home/config/concurrency-floor"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "invalid floor must not emit" || true
  n=$(count_refill_keys "$state" refill-floor)
  [ "$n" -eq 0 ] || fail "expected no floor wakes for safe-absent config, got $n"
  pass "absent/zero/invalid concurrency-floor is feature-off"
}

test_scouts_and_secondmates_do_not_count_as_live_ships() {
  local home live
  home=$(make_refill_home floor-kinds)
  printf 'window=w1\nkind=scout\n' > "$home/state/scout-a.meta"
  printf 'window=w2\nkind=secondmate\n' > "$home/state/sm-a.meta"
  printf 'window=w3\n' > "$home/state/default-ship.meta" # missing kind = ship
  live=$(source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "only default-kind ship should count, got $live"
  pass "live ship count excludes scout and secondmate meta"
}

test_parked_unpushed_probe() {
  local home wt
  home=$(make_refill_home parked-probe)
  wt="$home/wt-ship"
  mkdir -p "$wt"
  git -C "$wt" init -q
  git -C "$wt" config user.email "t@example.com"
  git -C "$wt" config user.name "t"
  printf 'x\n' > "$wt/f"
  git -C "$wt" add f
  git -C "$wt" commit -qm init
  # No remotes → HEAD --not --remotes lists the commit as unpushed.
  printf 'window=w1\nkind=ship\nmode=no-mistakes\nworktree=%s\n' "$wt" \
    > "$home/state/parked.meta"
  source_refill "$home" fm_refill_has_parked_unpushed \
    || fail "parked unpushed ship should report hazard"
  printf '3\n' > "$home/config/concurrency-floor"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    || fail "floor should still emit with HOLD note"
  grep -F 'HOLD: parked ship worktree has unpushed commits' \
    "$home/state/.wake-queue" >/dev/null \
    || fail "floor payload must include parked-unpushed hold"
  pass "parked unpushed probe holds floor payload without blocking the signal"
}

test_invalid_task_id_refused() {
  local home
  home=$(make_refill_home bad-id)
  source_refill "$home" fm_refill_emit_completion '../escape' \
    && fail "path-like id must be refused" || true
  source_refill "$home" fm_refill_emit_completion '' \
    && fail "empty id must be refused" || true
  [ ! -e "$home/state/.wake-queue" ] || [ ! -s "$home/state/.wake-queue" ] \
    || fail "invalid ids must not write wakes"
  pass "invalid task ids are refused without enqueue"
}

test_completion_double_fire_emits_once
test_completion_signal_is_durable_across_restart
test_distinct_tasks_each_get_one_signal
test_floor_below_target_emits_top_up
test_floor_at_or_above_target_silent
test_absent_config_floor_off
test_scouts_and_secondmates_do_not_count_as_live_ships
test_parked_unpushed_probe
test_invalid_task_id_refused
