#!/usr/bin/env bash
# Portable executable lifecycle tests; fake runtime boundaries never launch models.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-execution)
EXECUTION="$ROOT/bin/fm-execution.sh"

setup() {
  CASE_DIR="$TMP_ROOT/$1"
  TASK_HOME="$CASE_DIR/home"
  PROJECT="$CASE_DIR/project"
  WORKTREE="$CASE_DIR/wt"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$TASK_HOME" codex
  fm_test_spawn_brief "$TASK_HOME" initial 'Implement the specified behavior.'
  fm_git_worktree "$PROJECT" "$WORKTREE" "test-$1"
  jq -n '{version:1, harness_instructions:{codex:"TARGETED EXECUTION INSTRUCTIONS"},
    bounded:{initial:[{harness:"codex",model:"test-initial",effort:"max"}],
      repair:{harness:"codex",model:"test-repair",effort:"high"}}}' \
    >"$TASK_HOME/config/crew-execution.json"
  printf 'Reproduction: focused test failed with expected 2, actual 1.\n' >"$CASE_DIR/evidence"
}

execution() {
  FM_HOME="$TASK_HOME" PATH="$FAKEBIN:$PATH" "$EXECUTION" "$@"
}

spawn_initial() {
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$TASK_HOME" "$WORKTREE" "$FAKEBIN" initial "$PROJECT" \
      --harness codex --model test-initial --effort max --mode local-only --yolo off
}

seed_attempt() {
  fm_write_meta "$TASK_HOME/state/initial.meta" window=firstmate:fm-initial \
    endpoint_task_id=initial "worktree=$WORKTREE" "project=$PROJECT" harness=codex \
    kind=ship mode=local-only yolo=off spawn_gen=initial-generation
  execution _enroll initial "$PROJECT" codex test-initial max
  execution _consume initial '' codex test-initial max
  execution _base initial "$WORKTREE"
  execution _publish initial initial-generation
}

test_capacity_and_concurrency() {
  local future first second
  setup capacity
  seed_attempt
  future=$(($(date +%s) + 3600))
  execution classify initial capacity --evidence-file "$CASE_DIR/evidence" --retry-after "$future"
  if execution _prepare initial initial codex test-initial max; then
    fail 'capacity reset was ignored'
  fi
  setup concurrent
  seed_attempt
  execution classify initial salvageable --evidence-file "$CASE_DIR/evidence"
  execution _prepare initial initial codex test-repair high >"$CASE_DIR/one" 2>&1 &
  first=$!
  execution _prepare initial initial codex test-repair high >"$CASE_DIR/two" 2>&1 &
  second=$!
  first_rc=0; second_rc=0
  wait "$first" || first_rc=$?
  wait "$second" || second_rc=$?
  [ "$((first_rc + second_rc))" -gt 0 ] || fail 'both concurrent reservations succeeded'
  [ "$first_rc" = 0 ] || [ "$second_rc" = 0 ] || fail 'neither reservation succeeded'
  execution status initial | jq -e '.attempt == 2 and .phase == "reserved"' >/dev/null
  echo 'ok - reset guard and concurrent reservation use one repair allocation'
}

test_custody() {
  local branch ticket
  setup custody
  seed_attempt
  sed 's/mode=local-only/mode=no-mistakes/' "$TASK_HOME/state/initial.meta" >"$CASE_DIR/meta"
  cp "$CASE_DIR/meta" "$TASK_HOME/state/initial.meta"
  cat >"$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$FM_NM_OUTPUT"
SH
  chmod +x "$FAKEBIN/no-mistakes"
  export FM_NM_OUTPUT="$CASE_DIR/nm-output"
  branch=$(git -C "$WORKTREE" symbolic-ref --short HEAD)
  execution classify initial salvageable --evidence-file "$CASE_DIR/evidence"
  printf 'unknown response\n' >"$FM_NM_OUTPUT"
  if execution _prepare initial initial codex test-repair high; then fail 'unknown custody passed'; fi
  printf 'run:\n  branch: %s\n  status: running\nbranch_sync:\n  local:\n    branch: %s\n  state: synchronized\n  safety: already_synchronized\n' \
    "$branch" "$branch" >"$FM_NM_OUTPUT"
  if execution _prepare initial initial codex test-repair high; then fail 'active run passed'; fi
  printf 'current_branch: "%s"\nruns_on_current_branch: 0\n' "$branch" >"$FM_NM_OUTPUT"
  ticket=$(execution _prepare initial initial codex test-repair high)
  printf 'unknown response\n' >"$FM_NM_OUTPUT"
  if execution _consume initial "$ticket" codex test-repair high; then
    fail 'custody was not rechecked at launch'
  fi
  printf '%s\n' 'run:' "  branch: \"$branch\"" '  status: "failed"' \
    'branch_sync:' '  local:' "    branch: \"$branch\"" \
    '  state: "user_owned"' '  safety: "user_owned"' >"$FM_NM_OUTPUT"
  execution _consume initial "$ticket" codex test-repair high
  unset FM_NM_OUTPUT
  echo 'ok - unknown and active custody fail closed, including after reservation'
}

