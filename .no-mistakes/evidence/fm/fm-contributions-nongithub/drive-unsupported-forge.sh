#!/usr/bin/env bash
# Drives fm-contributions.sh against a scratch FM home: one GitLab MR (task gitlab),
# one GitHub PR whose forge reads fail (task github). gh is a fake that logs calls.
set -euo pipefail
ROOT=$1
H=$(mktemp -d /tmp/fm-live.XXXX)
mkdir -p "$H"/{data,state,config,projects,fakebin}
printf '# Backlog\n\n## Queued\n' > "$H/data/backlog.md"
printf -- '- [ ] gitlab - Filed https://gitlab.com/chops/questions-page/-/merge_requests/13 (repo: sample) (kind: ship)\n' >> "$H/data/backlog.md"
printf -- '- [ ] github - Filed https://github.com/o/r/pull/7 (repo: sample) (kind: ship)\n' >> "$H/data/backlog.md"
printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh-calls"\nexit 1\n' "$H" > "$H/fakebin/gh"
chmod +x "$H/fakebin/"*
run() { PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$@"; }
for i in 1 2 3; do
  echo "== poll $i (both tasks in backlog) =="
  run "$ROOT/bin/fm-contributions.sh" poll || echo "poll rc=$?"
  echo "gh calls so far: $(wc -l < "$H/gh-calls" 2>/dev/null || echo 0); gitlab in gh calls: $(grep -c gitlab "$H/gh-calls" || true)"
done
echo "== durable GitLab record =="
jq -c . "$H/data/gitlab/contributions.json"
echo "== durable GitHub record error =="
jq -c '.records[0] | {url,checked_at,error}' "$H/data/github/contributions.json"
echo "== pending =="
run "$ROOT/bin/fm-contributions.sh" pending
echo "== task cleanup: remove both backlog lines =="
printf '# Backlog\n\n## Queued\n' > "$H/data/backlog.md"
sum1=$(sha256sum < "$H/data/gitlab/contributions.json")
for i in 4 5; do
  echo "== poll $i (after cleanup) =="
  run "$ROOT/bin/fm-contributions.sh" poll || echo "poll rc=$?"
done
sum2=$(sha256sum < "$H/data/gitlab/contributions.json")
[ "$sum1" = "$sum2" ] && echo "GitLab record unchanged after cleanup polls" || echo "GitLab record CHANGED"
echo "gitlab in gh calls: $(grep -c gitlab "$H/gh-calls" || true)"
echo "== bearings contributions (FM_BEARINGS_NOW) =="
run env FM_BEARINGS_NOW=2026-09-17T08:00:00Z "$ROOT/bin/fm-bearings-snapshot.sh" --json \
  | jq -c '.contributions | {known,checked,unmeasured,complete,proven_clear}'
echo "== first-sight after a fresh MR while budget=1 =="
printf -- '- [ ] gitlab2 - Filed https://gitlab.com/o/proms-relay/-/merge_requests/2 (repo: sample) (kind: ship)\n' >> "$H/data/backlog.md"
run env FM_CONTRIBUTIONS_BUDGET=1 "$ROOT/bin/fm-contributions.sh" poll || echo "poll rc=$?"
jq -c '.records[] | {url,checked_at,error}' "$H/data/gitlab2/contributions.json"
trash "$H"
