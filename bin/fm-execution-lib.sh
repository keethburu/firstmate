#!/usr/bin/env bash
# Optional worker execution configuration and bounded implementation lifecycle.
# Public commands and record ownership are documented by fm-execution.sh --help.
# Shell globals are supplied by native spawn/control; jq expressions use literal variables.
# shellcheck disable=SC2016,SC2034,SC2153

fm_execution_error() {
  printf 'error: execution policy: %s\n' "$*" >&2
  return 1
}

fm_execution_cli() {
  FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-execution.sh" "$@"
}

fm_execution_validate() {
  local file=$1
  [ -e "$file" ] || [ -L "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] ||
    { fm_execution_error "$file must be a regular file"; return 1; }
  jq -e '
    def profile:
      type == "object" and (keys == ["effort", "harness", "model"]) and
      (.harness | IN("claude", "codex", "opencode", "pi", "pi-signed", "grok",
        "kimi", "cursor", "omp", "muse", "gemini", "rovo", "agy")) and
      (.model | type == "string" and test("^[^[:space:][:cntrl:]]+$")) and
      (.effort | IN("low", "medium", "high", "xhigh", "max", "ultra"));
    type == "object" and .version == 1 and
    ((keys - ["version", "harness_instructions", "bounded"]) | length == 0) and
    ((if has("harness_instructions") then .harness_instructions else {} end) |
      type == "object" and all(to_entries[];
        (.key | IN("claude", "codex", "opencode", "pi", "pi-signed", "grok",
          "kimi", "cursor", "omp", "muse", "gemini", "rovo", "agy")) and
        (.value | type == "string" and test("[^[:space:]]") and
          (contains("\u0000") | not)))) and
    ((has("bounded") | not) or (.bounded |
      type == "object" and
      ((keys - ["initial", "repair"]) | length == 0) and
      (.initial | type == "array" and length > 0 and all(.[]; profile)) and
      (.repair | profile) and
      (.repair as $repair | all(.initial[]; . != $repair))))
  ' "$file" >/dev/null 2>&1 ||
    fm_execution_error "invalid $file; see fm-execution.sh --help"
}

fm_execution_instructions() {
  local file=$1 harness=$2
  [ -f "$file" ] || return 0
  jq -r --arg harness "$harness" '
    .harness_instructions[$harness] // empty |
    "\n# Harness implementation instructions\n\n" + .
  ' "$file"
}

fm_execution_task_dir() {
  local id=$1
  fm_task_id_path_safe "$id" ||
    { fm_execution_error "invalid task id '$id'"; return 1; }
  [ -d "$DATA/$id" ] && [ ! -L "$DATA/$id" ] ||
    { fm_execution_error "unsafe or missing task directory $DATA/$id"; return 1; }
  printf '%s\n' "$DATA/$id"
}

fm_execution_record() {
  local dir root pointer
  fm_task_id_path_safe "$1" || return 1
  [ -e "$DATA/$1/execution-root" ] || [ -L "$DATA/$1/execution-root" ] || return 2
  dir=$(fm_execution_task_dir "$1") || return 1
  pointer="$dir/execution-root"
  [ -e "$pointer" ] || [ -L "$pointer" ] || return 2
  [ -f "$pointer" ] && [ ! -L "$pointer" ] ||
    { fm_execution_error "unsafe lineage pointer $pointer"; return 1; }
  root=$(cat "$pointer") || return 1
  dir=$(fm_execution_task_dir "$root") || return 1
  [ -f "$dir/execution.json" ] && [ ! -L "$dir/execution.json" ] ||
    { fm_execution_error "missing or unsafe lineage record for $root"; return 1; }
  jq -e --arg root "$root" '
    .version == 1 and .root == $root and
    (.attempt | IN(1,2)) and (.recoveries | IN(0,1)) and
    (.phase | IN("reserved", "launching", "running", "classified")) and
    (.current | type == "string") and (.policy | type == "object") and
    (.base | type == "string")
  ' "$dir/execution.json" >/dev/null ||
    { fm_execution_error "malformed lineage record for $root"; return 1; }
  printf '%s\n' "$dir/execution.json"
}

fm_execution_write() {
  local file=$1 tmp
  shift
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  if jq "$@" "$file" >"$tmp" && mv "$tmp" "$file"; then return 0; fi
  rm -f "$tmp"
  fm_execution_error "could not atomically update $file"
}

fm_execution_lock() {
  EXECUTION_LOCK="${1%/*}/.execution.lock"
  fm_lock_try_acquire "$EXECUTION_LOCK" ||
    fm_execution_error "lineage is busy; inspect status before retrying"
}

fm_execution_profile() {
  local record=$1 stage=$2 harness=$3 model=$4 effort=$5
  jq -e --arg stage "$stage" --arg harness "$harness" --arg model "$model" \
    --arg effort "$effort" '
      {harness:$harness, model:$model, effort:$effort} as $profile |
      if $stage == "initial" then any(.policy.initial[]; . == $profile)
      else .policy.repair == $profile end
    ' "$record" >/dev/null || fm_execution_error "profile is not allowed for $stage attempt"
}

fm_execution_evidence() {
  local source=$1 destination=$2
  [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] ||
    { fm_execution_error "evidence must be a nonempty regular file"; return 1; }
  case "/$source/" in */.env/*|*/.env.*/*)
    fm_execution_error "environment files cannot be evidence"; return 1 ;;
  esac
  [ "$(wc -c <"$source")" -le 262144 ] ||
    { fm_execution_error "evidence exceeds 256 KiB; provide focused diagnostics"; return 1; }
  [ ! -e "$destination" ] && [ ! -L "$destination" ] ||
    { fm_execution_error "evidence snapshot already exists; inspect lineage"; return 1; }
  (set -C; cat "$source" >"$destination")
}

fm_execution_classify() {
  local id=$1 class=$2 evidence=$3 retry=$4 record generation snapshot
  case "$class" in salvageable|structural|capacity) ;;
    *) fm_execution_error "unknown failure class '$class'"; return 1 ;; esac
  case "$retry" in ''|*[!0-9]*)
    fm_execution_error "retry-after must be an epoch integer (0 if unknown)"; return 1 ;;
  esac
  [ "$class" = capacity ] || [ "$retry" = 0 ] ||
    { fm_execution_error "retry-after applies only to capacity"; return 1; }
  record=$(fm_execution_record "$id") || return 1
  fm_execution_lock "$record" || return 1
  generation=$(fm_meta_get "$STATE/$id.meta" spawn_gen)
  [ -n "$generation" ] ||
    { fm_execution_error "task has no launch generation"; return 1; }
  jq -e --arg id "$id" --arg generation "$generation" '
    .current == $id and .phase == "running" and .generation == $generation
  ' "$record" >/dev/null ||
    { fm_execution_error "task is not the current unclassified attempt"; return 1; }
  snapshot="${record%/*}/execution-evidence.$generation.txt"
  fm_execution_evidence "$evidence" "$snapshot" || return 1
  fm_execution_write "$record" --arg class "$class" --arg evidence "$snapshot" \
    --argjson retry "$retry" '
      .phase = "classified" |
      .decision = {class:$class, evidence:$evidence, retry_after:$retry}
    '
}

fm_execution_enroll() {
  local id=$1 project=$2 harness=$3 model=$4 effort=$5 dir file tmp
  dir=$(fm_execution_task_dir "$id") || return 1
  file="$dir/execution.json"
  fm_execution_lock "$file" || return 1
  [ ! -e "$file" ] && [ ! -L "$file" ] &&
    [ ! -e "$dir/execution-root" ] && [ ! -L "$dir/execution-root" ] ||
    { fm_execution_error "task already has an enrollment; inspect its status"; return 1; }
  fm_execution_validate "$CONFIG/crew-execution.json" || return 1
  jq -e '.bounded.initial | length > 0' "$CONFIG/crew-execution.json" >/dev/null ||
    { fm_execution_error "bounded policy is not configured"; return 1; }
  tmp=$(mktemp "$dir/.execution.XXXXXX") ||
    { fm_execution_error "cannot create enrollment temporary file in $dir"; return 1; }
  EXECUTION_TEMP=$tmp
  jq --arg id "$id" --arg project "$project" '
    {version:1, root:$id, current:$id, project:$project, policy:.bounded,
     attempt:1, recoveries:0, phase:"reserved", base:"", generation:"", ticket:""}
  ' "$CONFIG/crew-execution.json" >"$tmp" ||
    { fm_execution_error "cannot prepare enrollment for $id"; return 1; }
  if ! fm_execution_profile "$tmp" initial "$harness" "$model" "$effort"; then
    rm -f "$tmp"; return 1
  fi
  [ -f "$dir/brief.md" ] && [ ! -L "$dir/brief.md" ] ||
    { fm_execution_error "missing or unsafe original brief $dir/brief.md"; return 1; }
  (set -C; cat "$dir/brief.md" >"$dir/execution-original.md") ||
    { fm_execution_error "original snapshot exists or cannot be created"; return 1; }
  mv "$tmp" "$file" ||
    { fm_execution_error "cannot publish enrollment $file"; return 1; }
  EXECUTION_TEMP=
  printf '%s\n' "$id" >"$dir/execution-root" ||
    fm_execution_error "cannot publish lineage pointer for $id; inspect $file"
}

fm_execution_transition() {
  local source=$1 target=$2 harness=$3 model=$4 effort=$5 record class attempt stage generation
  record=$(fm_execution_record "$source") || return 1
  fm_execution_lock "$record" || return 1
  jq -e --arg source "$source" '.current == $source and .phase == "classified"' \
    "$record" >/dev/null ||
    { fm_execution_error "record a failure classification before another launch"; return 1; }
  class=$(jq -r '.decision.class' "$record")
  attempt=$(jq -r '.attempt' "$record")
  stage=repair
  case "$class" in
    salvageable|structural)
      [ "$attempt" = 1 ] ||
        { fm_execution_error "two outer attempts exhausted; return to captain"; return 1; }
      if [ "$class" = salvageable ]; then
        [ "$source" = "$target" ] ||
          { fm_execution_error "salvageable repair must reuse task $source"; return 1; }
      else
        [ "$source" != "$target" ] ||
          { fm_execution_error "structural failure requires --restart-from in a new task"; return 1; }
      fi ;;
    capacity)
      [ "$source" = "$target" ] ||
        { fm_execution_error "capacity recovery must reuse task $source"; return 1; }
      [ "$attempt" = 1 ] && stage=initial
      jq -e --argjson now "$(date +%s)" '
        .recoveries < 1 and
        .decision.retry_after <= $now
      ' "$record" >/dev/null ||
        { fm_execution_error "capacity recovery exhausted or reset not reached"; return 1; } ;;
    *) fm_execution_error "classification returns control to captain"; return 1 ;;
  esac
  fm_execution_profile "$record" "$stage" "$harness" "$model" "$effort" || return 1
  fm_execution_custody "$source" || return 1
  generation=$(fm_meta_get "$STATE/$source.meta" spawn_gen)
  jq -e --arg generation "$generation" '.generation == $generation' "$record" >/dev/null ||
    { fm_execution_error "classification belongs to an older launch"; return 1; }
  [ "${FM_EXECUTION_CHECK_ONLY:-0}" != 1 ] || return 0
  fm_execution_reserve "$record" "$source" "$target" "$class"
}

fm_execution_reserve() {
  local record=$1 source=$2 target=$3 class=$4 dir ticket root generation
  generation=$(fm_meta_get "$STATE/$source.meta" spawn_gen)
  jq -e --arg generation "$generation" '.generation == $generation' "$record" >/dev/null ||
    { fm_execution_error "classification belongs to an older launch"; return 1; }
  fm_execution_stopped "$source" || return 1
  if [ "$source" != "$target" ]; then
    dir=$(fm_execution_task_dir "$target") || return 1
    [ ! -e "$dir/execution-root" ] && [ ! -L "$dir/execution-root" ] ||
      { fm_execution_error "restart target is already enrolled"; return 1; }
    root=$(jq -r '.root' "$record")
    printf '%s\n' "$root" >"$dir/execution-root" || return 1
  fi
  ticket="${BASHPID:-$$}.$(date +%s).$RANDOM"
  fm_execution_write "$record" --arg target "$target" --arg source "$source" \
    --arg ticket "$ticket" \
    --arg class "$class" '
      .previous = $source | .current = $target | .phase = "reserved" | .ticket = $ticket |
      if $class == "capacity" then .recoveries += 1 else .attempt += 1 end
    ' || return 1
  printf '%s\n' "$ticket"
}

fm_execution_stopped() {
  local id=$1 backend endpoint verdict
  fm_backend_validate_task_endpoint "$STATE/$id.meta" "$id" || return 1
  backend=$(fm_meta_get "$STATE/$id.meta" backend)
  endpoint=$(fm_meta_get "$STATE/$id.meta" window)
  [ -n "$endpoint" ] || return 1
  verdict=$(fm_backend_agent_state "${backend:-tmux}" "$endpoint") || return 1
  case "$verdict" in dead|missing) return 0 ;;
    *) fm_execution_error "source task $id is not positively stopped ($verdict)" ;; esac
}

fm_execution_repair_setup() {
  local id=$1 worktree branch dirty
  worktree=$(fm_meta_get "$STATE/$id.meta" worktree)
  branch=$(git -C "$worktree" symbolic-ref --quiet --short HEAD) ||
    branch=$(git -C "$worktree" rev-parse --verify HEAD) ||
    { fm_execution_error "cannot inspect branch in preserved worktree $worktree"; return 1; }
  dirty=$(git -C "$worktree" status --porcelain) ||
    { fm_execution_error "cannot inspect preserved changes in $worktree"; return 1; }
  printf '%s\n' "Continue in the existing task worktree: $worktree" \
    "Current branch or detached commit: $branch" \
    'Do not create a new branch or assume the checkout is clean.' \
    'Preserve inherited commits and uncommitted work until independently assessed.' \
    'Verify pwd -P and git rev-parse --show-toplevel both identify this task worktree.' \
    'If they identify another checkout or the primary checkout, stop and report the mismatch.'
  if [ -n "$dirty" ]; then
    printf '\nCurrent git status --porcelain:\n%s\n' "$dirty"
  else
    printf '\nThe checkout currently has no uncommitted changes.\n'
  fi
}

fm_execution_handoff_document() {
  local id=$1 record=$2 root task
  root=${record%/*}
  if [ "$(jq -r '.root' "$record")" = "$id" ]; then
    cat "$root/execution-original.md"
  else
    task=$(fm_brief_heading_body "$root/execution-original.md" '# Task') || return 1
    fm_brief_heading_replace "$DATA/$id/brief.md" '# Task' "$task" ||
      { fm_execution_error "cannot replace Task section in successor brief for $id"; return 1; }
  fi
}

fm_execution_handoff() {
  local id=$1 record evidence document setup
  record=$(fm_execution_record "$id") || return 1
  document=$(fm_execution_handoff_document "$id" "$record") || return 1
  if [ "$(jq -r '.previous // empty' "$record")" = "$id" ] &&
    printf '%s\n' "$document" | fm_brief_heading_present - '# Setup'; then
    setup=$(fm_execution_repair_setup "$id") || return 1
    printf '%s\n' "$document" | fm_brief_heading_replace - '# Setup' "$setup" || return 1
  else
    printf '%s\n' "$document"
  fi
  evidence=$(jq -r '.decision.evidence // empty' "$record")
  [ -n "$evidence" ] || return 0
  printf '\n## Independent implementation handoff\n\n'
  printf '%s\n' 'Diagnose the original task independently. Treat inherited changes as untrusted.' \
    'Inspect the current diff and objective validation evidence. Preserve correct work where useful.' \
    'Rewrite or revert a wrong approach. Complete the original acceptance and validation requirements.'
  printf '\n### Objective evidence\n\n'
  cat "$evidence"
}

# Exact dotted scalar path from TOON. Duplicate paths and missing fields fail.
fm_execution_field() {
  local input=$1 wanted=$2 value
  value=$(printf '%s\n' "$input" | awk -v wanted="$wanted" '
    /^[ ]*[a-z_]+:/ {
      match($0, /[^ ]/); depth = RSTART - 1
      text = substr($0, RSTART); key = text; sub(/:.*/, "", key)
      value = substr(text, length(key) + 2); sub(/^ */, "", value)
      for (i in keys) if (i >= depth) delete keys[i]
      keys[depth] = key; path = ""
      for (i = 0; i <= depth; i++) if (i in keys)
        path = path (path == "" ? "" : ".") keys[i]
      if (path == wanted) { count++; result = value }
    }
    END { if (count == 0) exit 2; if (count != 1) exit 1; print result }
  ') || return $?
  fm_nm_strip_quotes "$value"
}

