#!/usr/bin/env bash
# Record a handled refill claim-and-dispatch cycle that spawned no ship.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-refill-lib.sh
. "$SCRIPT_DIR/fm-refill-lib.sh"

case "${1:-}" in
  no-ready|no-eligible|held-only) outcome=$1 ;;
  *)
    echo "usage: fm-refill-complete.sh <no-ready|no-eligible|held-only>" >&2
    exit 2
    ;;
esac
[ "$#" -eq 1 ] || {
  echo "usage: fm-refill-complete.sh <no-ready|no-eligible|held-only>" >&2
  exit 2
}

fm_refill_dispatch_cycle_completed "$STATE" "$CONFIG"
printf 'refill claim-and-dispatch cycle completed: %s\n' "$outcome"
