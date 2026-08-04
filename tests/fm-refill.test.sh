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
WATCH="$ROOT/bin/fm-watch.sh"
REFILL_COMPLETE="$ROOT/bin/fm-refill-complete.sh"
TMP_ROOT=$(fm_test_tmproot fm-refill-tests)

make_refill_home() {
  local name=$1 dir
  dir=$(make_case "$name")
  mkdir -p "$dir/config" "$dir/state" "$dir/data"
  cat > "$dir/fake-crew-state" <<'SH'
#!/usr/bin/env bash
cat "$FM_STATE_OVERRIDE/$1.current" 2>/dev/null || printf 'state: unknown · source: none · fixture\n'
SH
  chmod +x "$dir/fake-crew-state"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = display-message ]; then
  target=
  while [ "$#" -gt 0 ]; do
    if [ "$1" = -t ]; then
      target=${2:-}
      break
    fi
    shift
  done
  [ -n "$target" ] || exit 1
  [ "$target" != "${FM_REFILL_DEAD_TARGET:-}" ] || exit 1
  case "$*" in
    *pane_current_command*)
      if [ "$target" = "${FM_REFILL_DEAD_AGENT_TARGET:-}" ]; then
        printf 'zsh\n'
      else
        printf 'codex\n'
      fi
      exit 0
      ;;
  esac
  printf '%%1\n'
  exit 0
fi
if [ "${1:-}" = list-windows ]; then
  [ -n "${FM_REFILL_TMUX_WINDOWS:-}" ] && printf '%s\n' "$FM_REFILL_TMUX_WINDOWS"
  exit 0
fi
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

source_refill() {
  local home=$1
  # shellcheck disable=SC1090,SC1091
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$home/fake-crew-state" \
    FM_REFILL_DEAD_TARGET="${FM_REFILL_DEAD_TARGET:-}" \
    FM_REFILL_DEAD_AGENT_TARGET="${FM_REFILL_DEAD_AGENT_TARGET:-}" \
    FM_REFILL_TMUX_WINDOWS="${FM_REFILL_TMUX_WINDOWS:-}" \
    FM_REFILL_TEST_STOP_AFTER_PENDING="${FM_REFILL_TEST_STOP_AFTER_PENDING:-0}" \
    PATH="$home/fakebin:$PATH" \
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
  grep -F 'bin/fm-refill-complete.sh <no-ready|no-eligible|held-only>' \
    "$state/.wake-queue" >/dev/null \
    || fail "wake payload must carry the handled empty-cycle boundary"
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
  source_refill "$home" fm_refill_supervision_needed \
    || fail "drained completion must remain a supervision need until dispatch"
  source_refill "$home" fm_refill_dispatch_cycle_completed
  source_refill "$home" fm_refill_supervision_needed \
    && fail "successful dispatch cycle must clear completion supervision need" || true
  pass "completion refill signal is durable and survives restart re-fire"
}