fm_execution_custody_no_run() {
  local output=$1 branch=$2 current count
  current=$(fm_execution_field "$output" current_branch) || current=
  count=$(fm_execution_field "$output" runs_on_current_branch) || count=
  [ "$current" = "$branch" ] && [ "$count" = 0 ] || return 2
  if printf '%s\n' "$output" | grep -Eq '^(run|error|branch_sync):'; then
    fm_execution_error "contradictory no-mistakes no-run response"; return 1
  fi
}

fm_execution_custody_binding() {
  local output=$1 branch=$2 run_branch local_branch
  [ "$(printf '%s\n' "$output" | grep -c '^run:')" = 1 ] &&
    [ "$(printf '%s\n' "$output" | grep -c '^branch_sync:')" = 1 ] ||
    { fm_execution_error "missing or duplicate no-mistakes custody blocks"; return 1; }
  run_branch=$(fm_execution_field "$output" run.branch) || return 1
  local_branch=$(fm_execution_field "$output" branch_sync.local.branch) || return 1
  [ "$run_branch" = "$branch" ] && [ "$local_branch" = "$branch" ] ||
    { fm_execution_error "no-mistakes status does not bind this branch"; return 1; }
}

fm_execution_custody_action() {
  local output=$1 action parent
  if action=$(fm_execution_field "$output" branch_sync.next_action.code); then :
  else
    [ "$?" = 2 ] || { fm_execution_error "duplicate custody action"; return 1; }
    if parent=$(fm_execution_field "$output" branch_sync.next_action); then
      [ "$parent" = null ] ||
        { fm_execution_error "malformed custody action"; return 1; }
    else
      [ "$?" = 2 ] || return 1
    fi
    action=
  fi
  printf '%s\n' "$action"
}

