#!/usr/bin/env bash
# Behavior tests for durable treehouse leases on ship/scout worktrees.
#
# Regression for kunchenguid/firstmate#1441: plain `treehouse get` only marks a
# slot in-use while a process holds it, so a parked task's worktree with unpushed
# commits still counted as available and could be handed to the next spawn.
# Spawn now leases with --lease --lease-holder <task-id>, then cds the worker
# into the leased path. Teardown releases the lease only via a successful
# `treehouse return` - a REFUSED teardown never reaches return.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# Lease markers live under $pool/.leases/<slot-name>, never inside the git
# worktree itself (an in-tree marker would look like uncommitted work to teardown).
make_lease_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TREEHOUSE_LOG:-/dev/null}
printf 'treehouse %s\n' "$*" >> "$log"
lease_file() {
  local slot=$1 pool base
  pool=${FM_FAKE_TREEHOUSE_POOL:?}
  base=$(basename "$slot")
  printf '%s\n' "$pool/.leases/$base"
}
case "${1:-}" in
  get)
    shift
    has_lease=0
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) has_lease=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift || true
    done
    pool=${FM_FAKE_TREEHOUSE_POOL:?}
    mkdir -p "$pool/.leases"
    if [ "$has_lease" -eq 1 ]; then
      i=1
      while [ "$i" -le 32 ]; do
        slot="$pool/slot-$i"
        lf=$(lease_file "$slot")
        if [ -d "$slot" ] && [ ! -e "$lf" ]; then
          printf '%s\n' "${holder:-}" > "$lf"
          printf '%s\n' "$slot"
          exit 0
        fi
        i=$((i + 1))
      done
      echo "error: fake pool exhausted" >&2
      exit 1
    fi
    # Plain get: first unleased slot only (proves leased slots are skipped).
    i=1
    while [ "$i" -le 32 ]; do
      slot="$pool/slot-$i"
      lf=$(lease_file "$slot")
      if [ -d "$slot" ] && [ ! -e "$lf" ]; then
        printf '%s\n' "$slot"
        exit 0
      fi
      i=$((i + 1))
    done
    exit 0
    ;;
  return)
    shift
    target=
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        --if-lease-holder) shift; holder=${1:-} ;;
        --if-lease-holder=*) holder=${1#--if-lease-holder=} ;;
        *) target=$1 ;;
      esac
      shift || true
    done
    [ -n "$target" ] || exit 1
    pool=${FM_FAKE_TREEHOUSE_POOL:?}
    mkdir -p "$pool/.leases"
    lf=$(lease_file "$target")
    if [ -n "$holder" ]; then
      [ -f "$lf" ] || exit 1
      [ "$(cat "$lf")" = "$holder" ] || exit 1
    fi
    rm -f -- "$lf"
    exit 0
    ;;
esac
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_home_case() {
  local name=$1 case_dir home proj pool fakebin log
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  pool="$case_dir/pool"
  log="$case_dir/treehouse.log"
  fakebin=$(make_lease_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$pool/.leases"
  printf 'codex\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$proj"
  git -C "$proj" worktree add -q --detach "$pool/slot-1" >/dev/null 2>&1
  git -C "$proj" worktree add -q --detach "$pool/slot-2" >/dev/null 2>&1
  : > "$log"
  printf '%s\n' "$case_dir|$home|$proj|$pool|$fakebin|$log"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR POOL_DIR FAKEBIN_DIR TH_LOG <<EOF
$1
EOF
}

prepare_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
}

