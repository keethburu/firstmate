#!/usr/bin/env bash
# Optional bounded execution policy and durable attempt records.
# Usage: fm-execution.sh validate
#        fm-execution.sh status <task-id>
#        fm-execution.sh classify <task-id> <salvageable|structural|capacity|external>
#          --evidence-file <path> [--retry-after <epoch-seconds>]
#
# config/crew-execution.json has version:1, optional harness_instructions mapping
# harness names to instruction text, and optional bounded containing initial
# (profile array), repair (one profile), max_capacity_recoveries (0 or 1; default 1).
# A profile has harness, model and effort. Private policy is snapshotted on enrollment.
# Matching initial ship profiles enroll automatically; --bounded enrolls explicitly.
# This allowlist does not select a model or alter the dispatch candidate pool.
# fm-control relaunch consumes a salvageable or
# capacity classification. fm-spawn --restart-from <source> consumes a structural
# classification, retaining the source task and using its original base commit.
# Classification is supervisor judgment, recorded against the current spawn generation.
# Evidence must contain objective diagnostics, never transcripts or previous reasoning.
# The limit is two OUTER implementation attempts; no-mistakes internal rounds are separate.
# Capacity recovery does not reset that count and is allowed at most once per lineage.
# retry-after 0 means no known reset; a supplied future reset prevents early recovery.
# External blockers and exhausted limits return control to the captain.
#
# data/<root>/execution.json owns the lineage; execution-root links successor tasks.
# The record survives teardown. A short-lived lineage lock serializes reservations,
# never waits on task/control locks, and therefore cannot reverse their lock order.
# Reserved attempts are conservatively consumed even if launch fails: uncertain
# delivery never refunds budget. Inspect status and return to captain after such failure.
# Original brief and evidence snapshots are retained beside the record.
# Native spawn/control use the private _prepare, _consume, _base and _publish commands.
# jq owns the literal expression variables below.
# shellcheck disable=SC2016
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in validate|status|--help|-h) ;;
  *) [ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME is required for mutation' >&2; exit 1; } ;;
esac
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
# shellcheck source=bin/fm-execution-lib.sh
. "$SCRIPT_DIR/fm-execution-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
EXECUTION_LOCK=
trap '[ -z "$EXECUTION_LOCK" ] || fm_lock_release "$EXECUTION_LOCK"; fm_lease_guard_release' EXIT

case "${1:-}" in
  --help|-h) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  validate) fm_execution_validate "$CONFIG/crew-execution.json" ;;
  status) record=$(fm_execution_record "${2:-}"); jq . "$record" ;;
  classify)
    id=${2:-}; class=${3:-}; shift 3
    evidence=; retry=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --evidence-file) evidence=${2:?missing evidence file}; shift 2 ;;
        --retry-after) retry=${2:?missing reset epoch}; shift 2 ;;
        *) fm_execution_error "unknown classify argument $1"; exit 1 ;;
      esac
    done
    fm_lease_guard "$id" 'classify bounded execution'
    fm_execution_classify "$id" "$class" "$evidence" "$retry"
    ;;
  _prepare)
    shift
    if [ "${FM_EXECUTION_CONTROL_PARENT:-0}" != 1 ]; then
      fm_lease_guard "${1:?missing source task}" 'reserve bounded execution'
    fi
    fm_execution_transition "$@"
    ;;
  _enroll)
    shift
    fm_execution_enroll "$@"
    ;;
  _handoff) fm_execution_handoff "${2:?missing task}" ;;
  _consume)
    record=$(fm_execution_record "${2:?missing task}")
    fm_execution_lock "$record"
    stage=initial
    [ "$(jq -r '.attempt' "$record")" = 1 ] || stage=repair
    fm_execution_profile "$record" "$stage" "${4:-}" "${5:-}" "${6:-}"
    previous=$(jq -r '.previous // empty' "$record")
    [ -z "$previous" ] || fm_execution_custody "$previous"
    fm_execution_write "$record" --arg ticket "${3:-}" --arg id "$2" '
      if .phase == "reserved" and .current == $id and .ticket == $ticket
      then .phase = "launching" else error("launch reservation already consumed or mismatched") end
    '
    ;;
  _base)
    record=$(fm_execution_record "${2:?missing task}")
    fm_execution_lock "$record"
    base=$(git -C "${3:?missing worktree}" rev-parse --verify HEAD)
    fm_execution_write "$record" --arg base "$base" '
      if .base == "" then .base = $base
      elif .base == $base then . else error("restart did not use original base") end
    '
    ;;
  _publish)
    record=$(fm_execution_record "${2:?missing task}")
    fm_execution_lock "$record"
    [ "$(fm_meta_get "$STATE/$2.meta" spawn_gen)" = "${3:?missing generation}" ] ||
      { fm_execution_error "publication generation does not match task metadata"; exit 1; }
    fm_execution_write "$record" --arg generation "$3" --arg id "$2" '
      if .phase == "launching" and .current == $id
      then .phase = "running" | .generation = $generation
      else error("no consumed launch reservation") end
    '
    ;;
  *) fm_execution_error "use fm-execution.sh --help"; exit 2 ;;
esac
