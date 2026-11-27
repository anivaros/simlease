#!/usr/bin/env bash
# Runs simlease against a fake `xcrun simctl` in a throwaway state directory.
# Usage: test/run.sh [bash 5 binary]   the default is the bash on PATH
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASH_BIN="${1:-bash}"
SE=com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation
PRO=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro
PRO_MAX=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
LATEST=com.apple.CoreSimulator.SimRuntime.iOS-27-1
OLDER=com.apple.CoreSimulator.SimRuntime.iOS-27-0

passed=0
failed=0

setup() {
  WORK="$(mktemp -d "$RUN_DIR/test.XXXXXX")"
  export STUB_DIR="$WORK/stub"
  export SIMLEASE_STATE_DIR="$WORK/state"
  export SIMLEASE_CONFIG="$WORK/config.json"
  export SIMLEASE_BOOTSTATUS_TIMEOUT=2
  export SIMLEASE_RESTART_PAUSE_SECONDS=0
  export SIMLEASE_SIM_DEVICES_DIR="$WORK/devices"
  export SIMLEASE_SIM_LOGS_DIR="$WORK/simlogs"
  mkdir -p "$STUB_DIR" "$WORK/bin"
  cp "$ROOT/test/stub/xcrun" "$WORK/bin/xcrun"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/open"
  chmod +x "$WORK/bin/xcrun" "$WORK/bin/open"
  export PATH="$WORK/bin:$ORIGINAL_PATH"
  unset STUB_BOOTSTATUS_HANG STUB_PROBE_FAIL STUB_SHUTDOWN_FAIL
  jq '.pools.test.auto_create = false | .pools.test.max_devices = 3' "$ROOT/config.example.json" > "$SIMLEASE_CONFIG"
  printf '%s\n' \
    "SE-1	iPhone SE 1	$SE	$LATEST	Shutdown" \
    "SE-2	iPhone SE 2	$SE	$LATEST	Shutdown" \
    "SE-OLD	iPhone SE 9	$SE	$OLDER	Shutdown" \
    "PROMAX-1	iPhone 17 Pro Max	$PRO_MAX	$LATEST	Shutdown" \
    "PRO-1	iPhone 17 Pro 1	$PRO	$LATEST	Shutdown" \
    "SE-XCODE	iPhone SE (3rd generation)	$SE	$LATEST	Shutdown" \
    "SE-COPY	iPhone SE 1 copy	$SE	$LATEST	Shutdown" \
    > "$STUB_DIR/devices.tsv"
}

teardown() { rm -rf "$WORK"; }

sl() { SIMLEASE_SESSION="${OWNER:-me}" "$BASH_BIN" "$ROOT/bin/simlease" "$@"; }

state_of() { awk -F'\t' -v udid="$1" '$1 == udid { print $5 }' "$STUB_DIR/devices.tsv"; }

set_state() {
  awk -F'\t' -v OFS='\t' -v udid="$1" -v state="$2" '$1 == udid { $5 = state } { print }' "$STUB_DIR/devices.tsv" > "$STUB_DIR/t"
  mv "$STUB_DIR/t" "$STUB_DIR/devices.tsv"
}

lease() { printf '%s/leases/%s.json' "$SIMLEASE_STATE_DIR" "$1"; }

age_lease() {
  jq '.heartbeat_at = 1' "$(lease "$1")" > "$WORK/t" && mv "$WORK/t" "$(lease "$1")"
}

expect() {
  local description="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "    expected: $description" >&2
  return 1
}

# Each test has its own WORK folder, stub and state, so tests run in parallel.
# The result goes to $RESULTS/<name>: "ok" or "FAIL" and the indented log.
run_test() {
  local name="$1"
  local rc=0
  setup
  # Not under `||`: bash ignores set -e in a subshell on the left of a list.
  ( set -e; "$name" ) > "$WORK/out.log" 2>&1
  rc=$?
  if (( rc == 0 )); then
    echo "ok   $name" > "$RESULTS/$name"
  else
    { echo "FAIL $name"; sed 's/^/    /' "$WORK/out.log"; } > "$RESULTS/$name"
  fi
  teardown
}

test_version_and_help() {
  sl version | grep -q '^simlease [0-9]'
  sl help 2>&1 | grep -q 'simlease acquire'
  local rc=0
  sl bogus >/dev/null 2>&1 || rc=$?
  expect "unknown command exits 2" [ "$rc" = 2 ]
}

