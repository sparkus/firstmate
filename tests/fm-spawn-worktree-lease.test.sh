#!/usr/bin/env bash
# Durable ship/scout worktree leases (bin/fm-spawn.sh + bin/fm-teardown.sh).
#
# A plain interactive `treehouse get` leaves a pool slot available, so a later
# get can hand the same slot to a new spawn and hard-reset unlanded work
# (kunchenguid/firstmate#1441). Ship and scout spawns must lease under the task
# id; successful teardown releases; refused teardown must never release;
# recovery into a recorded worktree must not double-lease; pre-lease worktrees
# must keep working.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)
fm_git_identity fmtest fmtest@example.invalid

# Fake treehouse that models a small pool with durable leases.
# Env:
#   FM_FAKE_TREEHOUSE_POOL_DIR  - dir with slots/ and leases/
#   FM_FAKE_TREEHOUSE_LOG       - append-only command log
#   FM_FAKE_TREEHOUSE_GET_PATH  - optional fixed path for a single-slot pool
#   FM_FAKE_TREEHOUSE_RETURN_FAIL=1 - make return fail
install_lease_treehouse() {
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TREEHOUSE_LOG:-/dev/null}
printf 'treehouse %s\n' "$*" >> "$log"
pool=${FM_FAKE_TREEHOUSE_POOL_DIR:?FM_FAKE_TREEHOUSE_POOL_DIR unset}
mkdir -p "$pool/slots" "$pool/leases"