fm_execution_custody_terminal() {
  local output=$1 branch=$2 status state safety action
  fm_execution_custody_binding "$output" "$branch" || return 1
  status=$(fm_execution_field "$output" run.status) || return 1
  case "$status" in completed|failed|cancelled|ci_monitor_interrupted) ;;
    *) fm_execution_error "no-mistakes run remains active or unknown"; return 1 ;; esac
  state=$(fm_execution_field "$output" branch_sync.state) || return 1
  safety=$(fm_execution_field "$output" branch_sync.safety) || return 1
  action=$(fm_execution_custody_action "$output") || return 1
  case "$state:$safety:$action" in
    user_owned:user_owned:|custody_returned:custody_returned:run_pipeline|\
      synchronized:already_synchronized:) return 0 ;;
    *) fm_execution_error "no-mistakes has not returned branch custody ($state)" ;;
  esac
}

fm_execution_custody() {
  local id=$1 wt branch output
  case "$(fm_meta_get "$STATE/$id.meta" mode)" in
    no-mistakes) ;;
    local-only|direct-PR) return 0 ;;
    *) fm_execution_error "missing or invalid delivery mode; cannot establish custody"; return 1 ;;
  esac
  wt=$(fm_meta_get "$STATE/$id.meta" worktree)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) ||
    { fm_execution_error "cannot prove custody of a detached branch"; return 1; }
  output=$(fm_nm_run_bounded "$wt" 10 axi status) ||
    { fm_execution_error "no-mistakes custody unavailable; leave work unchanged"; return 1; }
  if fm_execution_custody_no_run "$output" "$branch"; then return 0
  else [ "$?" = 2 ] || return 1
  fi
  fm_execution_custody_terminal "$output" "$branch"
}