test_old_bash_is_refused() {
  /bin/bash -c '(( BASH_VERSINFO[0] < 5 ))' || return 0
  local rc=0
  /bin/bash "$ROOT/bin/simlease" version > "$WORK/old-bash.log" 2>&1 || rc=$?
  expect "exit 2 under bash 3.2" [ "$rc" = 2 ]
  expect "says how to fix it" grep -q 'brew install bash' "$WORK/old-bash.log"
}

test_missing_config_is_a_config_error() {
  local rc=0
  SIMLEASE_CONFIG="$WORK/nope.json" sl status >/dev/null 2>&1 || rc=$?
  expect "exit 2" [ "$rc" = 2 ]
}

test_acquire_boots_and_leases_on_latest_runtime() {
  local udid
  udid="$(sl acquire --purpose test)"
  expect "first SE on latest runtime" [ "$udid" = SE-1 ]
  expect "device booted" [ "$(state_of SE-1)" = Booted ]
  expect "lease owner recorded" [ "$(jq -r .owner "$(lease SE-1)")" = me ]
  expect "older runtime untouched" [ "$(state_of SE-OLD)" = Shutdown ]
}

test_acquire_prefers_already_booted_device() {
  set_state SE-2 Booted
  expect "booted device first" [ "$(sl acquire --purpose test)" = SE-2 ]
}

test_visual_pool_matches_exact_model() {
  expect "17 Pro, never Pro Max" [ "$(sl acquire --purpose visual)" = PRO-1 ]
}

test_pool_takes_only_prefix_and_number_names() {
  set_state SE-XCODE Booted
  set_state SE-COPY Booted
  sl acquire --purpose test --count 2 >/dev/null
  expect "Xcode default device not leased" [ ! -f "$(lease SE-XCODE)" ]
  expect "copied device not leased" [ ! -f "$(lease SE-COPY)" ]
  expect "SE 1 leased" [ -f "$(lease SE-1)" ]
  expect "SE 2 leased" [ -f "$(lease SE-2)" ]
}

test_reclaim_unleased_refuses_device_outside_pool() {
  set_state SE-XCODE Booted
  mkdir -p "$SIMLEASE_STATE_DIR/booted"
  echo 1 > "$SIMLEASE_STATE_DIR/booted/SE-XCODE"
  local rc=0
  sl reclaim-unleased --purpose test SE-XCODE >/dev/null 2>&1 || rc=$?
  expect "exit 2" [ "$rc" = 2 ]
  expect "Xcode default device still booted" [ "$(state_of SE-XCODE)" = Booted ]
}