test_native_structural_restart() {
  local base successor
  setup structural
  # shellcheck disable=SC2016 # Fenced Markdown must retain literal backticks and escapes.
  printf '\n```sh\n# build the image\nprintf "literal\\n"\n```\n\n~~~sh\n# second fence\n~~~\nAFTER BOTH FENCES\n' \
    >>"$TASK_HOME/data/initial/brief.md"
  seed_attempt
  base=$(git -C "$WORKTREE" rev-parse HEAD)
  printf 'failed implementation\n' >"$WORKTREE/failed.txt"
  git -C "$WORKTREE" add failed.txt
  git -C "$WORKTREE" -c user.name=Test -c user.email=test@example.invalid \
    commit --quiet -m 'Record failed implementation'
  printf 'uncommitted failed work\n' >"$WORKTREE/unfinished.txt"
  successor="$CASE_DIR/successor"
  git -C "$PROJECT" worktree add --quiet -b successor "$successor" \
    "$(git -C "$WORKTREE" rev-parse HEAD)"
  [ "$(git -C "$successor" rev-parse HEAD)" != "$base" ] || fail 'fixture did not diverge'
  fm_test_spawn_brief "$TASK_HOME" successor 'This is deliberately not the original request.'
  # shellcheck disable=SC2016 # Literal Markdown fence, not shell command substitution.
  printf '\n```sh\n# target comment\nTARGET SNIPPET MUST DISAPPEAR\n```\n' \
    >>"$TASK_HOME/data/successor/brief.md"
  printf '\n# Status\nWrite to successor status only.\n' >>"$TASK_HOME/data/successor/brief.md"
  execution classify initial structural --evidence-file "$CASE_DIR/evidence"
  fm_test_run_spawn "$TASK_HOME" "$successor" "$FAKEBIN" successor "$PROJECT" \
    --restart-from initial --harness codex --model test-repair --effort high \
    --mode local-only --yolo off >"$CASE_DIR/restart.out" 2>&1 ||
    { cat "$CASE_DIR/restart.out"; fail 'native structural restart failed'; }
  [ "$(git -C "$successor" rev-parse HEAD)" = "$base" ] || fail 'wrong clean base'
  [ -f "$WORKTREE/failed.txt" ] && [ -f "$WORKTREE/unfinished.txt" ] || fail 'failed work lost'
  assert_grep 'Implement the specified behavior' "$TASK_HOME/data/successor/launch-brief.md" \
    'restart must retain original intent'
  assert_grep 'Write to successor status only' "$TASK_HOME/data/successor/launch-brief.md" \
    'restart must retain target status routing'
  assert_grep 'AFTER BOTH FENCES' "$TASK_HOME/data/successor/launch-brief.md" \
    'restart must preserve text after fenced headings'
  assert_grep 'Exercise the spawn behavior under test.' "$TASK_HOME/data/successor/launch-brief.md" \
    'restart must preserve original firstmate specification'
  assert_no_grep 'TARGET SNIPPET MUST DISAPPEAR' "$TASK_HOME/data/successor/launch-brief.md" \
    'replacement must remove the full fenced target Task section'
  if grep -q 'deliberately not the original' "$TASK_HOME/data/successor/launch-brief.md"; then
    fail 'restart changed original requirements'
  fi
  execution status successor | jq -e '.attempt == 2 and .current == "successor"' >/dev/null
  echo 'ok - native clean restart preserves original base, failed work and target contract'
}