fm_execution_initial_profile() {
  [ "$KIND" = ship ] && [ -f "$CONFIG/crew-execution.json" ] || return 0
  if jq -e --arg harness "$HARNESS" 'any(.bounded.initial[]?; .harness == $harness)' \
    "$CONFIG/crew-execution.json" >/dev/null; then
    case "$MODEL:$EFFORT" in :*|default:*|*:|*:default)
      fm_execution_error "configured initial harness requires explicit model and effort"
      return 1 ;;
    esac
  fi
  if jq -e --arg harness "$HARNESS" --arg model "${MODEL:-default}" \
    --arg effort "${EFFORT:-default}" '
      any(.bounded.initial[]?; . == {harness:$harness,model:$model,effort:$effort})
    ' "$CONFIG/crew-execution.json" >/dev/null; then EXECUTION_BOUNDED=1; fi
}

fm_execution_restart_contract() {
  local record=$1 source=$2
  [ -n "$EXECUTION_RESTART" ] || return 0
  [ "$MODE" = "$(fm_meta_get "$STATE/$source.meta" mode)" ] &&
    [ "$YOLO" = "$(fm_meta_get "$STATE/$source.meta" yolo)" ] ||
    { fm_execution_error "restart must preserve source delivery mode and yolo posture"; return 1; }
  EXECUTION_BASE=$(jq -r '.base' "$record")
  [ -n "$EXECUTION_BASE" ] ||
    { fm_execution_error "original base was not captured"; return 1; }
}