is_leased() {
  local path=$1 f holder
  for f in "$pool"/leases/*; do
    [ -e "$f" ] || continue
    if [ "$(cat "$f")" = "$path" ]; then
      return 0
    fi
  done
  return 1
}

case "${1:-}" in
  get)
    shift
    lease=0
    holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) lease=1 ;;
        --lease-holder) shift; holder=${1:-} ;;
        --lease-holder=*) holder=${1#--lease-holder=} ;;
        --json) ;;
      esac
      shift || true
    done
    if [ "$lease" -ne 1 ]; then
      # Plain get only hands out unleased available slots (the defect surface).
      if [ -n "${FM_FAKE_TREEHOUSE_GET_PATH:-}" ]; then
        path=$FM_FAKE_TREEHOUSE_GET_PATH
        if is_leased "$path"; then
          echo "error: no available worktree (all leased)" >&2
          exit 1
        fi
        printf '%s\n' "$path"
        exit 0
      fi
      for slot in "$pool"/slots/*; do
        [ -e "$slot" ] || continue
        path=$(cat "$slot")
        is_leased "$path" && continue
        printf '%s\n' "$path"
        exit 0
      done
      echo "error: no available worktree" >&2
      exit 1
    fi
    [ -n "$holder" ] || holder=${TREEHOUSE_LEASE_HOLDER:-unknown}
    # Prefer re-binding the same holder to its existing lease (not used by spawn
    # recovery, which skips get entirely; present for pool realism).
    if [ -f "$pool/leases/$holder" ]; then
      printf '%s\n' "$(cat "$pool/leases/$holder")"
      exit 0
    fi
    if [ -n "${FM_FAKE_TREEHOUSE_GET_PATH:-}" ]; then
      path=$FM_FAKE_TREEHOUSE_GET_PATH
      if is_leased "$path"; then
        echo "error: no available worktree (all leased)" >&2
        exit 1
      fi
      printf '%s\n' "$path" > "$pool/leases/$holder"
      printf 'leased worktree for %s\n' "$holder" >&2
      printf '%s\n' "$path"
      exit 0
    fi
    for slot in "$pool"/slots/*; do
      [ -e "$slot" ] || continue
      path=$(cat "$slot")
      is_leased "$path" && continue
      printf '%s\n' "$path" > "$pool/leases/$holder"
      printf 'leased worktree for %s\n' "$holder" >&2
      printf '%s\n' "$path"
      exit 0
    done
    echo "error: no available worktree" >&2
    exit 1
    ;;
  return)
    shift
    target=
    required_holder=
    while [ $# -gt 0 ]; do
      case "$1" in
        --force) ;;
        --if-lease-holder) shift; required_holder=${1:-} ;;
        *) target=$1 ;;
      esac
      shift || true
    done
    [ -z "${FM_FAKE_TREEHOUSE_RETURN_FAIL:-}" ] || exit 17
    if [ -n "${FM_FAKE_TREEHOUSE_RETURN_ENTERED:-}" ]; then
      : > "$FM_FAKE_TREEHOUSE_RETURN_ENTERED"
      while [ ! -e "${FM_FAKE_TREEHOUSE_RETURN_RELEASE:?}" ]; do
        sleep 0.01
      done
    fi
    if [ -n "$target" ]; then
      for f in "$pool"/leases/*; do
        [ -e "$f" ] || continue
        if [ "$(cat "$f")" = "$target" ]; then
          if [ -n "$required_holder" ] && [ "$(basename "$f")" != "$required_holder" ]; then
            exit 18
          fi
          rm -f "$f"
        fi
      done
    fi
    exit 0
    ;;
  status)
    first=1
    printf '['
    for slot in "$pool"/slots/*; do
      [ -e "$slot" ] || continue
      path=$(cat "$slot")
      holder=
      for f in "$pool"/leases/*; do
        [ -e "$f" ] || continue
        if [ "$(cat "$f")" = "$path" ]; then
          holder=$(basename "$f")
          break
        fi
      done
      state=available
      [ -z "$holder" ] || state=leased
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name":"%s","path":"%s","status":"%s","lease_id":"test","lease_holder":"%s","leased_at":null,"processes":[]}' \
        "$(basename "$slot")" "$path" "$state" "$holder"
    done
    printf ']\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

install_spawn_tmux() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_FAKE_TMUX_LOG:-/dev/null}
printf 'tmux %s\n' "$*" >> "$log"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    # After spawn sends `cd <path>`, tests can flip the pane path by matching
    # the cd target against FM_FAKE_PANE_PATH (already set to the leased path).
    if [ -n "${FM_FAKE_TMUX_SEND_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$FM_FAKE_TMUX_SEND_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# make_lease_case <name> <id> [slot2_name]
# Builds home, project, one (or two) real worktrees as pool slots, and fakes.
make_lease_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin pool
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  pool="$case_dir/pool"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$pool/slots" "$pool/leases"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$wt" > "$pool/slots/1"
  if [ -n "${3:-}" ]; then
    local wt2="$case_dir/wt2"
    git -C "$proj" worktree add --quiet -b "wt2-$name" "$wt2"
    printf '%s\n' "$wt2" > "$pool/slots/2"
  fi
  install_lease_treehouse "$fakebin"
  install_spawn_tmux "$fakebin"
  # Default gh/tasks stubs so teardown can complete when work is landed.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --version ] && { printf '0.1.1\n'; exit 0; }
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/tasks-axi"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$pool|$id"
}

read_lease_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR POOL_DIR TASK_ID <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TREEHOUSE_POOL_DIR="$POOL_DIR" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TMUX_LOG="$CASE_DIR/tmux.log" \
    FM_FAKE_TMUX_SEND_LOG="$CASE_DIR/tmux-send.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" "$@" 2>&1
}

run_teardown() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_FAKE_TREEHOUSE_POOL_DIR="$POOL_DIR" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$TEARDOWN" "$id" "$@" 2>&1
}

lease_holder_file() {
  local holder=$1
  printf '%s\n' "$POOL_DIR/leases/$holder"
}

install_failing_meta_mv() {
  local fakebin=$1 real_mv
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "\${FM_FAKE_META_MV_FAIL_DEST:-}" ]; then
    exit 73
  fi
done
exec '$real_mv' "\$@"
SH
  chmod +x "$fakebin/mv"
}

# ---------------------------------------------------------------------------
# 1. Spawn leases; a subsequent plain get must not hand out the same path.
# ---------------------------------------------------------------------------
test_spawn_lease_blocks_second_get() {
  local rec out status lease_file second
  rec=$(make_lease_case lease-blocks-get ship-lease-a1)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "spawn should lease a worktree"$'\n'"$out"
  assert_contains "$out" "spawned $TASK_ID" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$TASK_ID.meta" \
    "meta did not record the leased worktree"
  assert_grep "treehouse_lease_holder=$TASK_ID" "$HOME_DIR/state/$TASK_ID.meta" \
    "meta did not record the treehouse lease holder"
  assert_grep "treehouse_lease_state=held" "$HOME_DIR/state/$TASK_ID.meta" \
    "meta did not record the held treehouse lease state"
  lease_file=$(lease_holder_file "$TASK_ID")
  [ -f "$lease_file" ] || fail "spawn did not record a durable lease under the task id"
  [ "$(cat "$lease_file")" = "$WT_DIR" ] || fail "lease path mismatch: $(cat "$lease_file")"
  grep -F "treehouse get --lease --lease-holder $TASK_ID" "$CASE_DIR/treehouse.log" >/dev/null \
    || fail "spawn did not call treehouse get --lease --lease-holder under the task id"
  grep -E 'send-keys .*[[:space:]]cd[[:space:]]' "$CASE_DIR/tmux-send.log" >/dev/null \
    || fail "spawn did not cd the pane into the leased worktree: $(cat "$CASE_DIR/tmux-send.log" 2>/dev/null)"

  # Prove the negative: while the task is live, a subsequent plain get must not
  # return the leased path (single-slot pool).
  second=$(
    FM_FAKE_TREEHOUSE_POOL_DIR="$POOL_DIR" \
      FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
      FM_FAKE_TREEHOUSE_GET_PATH="$WT_DIR" \
      PATH="$FAKEBIN_DIR:$PATH" \
      treehouse get 2>/dev/null || true
  )
  [ -z "$second" ] || fail "plain treehouse get handed out still-leased path: $second"
  pass "spawned ship slot is leased and not handed out by a subsequent treehouse get"
}

# ---------------------------------------------------------------------------
# 2. Successful teardown releases the lease.
# ---------------------------------------------------------------------------
test_successful_teardown_releases_lease() {
  local rec out status lease_file
  rec=$(make_lease_case teardown-releases ship-lease-b2)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "spawn for release case failed"$'\n'"$out"
  lease_file=$(lease_holder_file "$TASK_ID")
  [ -f "$lease_file" ] || fail "lease missing after spawn"

  # Land the work on origin so teardown is allowed without --force.
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "landed"
  git -C "$PROJ_DIR" remote add origin "$CASE_DIR/origin.git" 2>/dev/null || true
  git init -q --bare "$CASE_DIR/origin.git"
  git -C "$WT_DIR" push -q "$CASE_DIR/origin.git" "HEAD:refs/heads/$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)"
  git -C "$PROJ_DIR" fetch -q origin 2>/dev/null || true
  # Ensure the worktree sees a remote-tracking ref for landed check.
  git -C "$PROJ_DIR" remote remove origin 2>/dev/null || true
  git -C "$PROJ_DIR" remote add origin "$CASE_DIR/origin.git"
  git -C "$PROJ_DIR" fetch -q origin
  # Point the task branch remote-tracking ref that work_is_landed looks for.
  branch=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  git -C "$PROJ_DIR" update-ref "refs/remotes/origin/$branch" "$(git -C "$WT_DIR" rev-parse HEAD)"

  : > "$CASE_DIR/treehouse.log"
  out=$(run_teardown "$TASK_ID")
  status=$?
  expect_code 0 "$status" "teardown should succeed for landed work"$'\n'"$out"
  [ ! -e "$lease_file" ] || fail "successful teardown left the lease held"
  grep -F "treehouse return --force" "$CASE_DIR/treehouse.log" >/dev/null \
    || fail "successful teardown did not call treehouse return"
  pass "successful teardown releases the lease and frees the slot"
}

# ---------------------------------------------------------------------------
# 3. REFUSED teardown leaves the lease held (exercise the refusal).
# ---------------------------------------------------------------------------
test_refused_teardown_keeps_lease() {
  local rec out status lease_file
  rec=$(make_lease_case teardown-refuses ship-lease-c3)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "spawn for refuse case failed"$'\n'"$out"
  lease_file=$(lease_holder_file "$TASK_ID")
  [ -f "$lease_file" ] || fail "lease missing after spawn"

  # Unlanded real content change (not --allow-empty: empty commits match the
  # "content already in default branch" landed fallback and would tear down).
  printf 'unlanded payload\n' > "$WT_DIR/unlanded.txt"
  git -C "$WT_DIR" add unlanded.txt
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -q -m "unlanded only"
  : > "$CASE_DIR/treehouse.log"
  set +e
  out=$(run_teardown "$TASK_ID" 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "teardown should refuse unlanded work, got success: $out"
  assert_contains "$out" "REFUSED" "teardown refusal did not report REFUSED"
  [ -f "$lease_file" ] || fail "refused teardown released the lease"
  [ "$(cat "$lease_file")" = "$WT_DIR" ] || fail "refused teardown altered the lease path"
  if grep -F "treehouse return" "$CASE_DIR/treehouse.log" >/dev/null 2>&1; then
    fail "refused teardown called treehouse return (would release the lease)"
  fi
  pass "refused teardown leaves the lease held (refusal exercised)"
}

# ---------------------------------------------------------------------------
# 4. Recovery into an existing recorded worktree does not create a second lease.
# ---------------------------------------------------------------------------
test_recovery_reuses_worktree_without_second_lease() {
  local rec out status lease_file get_count
  rec=$(make_lease_case recovery-reuse ship-lease-d4)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "initial spawn for recovery case failed"$'\n'"$out"
  lease_file=$(lease_holder_file "$TASK_ID")
  [ -f "$lease_file" ] || fail "lease missing after initial spawn"
  get_count=$(grep -c 'treehouse get --lease' "$CASE_DIR/treehouse.log" || true)
  [ "$get_count" -eq 1 ] || fail "expected exactly one lease acquire on first spawn, got $get_count"

  # Simulate recovery: endpoint gone, recorded worktree + lease still present.
  # Re-spawn under the same task id; must reuse worktree= and not call get again.
  : > "$CASE_DIR/treehouse.log"
  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "recovery spawn should reuse the recorded worktree"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$TASK_ID.meta" \
    "recovery spawn lost the recorded worktree"
  if grep -F 'treehouse get --lease' "$CASE_DIR/treehouse.log" >/dev/null 2>&1; then
    fail "recovery spawn acquired a second lease: $(cat "$CASE_DIR/treehouse.log")"
  fi
  grep -F 'treehouse status --json' "$CASE_DIR/treehouse.log" >/dev/null \
    || fail "recovery spawn did not verify the recorded task-held lease"
  [ -f "$lease_file" ] || fail "recovery spawn dropped the original lease"
  [ "$(cat "$lease_file")" = "$WT_DIR" ] || fail "recovery spawn changed the lease path"
  # Only one lease file for this holder (no double-lease artifact).
  [ "$(find "$POOL_DIR/leases" -type f | wc -l | tr -d ' ')" = 1 ] \
    || fail "recovery left more than one lease file"
  pass "recovery into an existing worktree does not create a second lease"
}

test_recovery_refuses_returned_stale_meta() {
  local rec out status meta_tmp
  rec=$(make_lease_case recovery-stale-return ship-lease-f6)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "initial spawn for stale-return case failed"$'\n'"$out"
  FM_FAKE_TREEHOUSE_POOL_DIR="$POOL_DIR" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    treehouse return --force --if-lease-holder "$TASK_ID" "$WT_DIR"
  [ ! -e "$(lease_holder_file "$TASK_ID")" ] || fail "stale-return fixture left the lease held"

  : > "$CASE_DIR/treehouse.log"
  set +e
  out=$(run_spawn "$TASK_ID")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "recovery reused a returned worktree from stale metadata"
  assert_contains "$out" "not leased under task $TASK_ID" \
    "stale returned-worktree recovery did not fail on ownership proof"
  if grep -F 'treehouse get --lease' "$CASE_DIR/treehouse.log" >/dev/null 2>&1; then
    fail "stale recovery acquired a replacement lease instead of failing closed"
  fi

  meta_tmp="$CASE_DIR/returned.meta"
  grep -v '^treehouse_lease_state=' "$HOME_DIR/state/$TASK_ID.meta" > "$meta_tmp"
  printf 'treehouse_lease_state=returned\n' >> "$meta_tmp"
  mv "$meta_tmp" "$HOME_DIR/state/$TASK_ID.meta"
  set +e
  out=$(run_spawn "$TASK_ID")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "recovery reused a worktree explicitly recorded as returned"
  assert_contains "$out" "lease state returned" \
    "returned lease state did not block recovery"
  pass "recovery refuses a returned worktree retained in stale metadata"
}

test_recovery_refuses_one_sided_lease_metadata() {
  local rec out status marker
  rec=$(make_lease_case recovery-partial-meta ship-lease-h8)
  read_lease_case "$rec"

  for marker in holder-only state-only; do
    fm_write_meta "$HOME_DIR/state/$TASK_ID.meta" \
      "window=firstmate:fm-$TASK_ID" \
      "endpoint_task_id=$TASK_ID" \
      "worktree=$WT_DIR" \
      "project=$PROJ_DIR" \
      "harness=codex" \
      "kind=ship" \
      "mode=no-mistakes" \
      "yolo=off"
    if [ "$marker" = holder-only ]; then
      printf 'treehouse_lease_holder=%s\n' "$TASK_ID" >> "$HOME_DIR/state/$TASK_ID.meta"
    else
      printf 'treehouse_lease_state=held\n' >> "$HOME_DIR/state/$TASK_ID.meta"
    fi
    : > "$CASE_DIR/treehouse.log"
    set +e
    out=$(run_spawn "$TASK_ID")
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "recovery accepted $marker treehouse lease metadata"
    if grep -F 'treehouse get --lease' "$CASE_DIR/treehouse.log" >/dev/null 2>&1; then
      fail "recovery replaced $marker lease metadata with a new lease"
    fi
  done
  pass "recovery rejects one-sided treehouse lease metadata"
}

test_failed_meta_publication_returns_fresh_lease() {
  local rec out status
  rec=$(make_lease_case atomic-meta-publication ship-lease-i9)
  read_lease_case "$rec"
  install_failing_meta_mv "$FAKEBIN_DIR"

  set +e
  out=$(FM_FAKE_META_MV_FAIL_DEST="$HOME_DIR/state/$TASK_ID.meta" run_spawn "$TASK_ID")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "spawn succeeded despite failed atomic metadata publication"
  assert_contains "$out" "could not publish metadata for task $TASK_ID" \
    "spawn did not report failed atomic metadata publication"
  [ ! -e "$HOME_DIR/state/$TASK_ID.meta" ] || fail "failed publication exposed partial task metadata"
  [ ! -e "$(lease_holder_file "$TASK_ID")" ] || fail "failed publication leaked the fresh treehouse lease"
  if find "$HOME_DIR/state" -maxdepth 1 -name ".${TASK_ID}.meta.*" -print | grep . >/dev/null; then
    fail "failed publication left a temporary metadata file"
  fi
  pass "failed metadata publication is atomic and returns its fresh lease"
}

test_teardown_serializes_against_recovery() {
  local rec out status entered release teardown_out teardown_pid spawn_out spawn_status i
  rec=$(make_lease_case teardown-race ship-lease-g7)
  read_lease_case "$rec"

  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "initial spawn for teardown race failed"$'\n'"$out"
  entered="$CASE_DIR/return-entered"
  release="$CASE_DIR/return-release"
  teardown_out="$CASE_DIR/teardown.out"
  FM_FAKE_TREEHOUSE_RETURN_ENTERED="$entered" \
    FM_FAKE_TREEHOUSE_RETURN_RELEASE="$release" \
    run_teardown "$TASK_ID" --force >"$teardown_out" 2>&1 &
  teardown_pid=$!
  i=0
  while [ ! -e "$entered" ] && [ "$i" -lt 200 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -e "$entered" ] || {
    : > "$release"
    wait "$teardown_pid" || true
    fail "teardown did not reach the blocked return: $(cat "$teardown_out")"
  }
  assert_grep 'treehouse_lease_state=returning' "$HOME_DIR/state/$TASK_ID.meta" \
    "teardown did not persist return-in-progress ownership"

  set +e
  spawn_out=$(run_spawn "$TASK_ID")
  spawn_status=$?
  set -e
  [ "$spawn_status" -ne 0 ] || fail "recovery entered while teardown held the task lifecycle lock"
  assert_contains "$spawn_out" "another spawn is already creating task $TASK_ID" \
    "recovery did not observe teardown's shared task lock"

  : > "$release"
  wait "$teardown_pid"
  status=$?
  expect_code 0 "$status" "blocked teardown did not finish after release"$'\n'"$(cat "$teardown_out")"
  pass "teardown and recovery serialize on the task lifecycle lock"
}

# ---------------------------------------------------------------------------
# 5. Pre-existing unleased worktrees do not break spawn or teardown.
# ---------------------------------------------------------------------------
test_legacy_unleased_worktree_spawn_and_teardown() {
  local rec out status
  rec=$(make_lease_case legacy-unleased ship-lease-e5)
  read_lease_case "$rec"

  # Pre-lease era: meta already points at a real worktree, no lease file.
  fm_write_meta "$HOME_DIR/state/$TASK_ID.meta" \
    "window=firstmate:fm-$TASK_ID" \
    "endpoint_task_id=$TASK_ID" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  [ ! -e "$(lease_holder_file "$TASK_ID")" ] || fail "fixture incorrectly created a lease"

  : > "$CASE_DIR/treehouse.log"
  out=$(run_spawn "$TASK_ID")
  status=$?
  expect_code 0 "$status" "spawn must accept a pre-existing unleased recorded worktree"$'\n'"$out"
  if grep -F 'treehouse get --lease' "$CASE_DIR/treehouse.log" >/dev/null 2>&1; then
    fail "legacy recovery incorrectly leased an already-owned unleased worktree"
  fi
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$TASK_ID.meta" \
    "legacy recovery lost the recorded worktree"

  # Land and teardown: return must succeed without requiring a prior lease.
  git -C "$WT_DIR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "landed legacy"
  git init -q --bare "$CASE_DIR/origin.git"
  git -C "$PROJ_DIR" remote remove origin 2>/dev/null || true
  git -C "$PROJ_DIR" remote add origin "$CASE_DIR/origin.git"
  branch=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  git -C "$WT_DIR" push -q origin "HEAD:refs/heads/$branch"
  git -C "$PROJ_DIR" fetch -q origin
  git -C "$PROJ_DIR" update-ref "refs/remotes/origin/$branch" "$(git -C "$WT_DIR" rev-parse HEAD)"

  : > "$CASE_DIR/treehouse.log"
  out=$(run_teardown "$TASK_ID")
  status=$?
  expect_code 0 "$status" "teardown of legacy unleased worktree should succeed"$'\n'"$out"
  grep -F "treehouse return --force" "$CASE_DIR/treehouse.log" >/dev/null \
    || fail "legacy teardown did not return the worktree"
  pass "pre-existing unleased worktrees do not break spawn or teardown"
}

test_spawn_lease_blocks_second_get
test_successful_teardown_releases_lease
test_refused_teardown_keeps_lease
test_recovery_reuses_worktree_without_second_lease
test_recovery_refuses_returned_stale_meta
test_recovery_refuses_one_sided_lease_metadata
test_failed_meta_publication_returns_fresh_lease
test_teardown_serializes_against_recovery
test_legacy_unleased_worktree_spawn_and_teardown

echo "# all fm-spawn-worktree-lease tests passed"