test_crash_after_pending_claim_recovers_on_retry() {
  local home state n
  home=$(make_refill_home completion-crash)
  state="$home/state"

  FM_REFILL_TEST_STOP_AFTER_PENDING=1 source_refill "$home" fm_refill_emit_completion task-crash
  [ "$?" -eq 75 ] || fail "crash seam must stop after durable pending claim"
  [ ! -s "$state/.wake-queue" ] || fail "crash seam must stop before queue append"
  grep -F 'pending ' "$state/.refill-completion-task-crash" >/dev/null \
    || fail "crash seam did not retain a pending receipt"
  source_refill "$home" fm_refill_supervision_needed \
    || fail "pending completion receipt must keep supervision active"

  source_refill "$home" fm_refill_emit_pending_if_needed \
    || fail "supervision surface must recover the missing completion wake"
  n=$(count_refill_keys "$state" "refill:task-crash")
  [ "$n" -eq 1 ] || fail "recovered completion must enqueue exactly one wake, got $n"
  grep -F 'committed ' "$state/.refill-completion-task-crash" >/dev/null \
    || fail "recovered completion receipt was not committed"
  source_refill "$home" fm_refill_emit_completion task-crash \
    && fail "committed completion must remain deduped" || true
  pass "pending completion crash recovers exactly one durable wake"
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

test_completion_also_evaluates_floor() {
  local home state
  home=$(make_refill_home completion-floor)
  state="$home/state"
  printf '2\n' > "$home/config/concurrency-floor"

  source_refill "$home" fm_refill_emit_completion task-floor \
    || fail "completion emit should succeed"
  [ "$(count_refill_keys "$state" refill-floor)" -eq 1 ] \
    || fail "completion did not independently evaluate the configured floor"
  pass "completion emission also evaluates the concurrency floor"
}

test_floor_below_target_emits_top_up() {
  local home state n live
  home=$(make_refill_home floor-below)
  state="$home/state"
  printf '2\n' > "$home/config/concurrency-floor"
  printf 'window=w1\nkind=ship\n' > "$state/ship-a.meta"
  printf 'state: working · source: pane · fixture\n' > "$state/ship-a.current"

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
  printf 'state: working · source: pane · fixture\n' > "$state/ship-a.current"
  printf 'state: working · source: pane · fixture\n' > "$state/ship-b.current"

  source_refill "$home" fm_refill_emit_floor_if_needed \
    && fail "floor at target must not emit" || true
  printf 'window=w3\nkind=ship\n' > "$state/ship-c.meta"
  printf 'state: working · source: pane · fixture\n' > "$state/ship-c.current"
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
  printf 'state: working · source: pane · fixture\n' > "$home/state/default-ship.current"
  live=$(source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "only default-kind ship should count, got $live"
  pass "live ship count excludes scout and secondmate meta"
}

test_parked_ship_meta_does_not_count_live() {
  local home live
  home=$(make_refill_home floor-parked)
  printf 'window=w1\nkind=ship\n' > "$home/state/active.meta"
  printf 'window=w2\nkind=ship\n' > "$home/state/parked.meta"
  printf 'state: working · source: pane · fixture\n' > "$home/state/active.current"
  printf 'state: parked · source: run-step · parked at review\n' > "$home/state/parked.current"
  live=$(source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "parked metadata inflated live capacity: $live"
  pass "parked ship metadata does not count as live capacity"
}

test_working_ship_with_dead_endpoint_does_not_count_live() {
  local home live
  home=$(make_refill_home floor-dead-endpoint)
  printf 'window=w-live\nkind=ship\n' > "$home/state/live.meta"
  printf 'window=w-dead\nkind=ship\n' > "$home/state/dead.meta"
  printf 'state: working · source: run-step · active run\n' > "$home/state/live.current"
  printf 'state: working · source: run-step · lingering active run\n' > "$home/state/dead.current"
  live=$(FM_REFILL_DEAD_TARGET=w-dead source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "dead endpoint inflated live capacity: $live"
  pass "live ship count requires working lifecycle and a present endpoint"
}

test_working_ship_with_dead_agent_does_not_count_live() {
  local home live windows
  home=$(make_refill_home floor-dead-agent)
  printf 'window=session:w-live\nkind=ship\n' > "$home/state/live.meta"
  printf 'window=session:w-dead\nkind=ship\n' > "$home/state/dead.meta"
  printf 'state: working · source: run-step · active run\n' > "$home/state/live.current"
  printf 'state: working · source: run-step · lingering active run\n' > "$home/state/dead.current"
  windows=$(printf 'w-live\nw-dead')
  live=$(FM_REFILL_DEAD_AGENT_TARGET=session:w-dead \
    FM_REFILL_TMUX_WINDOWS="$windows" \
    source_refill "$home" fm_refill_live_ship_count)
  [ "$live" = 1 ] || fail "dead agent with a surviving endpoint inflated live capacity: $live"
  pass "live ship count rejects a confirmed dead agent with a lingering run"
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
  printf 'window=w1\nkind=ship\nmode=local-only\nworktree=%s\n' "$wt" \
    > "$home/state/parked.meta"
  printf 'state: working · source: run-step · active run\n' \
    > "$home/state/parked.current"
  source_refill "$home" fm_refill_has_parked_unpushed \
    && fail "working unpushed ship must not report parked-work hazard" || true
  printf '3\n' > "$home/config/concurrency-floor"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    || fail "floor should emit while an unpushed ship is working"
  grep -F 'HOLD: parked ship worktree safety is not proven' \
    "$home/state/.wake-queue" >/dev/null \
    && fail "working unpushed ship must not hold floor top-up" || true
  : > "$home/state/.wake-queue"
  printf 'state: unknown · source: none · unreadable fixture\n' \
    > "$home/state/parked.current"
  source_refill "$home" fm_refill_has_parked_unpushed \
    || fail "unreadable ship lifecycle should fail closed"
  printf 'state: parked · source: run-step · parked at review\n' \
    > "$home/state/parked.current"
  source_refill "$home" fm_refill_has_parked_unpushed \
    || fail "parked unpushed ship should report hazard"
  source_refill "$home" fm_refill_emit_floor_if_needed \
    || fail "floor should still emit with HOLD note"
  grep -F 'HOLD: parked ship worktree safety is not proven' \
    "$home/state/.wake-queue" >/dev/null \
    || fail "floor payload must include parked-unpushed hold"
  pass "parked local-only unpushed work holds refill without blocking the signal"
}


test_running_watcher_surfaces_late_refill() {
  local home state out watcher_pid i
  home=$(make_refill_home watcher-late-refill)
  state="$home/state"
  out="$home/watcher.out"

  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CREW_STATE_BIN="$home/fake-crew-state" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" &
  watcher_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$state/.last-watcher-beat" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$state/.last-watcher-beat" ] || {
    kill "$watcher_pid" 2>/dev/null || true
    fail "watcher did not enter its cycle before late refill emit"
  }
  source_refill "$home" fm_refill_emit_completion late-task \
    || fail "late completion emit should succeed"
  wait_for_exit "$watcher_pid" 40 || {
    kill "$watcher_pid" 2>/dev/null || true
    fail "running watcher did not surface late refill"
  }
  grep -F 'check: refill completion late-task:' "$out" >/dev/null \
    || fail "running watcher omitted late completion reason: $(cat "$out")"
  pass "running watcher surfaces refill emitted after startup"
}

test_handled_empty_claim_cycle_clears_completion_need() {
  local home state out
  home=$(make_refill_home handled-no-ready)
  state="$home/state"

  source_refill "$home" fm_refill_emit_completion empty-task \
    || fail "completion emit should succeed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null \
    || fail "completion wake drain should succeed"
  [ -f "$state/.refill-needed-completion" ] \
    || fail "drained completion must remain pending before pickup handling"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    "$REFILL_COMPLETE" no-ready) \
    || fail "handled no-ready outcome should complete the refill cycle"
  [ "$out" = 'refill claim-and-dispatch cycle completed: no-ready' ] \
    || fail "unexpected refill completion output: $out"
  [ ! -e "$state/.refill-needed-completion" ] \
    || fail "handled no-ready outcome left completion need behind"
  source_refill "$home" fm_refill_surface_pending_if_needed \
    && fail "handled empty claim cycle must not enqueue refill-pending again" || true
  [ ! -s "$state/.wake-queue" ] \
    || fail "handled empty claim cycle re-enqueued a refill wake"
  pass "handled no-ready claim cycle clears completion supervision need"
}

test_unreadable_git_state_fails_closed_for_both_payloads() {
  local home wt fakebin
  home=$(make_refill_home parked-unknown)
  wt="$home/wt-ship"
  fakebin="$home/fakebin"
  mkdir -p "$wt" "$fakebin"
  printf 'window=w1\nkind=ship\nmode=no-mistakes\nworktree=%s\n' "$wt" \
    > "$home/state/unknown.meta"
  printf 'state: parked · source: run-step · parked at review\n' > "$home/state/unknown.current"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/git"

  PATH="$fakebin:$PATH" source_refill "$home" fm_refill_has_parked_unpushed \
    || fail "failed git read must report a hold hazard"
  printf '2\n' > "$home/config/concurrency-floor"
  PATH="$fakebin:$PATH" source_refill "$home" fm_refill_emit_floor_if_needed \
    || fail "floor should emit with unreadable git HOLD"
  PATH="$fakebin:$PATH" source_refill "$home" fm_refill_emit_completion unknown \
    || fail "completion should emit with unreadable git HOLD"
  [ "$(grep -c 'HOLD: parked ship worktree safety is not proven' "$home/state/.wake-queue")" -eq 2 ] \
    || fail "both floor and completion payloads must carry fail-closed HOLD"
  pass "unreadable git state fails closed in every refill payload"
}

test_empty_home_floor_is_explicit_supervision_need() {
  local home state out
  home=$(make_refill_home empty-home)
  state="$home/state"
  printf '2\n' > "$home/config/concurrency-floor"

  source_refill "$home" fm_refill_supervision_needed \
    || fail "zero-meta home below configured floor must need supervision"
  source_refill "$home" fm_refill_emit_pending_if_needed \
    || fail "zero-meta home below floor must surface a refill wake"
  [ "$(count_refill_keys "$state" refill-floor)" -eq 1 ] \
    || fail "zero-meta floor did not enqueue its refill wake"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$home/fake-crew-state" bash -c '
      . "$1"
      fm_supervision_needed "$2" 300
      printf "%s %s\n" "$FM_SUP_NEEDED" "$FM_SUP_REFILL_NEEDED"
    ' _ "$ROOT/bin/fm-supervision-lib.sh" "$state") \
    || fail "shared supervision predicate rejected zero-meta refill need"
  [ "$out" = "true true" ] || fail "shared supervision flags did not own refill need: $out"
  pass "empty home below floor remains supervision-active and surfaces refill"
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
test_crash_after_pending_claim_recovers_on_retry
test_distinct_tasks_each_get_one_signal
test_completion_also_evaluates_floor
test_floor_below_target_emits_top_up
test_floor_at_or_above_target_silent
test_absent_config_floor_off
test_scouts_and_secondmates_do_not_count_as_live_ships
test_parked_ship_meta_does_not_count_live
test_working_ship_with_dead_endpoint_does_not_count_live
test_working_ship_with_dead_agent_does_not_count_live
test_parked_unpushed_probe
test_unreadable_git_state_fails_closed_for_both_payloads
test_empty_home_floor_is_explicit_supervision_need
test_running_watcher_surfaces_late_refill
test_handled_empty_claim_cycle_clears_completion_need
test_invalid_task_id_refused
