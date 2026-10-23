#!/usr/bin/env bash
# Runs simlease against a fake `xcrun simctl` in a throwaway state directory.
# Usage: test/run.sh [bash binary]   e.g. test/run.sh /bin/bash to cover bash 3.2
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
  WORK="$(mktemp -d)"
  export STUB_DIR="$WORK/stub"
  export SIMLEASE_STATE_DIR="$WORK/state"
  export SIMLEASE_CONFIG="$WORK/config.json"
  export SIMLEASE_BOOTSTATUS_TIMEOUT=2
  mkdir -p "$STUB_DIR" "$WORK/bin"
  cp "$ROOT/test/stub/xcrun" "$WORK/bin/xcrun"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/open"
  chmod +x "$WORK/bin/xcrun" "$WORK/bin/open"
  export PATH="$WORK/bin:$ORIGINAL_PATH"
  unset STUB_BOOTSTATUS_HANG STUB_PROBE_FAIL
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

run_test() {
  local name="$1"
  local rc=0
  setup
  ( set -e; "$name" ) > "$WORK/out.log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    passed=$(( passed + 1 ))
    echo "ok   $name"
  else
    failed=$(( failed + 1 ))
    echo "FAIL $name"
    sed 's/^/    /' "$WORK/out.log"
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

test_visual_release_keeps_device_booted() {
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

test_gc_keeps_live_lease() {
  OWNER=alive sl acquire --purpose test >/dev/null
  sl gc >/dev/null 2>&1
  expect "live lease kept" [ -f "$(lease SE-1)" ]
  expect "device still booted" [ "$(state_of SE-1)" = Booted ]
}

test_gc_keeps_stale_visual_lease_unless_aggressive() {
  OWNER=dead sl acquire --purpose visual >/dev/null
  age_lease PRO-1
  sl gc >/dev/null 2>&1
  expect "visual lease kept" [ -f "$(lease PRO-1)" ]
  sl gc --aggressive >/dev/null 2>&1
  expect "--aggressive reclaims it" [ ! -f "$(lease PRO-1)" ]
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

test_max_booted_guard_stops_booting() {
  jq '.guards.max_booted_devices = 1' "$SIMLEASE_CONFIG" > "$WORK/t" && mv "$WORK/t" "$SIMLEASE_CONFIG"
  set_state PROMAX-1 Booted
  local rc=0
  sl acquire --purpose test >/dev/null 2>&1 || rc=$?
  expect "exit 3" [ "$rc" = 3 ]
  expect "nothing booted" [ "$(state_of SE-1)" = Shutdown ]
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

ORIGINAL_PATH="$PATH"
echo "simlease tests with $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"
for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  run_test "$name"
done
echo "$passed passed, $failed failed"
(( failed == 0 ))
