#!/usr/bin/env bash
# Proves the resume path of lua/autocompact.lua on a live Maki, without
# waiting for a real 300k-token compaction.
#
# How: an isolated config dir (XDG_CONFIG_HOME) loads the real plugin, then a
# probe fires the two events a real compaction fires -- "AutoCompacting" for
# Maki's own trigger, "CompactionDone" for the summary -- and the plugin's own
# handler does the rest. Nothing is summarised, the context is untouched.
#
# Expected matrix:
#   A  CompactionDone alone            -> 0 resumes  (manual /compact)
#   B  cancelled turn, then auto       -> 0 resumes  (Esc means stop)
#   C  two auto compactions            -> 1 resume   (resume_min_gap_secs)
#   D  native auto-compaction          -> 1 resume   (the point of the plugin)
#   E  resume = false                  -> 0 resumes  (the off switch)
#
# Negative control, for the harness itself: append `this is not lua` to the
# copied plugin and Maki prints "syntax error" on stderr, so a silent run
# really means the plugin loaded.
#
# A resume that lands after the run ends is lost with the process, so each
# case keeps the turn alive long enough for the 1 s defer to fire, and a case
# whose probe never ran is retried once.
#
# Costs five short model calls. Exits non-zero on any mismatch.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CFG=$(mktemp -d)
LOG="$HOME/.local/logs/maki/maki.log"
trap 'rm -rf "$CFG"' EXIT

mkdir -p "$CFG/maki/lua"
cp lua/autocompact.lua lua/ocgo.lua lua/tps.lua "$CFG/maki/lua/"
cp plugin.toml "$CFG/maki/plugin.toml"
printf 'require("ocgo")\nrequire("tps")\nrequire("autocompact")\nrequire("selftest")\n' \
  > "$CFG/maki/init.lua"

PROMPT="List the numbers from 1 to 80 separated by spaces, then stop."
HEAD='local sid = maki.session.current() maki.log.info("selftest: session " .. tostring(sid))'
DONE='maki.api.exec_autocmds("CompactionDone", { data = { session_id = sid, context_size_before = 300800, context_size_after = 30000, context_window = 1000000 } })'
AUTO='maki.api.exec_autocmds("AutoCompacting", { data = { session_id = sid } })'

# One real run. Prints "<probe ran> <resumes>", both counted from the log the
# run appended to.
attempt() {
  local body="$1" before delta
  printf 'maki.defer_fn(function() %s %s end, 500)\n' "$HEAD" "$body" > "$CFG/maki/lua/selftest.lua"
  before=$(wc -l < "$LOG")
  XDG_CONFIG_HOME="$CFG" timeout 120 maki -p "$PROMPT" --max-turns 1 >/dev/null 2>/dev/null
  delta=$(tail -n +$((before + 1)) "$LOG")
  printf '%s %s\n' \
    "$(printf '%s\n' "$delta" | grep -c 'selftest: session')" \
    "$(printf '%s\n' "$delta" | grep -c 'autocompact: resume woke')"
}

case_run() {
  local name="$1" want="$2" body="$3" attempt_no ran got
  ran=0
  got=0
  for attempt_no in 1 2; do
    read -r ran got <<<"$(attempt "$body")"
    if [ "$ran" -eq 0 ]; then
      continue # the probe never fired: the session was not up yet
    fi
    if [ "$got" -eq "$want" ]; then
      printf '  ok    %-34s resume=%s\n' "$name" "$got"
      return 0
    fi
  done
  printf '  FAIL  %-34s resume=%s (want %s)\n' "$name" "$got" "$want"
  return 1
}

echo "resume matrix (isolated config: $CFG)"
fail=0
case_run "A manual /compact"        0 "$DONE" || fail=1
case_run "B cancelled turn"         0 "maki.api.exec_autocmds(\"TurnEnd\", { data = { session_id = sid, reason = \"cancelled\" } }) $AUTO $DONE" || fail=1
case_run "C two auto compactions"   1 "$AUTO $DONE $AUTO $DONE" || fail=1
case_run "D native auto-compaction" 1 "$AUTO $DONE" || fail=1
case_run "E resume = false"         0 "require(\"autocompact\").setup({ resume = false }) $AUTO $DONE" || fail=1

if [ "$fail" -eq 0 ]; then
  echo "resume matrix: ok"
else
  echo "resume matrix: FAILED"
fi
exit "$fail"