next_free_slot() {
  local pool=$1 i=1
  while [ "$i" -le 32 ]; do
    if [ -d "$pool/slot-$i" ] && [ ! -e "$pool/.leases/slot-$i" ]; then
      printf '%s\n' "$pool/slot-$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

slot_leased() {
  local pool=$1 slot=$2
  [ -f "$pool/.leases/$(basename "$slot")" ]
}

run_spawn_pool() {
  local home=$1 proj=$2 fakebin=$3 log=$4 pool=$5 id=$6 pane=$7
  prepare_brief "$home" "$id"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_POOL="$pool" \
    FM_FAKE_TREEHOUSE_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1
}

run_teardown() {
  local home=$1 fakebin=$2 log=$3 pool=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_FAKE_TREEHOUSE_POOL="$pool" \
    FM_FAKE_TREEHOUSE_LOG="$log" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

write_ship_meta() {
  local home=$1 id=$2 wt=$3 proj=$4 mode=$5
  {
    echo "window=firstmate:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=codex"
    echo "kind=ship"
    echo "mode=$mode"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
  } > "$home/state/$id.meta"
}

# --- 1. Lease holds the slot: plain get must not return the leased path ------

test_lease_excludes_slot_from_plain_get() {
  local rec slot out status plain
  rec=$(make_home_case lease-excludes)
  read_case "$rec"
  slot=$(next_free_slot "$POOL_DIR")

  out=$(run_spawn_pool "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" \
    lease-hold-a1 "$slot")
  status=$?
  expect_code 0 "$status" "spawn should succeed while leasing"$'\n'"$out"
  assert_contains "$out" "spawned lease-hold-a1" "spawn did not report success"
  assert_grep "worktree=$slot" "$HOME_DIR/state/lease-hold-a1.meta" \
    "meta did not record the leased worktree"
  slot_leased "$POOL_DIR" "$slot" || fail "spawn did not leave a durable lease on the slot"
  [ "$(cat "$POOL_DIR/.leases/$(basename "$slot")")" = lease-hold-a1 ] \
    || fail "lease holder is not the task id"
  grep -F "treehouse get --lease --lease-holder lease-hold-a1" "$TH_LOG" >/dev/null \
    || fail "spawn did not call treehouse get --lease --lease-holder <task-id>"

  plain=$(FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" PATH="$FAKEBIN_DIR:$PATH" treehouse get)
  [ "$plain" != "$slot" ] || fail "plain treehouse get returned the still-leased path"
  [ -n "$plain" ] || fail "plain treehouse get found no free slot (expected the other pool slot)"
  [ "$plain" = "$POOL_DIR/slot-2" ] || fail "plain get should hand out the unleased slot-2, got '$plain'"

  pass "spawn leases the slot; subsequent plain treehouse get does not return it"
}

# --- 2. Successful teardown releases the lease --------------------------------

test_successful_teardown_releases_lease() {
  local rec slot out status
  rec=$(make_home_case teardown-release)
  read_case "$rec"
  slot=$(next_free_slot "$POOL_DIR")

  out=$(run_spawn_pool "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" \
    lease-td-ok-b2 "$slot")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  slot_leased "$POOL_DIR" "$slot" || fail "lease missing after spawn"

  # Clean detached worktree at main with no unique commits: local-only allows it.
  write_ship_meta "$HOME_DIR" lease-td-ok-b2 "$slot" "$PROJ_DIR" local-only

  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" lease-td-ok-b2)
  status=$?
  expect_code 0 "$status" "successful teardown should complete"$'\n'"$out"
  slot_leased "$POOL_DIR" "$slot" && fail "successful teardown left the lease held"
  grep -F "treehouse return --force $slot" "$TH_LOG" >/dev/null \
    || fail "teardown did not return the worktree through treehouse"
  pass "successful teardown releases the durable lease"
}

# --- 3. REFUSED teardown leaves the lease held --------------------------------

test_refused_teardown_keeps_lease() {
  local rec slot out status
  rec=$(make_home_case teardown-refuse)
  read_case "$rec"
  slot=$(next_free_slot "$POOL_DIR")

  out=$(run_spawn_pool "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" \
    lease-td-no-c3 "$slot")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  slot_leased "$POOL_DIR" "$slot" || fail "lease missing after spawn"

  # Truly unlanded work so teardown REFUSES before treehouse return.
  printf 'unlanded\n' > "$slot/unlanded.txt"
  git -C "$slot" add unlanded.txt
  git -C "$slot" commit -q -m 'unlanded ship work'
  write_ship_meta "$HOME_DIR" lease-td-no-c3 "$slot" "$PROJ_DIR" no-mistakes

  : > "$TH_LOG"
  out=$(run_teardown "$HOME_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" lease-td-no-c3)
  status=$?
  [ "$status" -ne 0 ] || fail "teardown should refuse unlanded work"$'\n'"$out"
  assert_contains "$out" "REFUSED" "teardown did not report REFUSED"
  slot_leased "$POOL_DIR" "$slot" || fail "REFUSED teardown released the lease (must keep it)"
  grep -F "treehouse return" "$TH_LOG" >/dev/null \
    && fail "REFUSED teardown must not call treehouse return"
  [ -e "$HOME_DIR/state/lease-td-no-c3.meta" ] || fail "REFUSED teardown cleared meta"
  pass "REFUSED teardown leaves the durable lease held"
}

# --- 4. Concurrent distinct-task spawns both succeed --------------------------

test_concurrent_distinct_spawns_both_succeed() {
  local rec out1 out2 status1 status2
  rec=$(make_home_case concurrent-mapped)
  read_case "$rec"

  # Holder-bound slots so each concurrent spawn's leased path matches its pane
  # cwd without depending on allocation order races.
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf 'treehouse %s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
case "${1:-}" in
  get)
    shift
    has_lease=0
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) has_lease=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
      esac
      shift || true
    done
    pool=${FM_FAKE_TREEHOUSE_POOL:?}
    mkdir -p "$pool/.leases"
    if [ "$has_lease" -eq 1 ]; then
      case "$holder" in
        conc-map-a6) slot="$pool/slot-1" ;;
        conc-map-b7) slot="$pool/slot-2" ;;
        *) echo "error: unknown holder $holder" >&2; exit 1 ;;
      esac
      printf '%s\n' "$holder" > "$pool/.leases/$(basename "$slot")"
      printf '%s\n' "$slot"
      exit 0
    fi
    exit 0
    ;;
  return) exit 0 ;;