fm_execution_continue() {
  local record=$1 source=$2
  [ "$KIND:$RAW_LAUNCH" = ship:0 ] ||
    { fm_execution_error "bounded execution requires a canonical ship harness"; return 1; }
  [ "$RELAUNCH" = 1 ] || [ -n "$EXECUTION_RESTART" ] ||
    { fm_execution_error "enrolled task must use its classified continuation"; return 1; }
  jq -e --arg project "$PROJ_ABS" '.project == $project' "$record" >/dev/null ||
    { fm_execution_error "restart project differs from original project"; return 1; }
  fm_execution_restart_contract "$record" "$source" || return 1
  EXECUTION_LAUNCH_TICKET=${FM_EXECUTION_TICKET:-}
  if [ -z "$EXECUTION_LAUNCH_TICKET" ]; then
    EXECUTION_LAUNCH_TICKET=$(fm_execution_cli _prepare "$source" "$ID" \
      "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}") || return 1
  fi
}

fm_execution_launch_intent() {
  local record=$1
  [ "$MODE" = no-mistakes ] || return 0
  CAPTAIN_INTENT=$(fm_brief_task_heading_body \
    "${record%/*}/execution-original.md" "## Captain's intent")
  [ -n "$CAPTAIN_INTENT" ] ||
    { fm_execution_error "bounded no-mistakes needs explicit original captain intent"; return 1; }
}