test_count_and_destination_output() {
  local out
  out="$(sl acquire --purpose test --count 2 --print destination)"
  expect "two destinations" [ "$out" = "platform=iOS Simulator,id=SE-1
platform=iOS Simulator,id=SE-2" ]
}

test_exhausted_pool_exits_3_without_leftover_leases() {
  OWNER=other sl acquire --purpose test >/dev/null
  local rc=0
  sl acquire --purpose test --count 2 >/dev/null 2>&1 || rc=$?
  expect "exit 3" [ "$rc" = 3 ]
  expect "partial lease released" [ ! -f "$(lease SE-2)" ]
  expect "other session keeps its lease" [ -f "$(lease SE-1)" ]
}

test_live_lease_is_never_handed_out_twice() {
  OWNER=a sl acquire --purpose test >/dev/null
  expect "second session gets the next device" [ "$(OWNER=b sl acquire --purpose test)" = SE-2 ]
}

test_release_shuts_down_test_device() {
  sl acquire --purpose test >/dev/null
  sl release SE-1
  expect "lease removed" [ ! -f "$(lease SE-1)" ]
  expect "device shut down" [ "$(state_of SE-1)" = Shutdown ]
}

fill_device_folders() {
  local data="$SIMLEASE_SIM_DEVICES_DIR/$1/data" path
  for path in tmp/a.log Library/Logs/b.log var/db/diagnostics/c var/db/uuidtext/d \
    Containers/Data/Application/APP/tmp/e Containers/Data/Application/APP/Documents/keep \
    Library/Preferences/keep.plist; do
    mkdir -p "$data/$(dirname "$path")"
    echo x > "$data/$path"
  done
  mkdir -p "$SIMLEASE_SIM_LOGS_DIR/$1"
  echo x > "$SIMLEASE_SIM_LOGS_DIR/$1/system.log"
}

scratch_files_of() {
  find "$SIMLEASE_SIM_DEVICES_DIR/$1/data/tmp" "$SIMLEASE_SIM_DEVICES_DIR/$1/data/Library/Logs" \
    "$SIMLEASE_SIM_DEVICES_DIR/$1/data/var/db" "$SIMLEASE_SIM_DEVICES_DIR/$1/data/Containers/Data/Application/APP/tmp" \
    "$SIMLEASE_SIM_LOGS_DIR/$1" -type f 2>/dev/null
}

test_release_cleans_logs_and_tmp_but_keeps_app_data() {
  fill_device_folders SE-1
  sl acquire --purpose test >/dev/null
  sl release SE-1
  expect "no logs or temp files left" [ -z "$(scratch_files_of SE-1)" ]
  expect "app documents kept" [ -f "$SIMLEASE_SIM_DEVICES_DIR/SE-1/data/Containers/Data/Application/APP/Documents/keep" ]
  expect "settings kept" [ -f "$SIMLEASE_SIM_DEVICES_DIR/SE-1/data/Library/Preferences/keep.plist" ]
}

test_failed_shutdown_is_cleaned_by_a_later_gc() {
  set_state SE-1 Booted
  fill_device_folders SE-1
  sl acquire --purpose test >/dev/null
  export STUB_SHUTDOWN_FAIL=1
  sl release SE-1 2>/dev/null
  expect "logs of the still booted device kept" [ -n "$(scratch_files_of SE-1)" ]
  expect "boot marker set for a later sweep" [ -f "$SIMLEASE_STATE_DIR/booted/SE-1" ]
  unset STUB_SHUTDOWN_FAIL
  set_state SE-1 Shutdown
  sl gc >/dev/null 2>&1
  expect "gc cleans the device once it is off" [ -z "$(scratch_files_of SE-1)" ]
  expect "boot marker cleared" [ ! -f "$SIMLEASE_STATE_DIR/booted/SE-1" ]
}

test_release_does_not_mark_hand_made_device_for_deletion() {
  sl acquire --purpose test >/dev/null
  sl release SE-1
  expect "no created marker" [ ! -e "$SIMLEASE_STATE_DIR/created/SE-1" ]
}

test_release_refuses_foreign_lease() {
  OWNER=other sl acquire --purpose test >/dev/null
  local rc=0
  sl release SE-1 >/dev/null 2>&1 || rc=$?
  expect "exit 4" [ "$rc" = 4 ]
  expect "lease kept" [ -f "$(lease SE-1)" ]
  sl release --force SE-1
  expect "--force releases" [ ! -f "$(lease SE-1)" ]
}

test_release_all_mine_only_touches_my_leases() {
  sl acquire --purpose test >/dev/null
  OWNER=other sl acquire --purpose test >/dev/null
  sl release --all-mine
  expect "mine released" [ ! -f "$(lease SE-1)" ]
  expect "other kept" [ -f "$(lease SE-2)" ]
}

keep_visual_booted() {
  jq '.pools.visual.release = "keep-booted"' "$SIMLEASE_CONFIG" > "$WORK/t" && mv "$WORK/t" "$SIMLEASE_CONFIG"
}

test_visual_release_shuts_down_device_by_default() {
  sl acquire --purpose visual >/dev/null
  sl release PRO-1
  expect "visual device shut down" [ "$(state_of PRO-1)" = Shutdown ]
}

test_keep_booted_release_keeps_device_booted() {
  keep_visual_booted
  sl acquire --purpose visual >/dev/null
  sl release PRO-1
  expect "visual device stays booted" [ "$(state_of PRO-1)" = Booted ]
}

test_heartbeat_extends_only_own_lease() {
  sl acquire --purpose test >/dev/null
  age_lease SE-1
  sl heartbeat SE-1
  expect "heartbeat refreshed" [ "$(jq .heartbeat_at "$(lease SE-1)")" -gt 1 ]
  local rc=0
  OWNER=other sl heartbeat SE-1 >/dev/null 2>&1 || rc=$?
  expect "foreign heartbeat refused" [ "$rc" = 4 ]
}

test_gc_reclaims_stale_test_lease() {
  OWNER=dead sl acquire --purpose test >/dev/null
  age_lease SE-1
  sl gc >/dev/null 2>&1
  expect "stale lease removed" [ ! -f "$(lease SE-1)" ]
  expect "device shut down" [ "$(state_of SE-1)" = Shutdown ]
}

# Runs one simlease function, for paths that the CLI cannot reach on time (races).
sl_function() {
  # eval, not `source <(…)`: bash 3.2 reads nothing from a process substitution there.
  # `|| exit` keeps errexit off inside the function, as at the real call sites.
  SIMLEASE_SESSION="${OWNER:-me}" "$BASH_BIN" -c 'eval "$(sed "/^command=/,\$d" "$1")"; shift; "$@" || exit' sl_function "$ROOT/bin/simlease" "$@"
}

test_stale_release_keeps_a_lease_that_is_live_again() {
  OWNER=other sl acquire --purpose test >/dev/null
  local rc=0
  # Same session as the lease owner, so only the liveness check can refuse.
  OWNER=other sl_function release_one SE-1 stale >/dev/null 2>"$WORK/err" || rc=$?
  expect "release refused" [ "$rc" = 1 ]
  expect "refused because the lease is live" grep -q 'is live again' "$WORK/err"
  expect "live lease kept" [ -f "$(lease SE-1)" ]
  expect "device still booted" [ "$(state_of SE-1)" = Booted ]
}

test_gc_keeps_live_lease() {
  OWNER=alive sl acquire --purpose test >/dev/null
  sl gc >/dev/null 2>&1
  expect "live lease kept" [ -f "$(lease SE-1)" ]
  expect "device still booted" [ "$(state_of SE-1)" = Booted ]
}

test_gc_keeps_stale_keep_booted_lease_unless_aggressive() {
  keep_visual_booted
  OWNER=dead sl acquire --purpose visual >/dev/null
  age_lease PRO-1
  sl gc >/dev/null 2>&1
  expect "visual lease kept" [ -f "$(lease PRO-1)" ]
  sl gc --aggressive >/dev/null 2>&1
  expect "--aggressive reclaims it" [ ! -f "$(lease PRO-1)" ]
}

fake_ps() {
  printf '%s\n' "$@" > "$WORK/ps.txt"
  printf '#!/bin/sh\ncat "%s"\n' "$WORK/ps.txt" > "$WORK/bin/ps"
  chmod +x "$WORK/bin/ps"
}

test_gc_reclaims_abandoned_device_with_running_app() {
  OWNER=dead sl acquire --purpose test >/dev/null
  sl acquire --purpose test >/dev/null
  rm "$(lease SE-2)"
  age_lease SE-1
  fill_device_folders SE-1
  fill_device_folders SE-2
  fake_ps "/Users/x/Library/Developer/CoreSimulator/Devices/SE-1/data/Containers/Bundle/Application/A/App.app/App" \
    "/Users/x/Library/Developer/CoreSimulator/Devices/SE-2/data/Containers/Bundle/Application/B/App.app/App"
  sl gc >/dev/null 2>&1
  expect "stale lease reclaimed" [ "$(state_of SE-1)" = Shutdown ]
  expect "reclaimed device cleaned" [ -z "$(scratch_files_of SE-1)" ]
  expect "unleased device swept" [ "$(state_of SE-2)" = Shutdown ]
  expect "swept device cleaned" [ -z "$(scratch_files_of SE-2)" ]
}

test_reclaim_unleased_cleans_device() {
  sl acquire --purpose test >/dev/null
  rm "$(lease SE-1)"
  fill_device_folders SE-1
  sl reclaim-unleased --purpose test SE-1 >/dev/null 2>&1
  expect "device shut down" [ "$(state_of SE-1)" = Shutdown ]
  expect "device cleaned" [ -z "$(scratch_files_of SE-1)" ]
}

test_acquire_skips_device_that_runs_an_app() {
  fake_ps "/Users/x/Library/Developer/CoreSimulator/Devices/SE-1/data/Containers/Bundle/Application/A/App.app/App"
  expect "next device without an app" [ "$(sl acquire --purpose test)" = SE-2 ]
  expect "device with an app not leased" [ ! -f "$(lease SE-1)" ]
}

test_gc_keeps_device_in_active_build() {
  OWNER=dead sl acquire --purpose test >/dev/null
  sl acquire --purpose test >/dev/null
  age_lease SE-1
  rm "$(lease SE-2)"
  old_created_marker SE-OLD
  fake_ps "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -destination id=SE-1" \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -destination id=SE-2" \
    "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -destination id=SE-OLD"
  sl gc >/dev/null 2>&1
  expect "stale lease kept" [ -f "$(lease SE-1)" ]
  expect "leased device still booted" [ "$(state_of SE-1)" = Booted ]
  expect "unleased device not swept" [ "$(state_of SE-2)" = Booted ]
  expect "idle auto-created device not deleted" device_exists SE-OLD
}

test_gc_leaves_devices_booted_outside_simlease() {
  set_state SE-2 Booted
  sl gc >/dev/null 2>&1
  expect "Xcode-booted device untouched" [ "$(state_of SE-2)" = Booted ]
}

test_gc_sweeps_unleased_device_simlease_booted() {
  sl acquire --purpose test >/dev/null
  rm "$(lease SE-1)"
  sl gc >/dev/null 2>&1
  expect "device shut down" [ "$(state_of SE-1)" = Shutdown ]
  expect "boot marker cleared" [ ! -f "$SIMLEASE_STATE_DIR/booted/SE-1" ]
}

test_gc_dry_run_changes_nothing() {
  OWNER=dead sl acquire --purpose test >/dev/null
  age_lease SE-1
  sl gc --dry-run | grep -q 'would reclaim'
  expect "lease kept" [ -f "$(lease SE-1)" ]
  expect "device still booted" [ "$(state_of SE-1)" = Booted ]
}

test_corrupt_lease_is_dropped_not_fatal() {
  mkdir -p "$SIMLEASE_STATE_DIR/leases"
  echo '{broken' > "$(lease SE-1)"
  sl status >/dev/null 2>&1
  expect "corrupt lease removed" [ ! -f "$(lease SE-1)" ]
  expect "device leasable again" [ "$(sl acquire --purpose test)" = SE-1 ]
}

test_stale_lock_is_reclaimed() {
  mkdir -p "$SIMLEASE_STATE_DIR/locks/SE-1"
  printf '999999\n1\ndead\n' > "$SIMLEASE_STATE_DIR/locks/SE-1/meta"
  expect "locked device acquired" [ "$(sl acquire --purpose test)" = SE-1 ]
  expect "lock dropped" [ ! -d "$SIMLEASE_STATE_DIR/locks/SE-1" ]
}

test_auto_create_adds_device_on_latest_runtime() {
  jq '.pools.test.auto_create = true | .pools.test.max_devices = 4' "$SIMLEASE_CONFIG" > "$WORK/t" && mv "$WORK/t" "$SIMLEASE_CONFIG"
  printf '%s\n' "SE-X3	iPhone SEx3	$SE	$LATEST	Shutdown" >> "$STUB_DIR/devices.tsv"
  sl acquire --purpose test --count 3 >/dev/null
  local created
  created="$(awk -F'\t' '$2 == "iPhone SE 3" { print $4 }' "$STUB_DIR/devices.tsv")"
  expect "iPhone SE 3 created on latest runtime" [ "$created" = "$LATEST" ]
  expect "marked as auto-created" [ "$(ls "$SIMLEASE_STATE_DIR/created" | wc -l | tr -d ' ')" = 1 ]
}

old_created_marker() {
  mkdir -p "$SIMLEASE_STATE_DIR/created"
  echo "iPhone SE 1" > "$SIMLEASE_STATE_DIR/created/$1"
  touch -t 200001010000 "$SIMLEASE_STATE_DIR/created/$1"
}

device_exists() { awk -F'\t' -v udid="$1" '$1 == udid { found = 1 } END { exit !found }' "$STUB_DIR/devices.tsv"; }

test_gc_deletes_idle_auto_created_device() {
  old_created_marker SE-1
  sl gc >/dev/null 2>&1
  expect "idle auto-created device deleted" [ -z "$(state_of SE-1)" ]
}

test_gc_does_not_delete_device_locked_by_a_live_acquire() {
  old_created_marker SE-1
  mkdir -p "$SIMLEASE_STATE_DIR/locks/SE-1"
  # An old stamp: a slow acquire can hold its lock longer than SIMLEASE_LOCK_STALE_SECONDS.
  printf '%s\n1\nother\n\n' "$$" > "$SIMLEASE_STATE_DIR/locks/SE-1/meta"
  sl gc >/dev/null 2>&1
  expect "locked device kept" device_exists SE-1
  expect "lock of the live owner kept" [ -d "$SIMLEASE_STATE_DIR/locks/SE-1" ]
}

test_gc_does_not_delete_booted_auto_created_device() {
  old_created_marker SE-1
  set_state SE-1 Booted
  sl gc >/dev/null 2>&1
  expect "device booted outside simlease kept" device_exists SE-1
}

test_gc_keeps_recently_released_auto_created_device() {
  old_created_marker SE-1
  sl acquire --purpose test >/dev/null
  sl release SE-1
  sl gc >/dev/null 2>&1
  expect "device released just now kept" device_exists SE-1
}

test_gc_keeps_auto_created_device_it_just_reclaimed() {
  old_created_marker SE-1
  OWNER=dead sl acquire --purpose test >/dev/null
  age_lease SE-1
  sl gc >/dev/null 2>&1
  expect "stale lease reclaimed" [ ! -f "$(lease SE-1)" ]
  expect "device kept for the TTL after reclaim" device_exists SE-1
}

test_max_booted_guard_stops_booting() {
  jq '.guards.max_booted_devices = 1' "$SIMLEASE_CONFIG" > "$WORK/t" && mv "$WORK/t" "$SIMLEASE_CONFIG"
  set_state PROMAX-1 Booted
  local rc=0
  sl acquire --purpose test >/dev/null 2>&1 || rc=$?
  expect "exit 3" [ "$rc" = 3 ]
  expect "nothing booted" [ "$(state_of SE-1)" = Shutdown ]
}

test_owned_lifecycle_cli() {
  local udid=11111111-1111-1111-1111-111111111111 out
  awk -F'\t' -v OFS='\t' -v id="$udid" '$1 == "SE-1" { $1 = id } { print }' "$STUB_DIR/devices.tsv" > "$STUB_DIR/t"
  mv "$STUB_DIR/t" "$STUB_DIR/devices.tsv"
  mkdir -p "$SIMLEASE_STATE_DIR/leases"
  jq -n --arg udid "$udid" --argjson now "$(date +%s)" '{udid:$udid,owner:"me",purpose:"test",heartbeat_at:$now,acquired_at:$now}' > "$(lease "$udid")"
  out="$(sl resume "$udid")" || return 1
  expect "resume returns the leased UUID" [ "$out" = "$udid" ] || return 1
  expect "resume boots the device" [ "$(state_of "$udid")" = Booted ] || return 1
  out="$(sl reboot "$udid")" || return 1
  expect "reboot returns the leased UUID" [ "$out" = "$udid" ] || return 1
  expect "reboot retains the lease" [ -f "$(lease "$udid")" ] || return 1
  expect "reboot leaves the device booted" [ "$(state_of "$udid")" = Booted ]
}

test_unhealthy_device_is_skipped() {
  export STUB_PROBE_FAIL=SE-1
  expect "next healthy device" [ "$(sl acquire --purpose test)" = SE-2 ]
  expect "no lease on unhealthy one" [ ! -f "$(lease SE-1)" ]
}

test_hanging_bootstatus_times_out() {
  export STUB_BOOTSTATUS_HANG=1
  local rc=0
  sl acquire --purpose test --count 1 >/dev/null 2>&1 || rc=$?
  expect "exit 3 instead of hanging" [ "$rc" = 3 ]
  expect "no locks left behind" [ -z "$(ls "$SIMLEASE_STATE_DIR/locks")" ]
}

test_bad_arguments_fail_before_leasing() {
  local rc=0
  sl acquire --purpose test --count 0 >/dev/null 2>&1 || rc=$?
  expect "exit 2" [ "$rc" = 2 ]
  rc=0
  sl acquire --purpose nope >/dev/null 2>&1 || rc=$?
  expect "unknown pool exits 2" [ "$rc" = 2 ]
  expect "nothing booted" [ "$(state_of SE-1)" = Shutdown ]
}

install_copy() {
  mkdir -p "$WORK/inst"
  cp "$ROOT/bin/simlease" "$WORK/inst/simlease"
  chmod 0755 "$WORK/inst/simlease"
}

update_copy() { SIMLEASE_UPDATE_URL="file://$1" "$BASH_BIN" "$WORK/inst/simlease" "${2:-update}"; }

test_update_replaces_installed_script() {
  install_copy
  sed 's/^SIMLEASE_VERSION=.*/SIMLEASE_VERSION="9.9.9"/' "$ROOT/bin/simlease" > "$WORK/new"
  update_copy "$WORK/new" upgrade | grep -q -- '-> 9.9.9'
  expect "new script installed" cmp -s "$WORK/new" "$WORK/inst/simlease"
  expect "still executable" [ -x "$WORK/inst/simlease" ]
  expect "no temp file left" [ "$(ls -A "$WORK/inst")" = simlease ]
  update_copy "$WORK/new" | grep -q 'up to date'
  expect "no temp file left when up to date" [ "$(ls -A "$WORK/inst")" = simlease ]
  local rc=0
  SIMLEASE_UPDATE_URL="file://$WORK/new" "$BASH_BIN" "$WORK/inst/simlease" update --dry-run >/dev/null 2>&1 || rc=$?
  expect "extra arguments are a usage error" [ "$rc" = 2 ]
}

test_update_rejects_each_kind_of_bad_download() {
  install_copy
  echo '<html>not found</html>' > "$WORK/junk"
  tail -n +2 "$ROOT/bin/simlease" > "$WORK/no-shebang"
  grep -v '^SIMLEASE_VERSION=' "$ROOT/bin/simlease" > "$WORK/no-version"
  awk 'NR == 2 { print "if then" } { print }' "$ROOT/bin/simlease" > "$WORK/syntax-error"
  awk '/^cmd_gc\(\) \{/ { exit } { print }' "$ROOT/bin/simlease" > "$WORK/truncated"
  awk '{ print } /^esac$/ { exit }' "$ROOT/bin/simlease" > "$WORK/cut-after-first-esac"
  local fixture rc
  for fixture in junk no-shebang no-version syntax-error truncated cut-after-first-esac missing; do
    rc=0
    update_copy "$WORK/$fixture" >/dev/null 2>&1 || rc=$?
    expect "$fixture rejected with exit 1" [ "$rc" = 1 ]
  done
  expect "installed script unchanged" cmp -s "$ROOT/bin/simlease" "$WORK/inst/simlease"
  expect "no temp file left" [ "$(ls -A "$WORK/inst")" = simlease ]
}

test_update_refuses_symlink_and_git_tracked_script() {
  install_copy
  sed 's/^SIMLEASE_VERSION=.*/SIMLEASE_VERSION="9.9.9"/' "$ROOT/bin/simlease" > "$WORK/new"
  mkdir -p "$WORK/link"
  ln -s "$WORK/inst/simlease" "$WORK/link/simlease"
  local rc=0
  SIMLEASE_UPDATE_URL="file://$WORK/new" "$BASH_BIN" "$WORK/link/simlease" update >/dev/null 2>&1 || rc=$?
  expect "symlink refused" [ "$rc" = 1 ]
  git -C "$WORK/inst" init -q
  update_copy "$WORK/new" >/dev/null
  expect "untracked script inside a repo updated" cmp -s "$WORK/new" "$WORK/inst/simlease"
  git -C "$WORK/inst" add simlease
  rc=0
  update_copy "$ROOT/bin/simlease" >/dev/null 2>&1 || rc=$?
  expect "git-tracked script refused" [ "$rc" = 1 ]
  expect "tracked script unchanged" cmp -s "$WORK/new" "$WORK/inst/simlease"
}

ORIGINAL_PATH="$PATH"
echo "simlease tests with $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"
# Every test folder lives in RUN_DIR, so an interrupted run also leaves nothing behind.
# set -m gives each test its own process group: stop_run then stops the test together
# with the simlease, stub and sleep processes it started.
RUN_DIR="$(mktemp -d)"
set -m
stop_run() {
  local pid
  for pid in $(jobs -p); do
    kill -TERM -- "-$pid" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf "$RUN_DIR"
}
trap stop_run EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
RESULTS="$RUN_DIR/results"
mkdir "$RESULTS"
jobs_max="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  while (( $(jobs -rp | wc -l) >= jobs_max )); do
    sleep 0.1
  done
  run_test "$name" &
done
wait
for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  if [[ ! -f "$RESULTS/$name" ]]; then
    echo "FAIL $name (no result)"
    failed=$(( failed + 1 ))
  elif head -n 1 "$RESULTS/$name" | grep -q '^ok '; then
    cat "$RESULTS/$name"
    passed=$(( passed + 1 ))
  else
    cat "$RESULTS/$name"
    failed=$(( failed + 1 ))
  fi
done
echo "$passed passed, $failed failed"
(( failed == 0 ))