esac
exit 0
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
  prepare_brief "$HOME_DIR" conc-map-a6
  prepare_brief "$HOME_DIR" conc-map-b7

  (
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL_DIR/slot-1" TMUX="fake,1,0" \
      FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" FM_FAKE_TREEHOUSE_LOG="$TH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" conc-map-a6 "$PROJ_DIR" >"$CASE_DIR/out-a" 2>&1
    echo $? >"$CASE_DIR/rc-a"
  ) &
  pid_a=$!
  (
    FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$POOL_DIR/slot-2" TMUX="fake,1,0" \
      FM_FAKE_TREEHOUSE_POOL="$POOL_DIR" FM_FAKE_TREEHOUSE_LOG="$TH_LOG" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" conc-map-b7 "$PROJ_DIR" >"$CASE_DIR/out-b" 2>&1
    echo $? >"$CASE_DIR/rc-b"
  ) &
  pid_b=$!
  wait "$pid_a" || true
  wait "$pid_b" || true
  status1=$(cat "$CASE_DIR/rc-a")
  status2=$(cat "$CASE_DIR/rc-b")
  out1=$(cat "$CASE_DIR/out-a")
  out2=$(cat "$CASE_DIR/out-b")
  expect_code 0 "$status1" "concurrent spawn A should succeed"$'\n'"$out1"
  expect_code 0 "$status2" "concurrent spawn B should succeed"$'\n'"$out2"
  assert_grep "worktree=$POOL_DIR/slot-1" "$HOME_DIR/state/conc-map-a6.meta" \
    "spawn A did not record its leased slot"
  assert_grep "worktree=$POOL_DIR/slot-2" "$HOME_DIR/state/conc-map-b7.meta" \
    "spawn B did not record its leased slot"
  slot_leased "$POOL_DIR" "$POOL_DIR/slot-1" || fail "spawn A missing lease"
  slot_leased "$POOL_DIR" "$POOL_DIR/slot-2" || fail "spawn B missing lease"
  pass "concurrent distinct-task spawns both succeed with distinct leased slots"
}

# --- 5. Failed spawn abort releases only its task-owned lease ----------------

test_aborted_spawn_releases_only_own_lease() {
  local rec out status other_lease own_lease
  rec=$(make_home_case abort-holder-scope)
  read_case "$rec"
  other_lease="$POOL_DIR/.leases/slot-1"
  own_lease="$POOL_DIR/.leases/slot-2"
  printf 'other-holder\n' > "$other_lease"
  fm_fake_exit0 "$FAKEBIN_DIR" sleep

  out=$(run_spawn_pool "$HOME_DIR" "$PROJ_DIR" "$FAKEBIN_DIR" "$TH_LOG" "$POOL_DIR" \
    lease-abort-d4 "$PROJ_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn should abort when the pane never reaches its leased worktree"$'\n'"$out"
  assert_contains "$out" "worker did not enter leased worktree" \
    "spawn did not fail at leased-worktree landing"
  [ ! -e "$HOME_DIR/state/lease-abort-d4.meta" ] \
    || fail "aborted spawn published metadata"
  [ ! -e "$own_lease" ] || fail "aborted spawn left its own lease held"
  [ -f "$other_lease" ] || fail "aborted spawn released another holder's lease"
  [ "$(cat "$other_lease")" = other-holder ] \
    || fail "aborted spawn changed another holder's lease"
  grep -F "treehouse return --force --if-lease-holder lease-abort-d4 $POOL_DIR/slot-2" \
    "$TH_LOG" >/dev/null \
    || fail "abort cleanup did not scope return to the spawning task's lease"
  pass "failed spawn abort releases only its task-owned lease"
}

test_lease_excludes_slot_from_plain_get
test_successful_teardown_releases_lease
test_refused_teardown_keeps_lease
test_concurrent_distinct_spawns_both_succeed
test_aborted_spawn_releases_only_own_lease

echo "# all fm-spawn-worktree-lease tests passed"