fm_execution_begin() {
  [ "$KIND:$RAW_LAUNCH" = ship:0 ] ||
    { fm_execution_error "bounded execution requires a canonical ship harness"; return 1; }
  [ "$RELAUNCH" = 0 ] && [ -z "$EXECUTION_RESTART" ] ||
    { fm_execution_error "cannot enroll an existing task as a fresh attempt"; return 1; }
  fm_execution_cli _enroll "$ID" "$PROJ_ABS" \
    "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}"
}

fm_execution_spawn_prepare() {
  local record rc source
  fm_execution_validate "$CONFIG/crew-execution.json" || return 1
  EXECUTION_ACTIVE=0
  EXECUTION_BASE=
  EXECUTION_LAUNCH_TICKET=
  source=${EXECUTION_RESTART:-$ID}
  if record=$(fm_execution_record "$source"); then rc=0; else rc=$?; fi
  case "$rc:$RELAUNCH:$EXECUTION_RESTART" in 2:1:) return 0 ;; esac
  case "$rc" in
    2)
      fm_execution_initial_profile || return 1
      [ "$EXECUTION_BOUNDED" = 1 ] || [ -n "$EXECUTION_RESTART" ] || return 0
      fm_execution_begin || return 1 ;;
    0) fm_execution_continue "$record" "$source" || return 1 ;;
    *) return 1 ;;
  esac
  record=$(fm_execution_record "$ID") || return 1
  fm_execution_launch_intent "$record" || return 1
  fm_execution_cli _consume "$ID" "$EXECUTION_LAUNCH_TICKET" \
    "$HARNESS" "${MODEL:-default}" "${EFFORT:-default}" || return 1
  EXECUTION_ACTIVE=1
}
