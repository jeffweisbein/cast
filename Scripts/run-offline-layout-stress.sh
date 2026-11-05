#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
strategy=${1:-detached-lazy}
iterations=${2:-360}

case "$strategy" in
  safe-area-lazy|detached-lazy|detached-eager) ;;
  *)
    print -u2 "usage: $0 [safe-area-lazy|detached-lazy|detached-eager] [iterations]"
    exit 64
    ;;
esac

if [[ ! "$iterations" =~ '^[0-9]+$' ]] || (( iterations < 1 )); then
  print -u2 "iterations must be a positive integer"
  exit 64
fi

run_dir=$(mktemp -d "${TMPDIR:-/tmp}/cast-layout-stress.XXXXXX")
derived_data="$run_dir/DerivedData"
app_log="$run_dir/app.log"
cpu_log="$run_dir/cpu.log"
socket_log="$run_dir/sockets.log"
sample_log="$run_dir/hang.sample.txt"
app_pid=""
launcher_pid=""

cleanup() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
    kill "$app_pid" 2>/dev/null || true
  fi
  [[ -n "$launcher_pid" ]] && wait "$launcher_pid" 2>/dev/null || true
  rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

print "Building unsigned arm64 Cast…"
xcodebuild \
  -project "$repo_dir/Cast.xcodeproj" \
  -scheme Cast-macOS \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build >"$run_dir/build.log"

app_bundle=${derived_data:A}/Build/Products/Debug/Cast.app
executable=${app_bundle:A}/Contents/MacOS/Cast
if [[ ! -x "$executable" ]]; then
  print -u2 "offline stress executable was not built"
  tail -80 "$run_dir/build.log" >&2
  exit 1
fi

print "Running offline layout stress: $strategy ($iterations iterations)…"
open -n -F -W \
  --stdout "$app_log" \
  --stderr "$app_log" \
  --env CAST_GATEWAY_TOKEN= \
  --env CAST_OFFLINE_LAYOUT_STRESS=1 \
  --env CAST_LAYOUT_STRATEGY="$strategy" \
  --env CAST_LAYOUT_STRESS_ITERATIONS="$iterations" \
  --env CAST_LAYOUT_STRESS_INTERVAL_MS=20 \
  --env CAST_LAYOUT_STRESS_WATCHDOG_MS=5000 \
  "$app_bundle" &
launcher_pid=$!

for _ in {1..100}; do
  app_pid=$(pgrep -f "^$executable" | tail -1 || true)
  [[ -n "$app_pid" ]] && break
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.1
done
if [[ -z "$app_pid" ]]; then
  print -u2 "LaunchServices did not start the offline stress app"
  cat "$app_log" >&2 || true
  exit 1
fi

start_seconds=$SECONDS
timeout_seconds=$(( iterations * 20 / 1000 + 45 ))
high_cpu_samples=0

fail_running_process() {
  local reason=$1
  print -u2 "$reason"
  if kill -0 "$app_pid" 2>/dev/null; then
    /usr/bin/sample "$app_pid" 2 -file "$sample_log" >/dev/null 2>&1 || true
    kill "$app_pid" 2>/dev/null || true
  fi
  print -u2 -- "--- app log ---"
  tail -80 "$app_log" >&2 || true
  if [[ -s "$sample_log" ]]; then
    print -u2 -- "--- sample (main-thread excerpts) ---"
    grep -En -m 30 'Call graph:|Thread_.*DispatchQueue_1|LazySubview|LazyStack|GraphHost|AttributeGraph|SwiftUI' "$sample_log" >&2 || true
  fi
  exit 1
}

while kill -0 "$app_pid" 2>/dev/null; do
  cpu=$(ps -p "$app_pid" -o %cpu= | tr -d ' ' || true)
  [[ -n "$cpu" ]] && print "$cpu" >>"$cpu_log"

  if [[ -n "$cpu" ]] && awk -v cpu="$cpu" 'BEGIN { exit !(cpu >= 90) }'; then
    (( high_cpu_samples += 1 ))
  else
    high_cpu_samples=0
  fi
  if (( high_cpu_samples >= 20 )); then
    fail_running_process "sustained >=90% CPU for four seconds ($strategy)"
  fi

  if lsof -nP -a -p "$app_pid" -i >"$socket_log" 2>/dev/null && [[ -s "$socket_log" ]]; then
    fail_running_process "offline stress opened an IP socket ($strategy)"
  fi
  if (( SECONDS - start_seconds > timeout_seconds )); then
    fail_running_process "external responsiveness timeout after ${timeout_seconds}s ($strategy)"
  fi
  sleep 0.2
done

set +e
wait "$launcher_pid"
launcher_status=$?
set -e
app_pid=""
launcher_pid=""

if (( launcher_status != 0 )) && ! grep -q "CAST_LAYOUT_STRESS_COMPLETE" "$app_log"; then
  print -u2 "offline stress launcher exited $launcher_status ($strategy)"
  tail -80 "$app_log" >&2 || true
  exit 1
fi
if ! grep -q "CAST_LAYOUT_STRESS_COMPLETE strategy=$strategy iterations=$iterations" "$app_log"; then
  print -u2 "offline stress exited without its completion marker ($strategy)"
  tail -80 "$app_log" >&2 || true
  exit 1
fi
if [[ -s "$socket_log" ]]; then
  print -u2 "offline stress produced network socket output ($strategy)"
  cat "$socket_log" >&2
  exit 1
fi

cpu_summary=$(awk '
  NR == 1 { min = max = $1 }
  { sum += $1; if ($1 < min) min = $1; if ($1 > max) max = $1 }
  END { if (NR) printf "samples=%d avg=%.1f%% max=%.1f%%", NR, sum / NR, max; else print "samples=0" }
' "$cpu_log")
print "CAST_LAYOUT_STRESS_GATE_PASS strategy=$strategy $cpu_summary"