test_native_enrollment() {
  setup enrollment
  spawn_initial >"$CASE_DIR/spawn.out" 2>&1 || { cat "$CASE_DIR/spawn.out"; exit 1; }
  execution status initial >"$CASE_DIR/status"
  jq -e '.phase == "running" and .attempt == 1 and (.base | length > 0)' \
    "$CASE_DIR/status" >/dev/null
  assert_grep 'TARGETED EXECUTION INSTRUCTIONS' "$TASK_HOME/data/initial/launch-brief.md" \
    'initial worker must receive configured execution instructions'
  if execution _prepare initial initial codex test-repair high >"$CASE_DIR/refusal" 2>&1; then
    echo 'unclassified repair was accepted' >&2; exit 1
  fi
  execution classify initial salvageable --evidence-file "$CASE_DIR/evidence"
  if execution classify initial capacity --evidence-file "$CASE_DIR/evidence"; then
    echo 'duplicate classification was accepted' >&2; exit 1
  fi
  if execution _prepare initial initial codex test-initial max; then
    echo 'wrong repair model was accepted' >&2; exit 1
  fi
  ticket=$(execution _prepare initial initial codex test-repair high)
  if execution _prepare initial initial codex test-repair high; then
    echo 'duplicate reservation was accepted' >&2; exit 1
  fi
  execution _consume initial "$ticket" codex test-repair high
  if execution _consume initial "$ticket" codex test-repair high; then
    echo 'duplicate ticket was accepted' >&2; exit 1
  fi
  generation=repaired-generation
  sed 's/^spawn_gen=.*/spawn_gen=repaired-generation/' "$TASK_HOME/state/initial.meta" \
    >"$CASE_DIR/meta"
  cp "$CASE_DIR/meta" "$TASK_HOME/state/initial.meta"
  execution _publish initial "$generation"
  execution classify initial salvageable --evidence-file "$CASE_DIR/evidence"
  if execution _prepare initial initial codex test-repair high; then
    echo 'third implementation attempt was accepted' >&2; exit 1
  fi
  echo 'ok - native enrollment, mandatory classification, finite attempts and tickets'
}

test_config_validation() {
  setup config
  execution validate
  jq '.bounded.repair = .bounded.initial[0]' "$TASK_HOME/config/crew-execution.json" \
    >"$CASE_DIR/invalid"
  cp "$CASE_DIR/invalid" "$TASK_HOME/config/crew-execution.json"
  if execution validate; then echo 'overlapping profiles accepted' >&2; exit 1; fi
  if spawn_initial >"$CASE_DIR/refusal" 2>&1; then
    echo 'invalid config launched a worker' >&2; exit 1
  fi
  [ ! -e "$TASK_HOME/state/initial.meta" ]
  echo 'ok - malformed policy refuses before metadata publication'
}

test_immutable_policy_and_safe_snapshots() {
  local ticket
  setup immutable
  seed_attempt
  mv "$TASK_HOME/config/crew-execution.json" "$CASE_DIR/removed-config"
  execution classify initial capacity --evidence-file "$CASE_DIR/evidence"
  ticket=$(execution _prepare initial initial codex test-initial max)
  execution _consume initial "$ticket" codex test-initial max
  sed 's/spawn_gen=initial-generation/spawn_gen=recovered-generation/' \
    "$TASK_HOME/state/initial.meta" >"$CASE_DIR/meta"
  cp "$CASE_DIR/meta" "$TASK_HOME/state/initial.meta"
  execution _publish initial recovered-generation
  execution classify initial capacity --evidence-file "$CASE_DIR/evidence"
  if execution _prepare initial initial codex test-initial max; then
    fail 'second capacity recovery was accepted after config removal'
  fi
  setup unsafe-snapshot
  ln -s "$CASE_DIR/must-not-exist" "$TASK_HOME/data/initial/execution-original.md"
  if execution _enroll initial "$PROJECT" codex test-initial max; then
    fail 'dangling original snapshot symlink was followed'
  fi
  [ ! -e "$CASE_DIR/must-not-exist" ] || fail 'symlink target was created'
  if compgen -G "$TASK_HOME/data/initial/.execution.*" >/dev/null; then
    fail 'failed enrollment left a temporary file behind'
  fi
  echo 'ok - enrollment policy survives config removal and snapshots cannot follow links'
}

test_config_validation
test_native_enrollment
test_capacity_and_concurrency
test_custody
test_native_structural_restart
test_immutable_policy_and_safe_snapshots
