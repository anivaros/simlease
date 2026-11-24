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
  export PREP_LOG="$WORK/prep.log"
  mkdir -p "$STUB_DIR" "$WORK/bin"
  : > "$STUB_DIR/calls.log"
  cp "$ROOT/test/stub/xcrun" "$WORK/bin/xcrun"
  printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/open"
  chmod +x "$WORK/bin/xcrun" "$WORK/bin/open"
  export PATH="$WORK/bin:$ORIGINAL_PATH"
  unset STUB_BOOTSTATUS_HANG STUB_PROBE_FAIL STUB_ERASE_FAIL SIMLEASE_PREPARE_TIMEOUT
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

teardown() {
  if [[ -f "$WORK/app.pid" ]]; then
    kill "$(cat "$WORK/app.pid")" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}

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

heartbeat_of() { jq .heartbeat_at "$(lease "$1")"; }

edit_config() { jq "$@" "$SIMLEASE_CONFIG" > "$WORK/t" && mv "$WORK/t" "$SIMLEASE_CONFIG"; }

sticky_pool() { edit_config '.pools.test.sticky = true'; }

erase_pool() { edit_config '.pools.test.on_owner_change = "erase"'; }

set_prepare() { edit_config --arg cmd "$1" '.pools.test.prepare = $cmd'; }

# Logs "<event> <udid> <purpose>" and prints noise that must not reach acquire's stdout.
PREP_RECORDER='echo "$SIMLEASE_POOL_EVENT $SIMLEASE_UDID $SIMLEASE_PURPOSE" >> "$PREP_LOG"; echo noise'

calls_of() { grep -cx "simctl $1" "$STUB_DIR/calls.log" || true; }

last_line_of() { grep -nx "simctl $1" "$STUB_DIR/calls.log" | tail -1 | cut -d: -f1; }

last_owner_of() { cat "$SIMLEASE_STATE_DIR/last/$1"; }

# simlease treats a process whose executable lives under .../Devices/<udid>/ as an app running on that device.
run_app_on() {
  mkdir -p "$WORK/Devices/$1/data/Containers"
  ln -s "$(command -v sleep)" "$WORK/Devices/$1/data/Containers/App"
  "$WORK/Devices/$1/data/Containers/App" 60 &
  echo $! > "$WORK/app.pid"
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
  ( set -e; "$name" ) > "$WORK/out.log" 2>&1
  rc=$?
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

test_sticky_prefers_last_owner() {
  sticky_pool
  expect "a gets SE 1" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  OWNER=a sl release SE-1
  expect "last owner recorded" [ "$(last_owner_of SE-1)" = a ]
  expect "b gets a device nobody used" [ "$(OWNER=b sl acquire --purpose test)" = SE-2 ]
  expect "a gets its device back" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
}

test_sticky_handover_notes_previous_owner() {
  sticky_pool
  edit_config '.pools.test.max_devices = 1'
  OWNER=a sl acquire --purpose test >/dev/null 2>"$WORK/first.err"
  expect "no note for a never-used device" [ "$(grep -c 'was last used by' "$WORK/first.err")" = 0 ]
  OWNER=a sl release SE-1
  OWNER=a sl acquire --purpose test >/dev/null 2>"$WORK/own.err"
  expect "no note for the same owner" [ "$(grep -c 'was last used by' "$WORK/own.err")" = 0 ]
  OWNER=a sl release SE-1
  expect "b gets a's device" [ "$(OWNER=b sl acquire --purpose test 2>"$WORK/other.err")" = SE-1 ]
  expect "b is told who used it" grep -q 'SE-1) was last used by a;' "$WORK/other.err"
  expect "nothing was erased" [ "$(calls_of 'erase SE-1')" = 0 ]
}

test_sticky_same_owner_reacquire_returns_same_device() {
  sticky_pool
  OWNER=a sl acquire --purpose test >/dev/null
  expect "same device again" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  expect "exactly one lease" [ "$(ls "$SIMLEASE_STATE_DIR/leases" | wc -l | tr -d ' ')" = 1 ]
  set_state SE-1 Shutdown
  expect "shut-down held device comes back" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  expect "and is booted again" [ "$(state_of SE-1)" = Booted ]
  expect "still one lease" [ "$(ls "$SIMLEASE_STATE_DIR/leases" | wc -l | tr -d ' ')" = 1 ]
}

test_sticky_reacquire_refreshes_heartbeat() {
  sticky_pool
  OWNER=a sl acquire --purpose test >/dev/null
  age_lease SE-1
  expect "expired own lease: same device" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  expect "heartbeat refreshed" [ "$(heartbeat_of SE-1)" -gt 1 ]
}

test_sticky_expired_lease_returns_same_device_without_erase() {
  sticky_pool
  erase_pool
  OWNER=a sl acquire --purpose test >/dev/null
  age_lease SE-1
  expect "same device after expiry" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  OWNER=a sl release SE-1
  expect "same device after release" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  expect "erased only on first use" [ "$(calls_of 'erase SE-1')" = 1 ]
}

test_non_sticky_pool_unchanged() {
  OWNER=a sl acquire --purpose test >/dev/null
  OWNER=a sl release SE-1
  expect "b gets SE 1 as before" [ "$(OWNER=b sl acquire --purpose test)" = SE-1 ]
  expect "a second acquire leases another device" [ "$(OWNER=b sl acquire --purpose test)" = SE-2 ]
  expect "nothing erased" [ "$(grep -c ' erase ' "$STUB_DIR/calls.log" || true)" = 0 ]
}

test_owner_change_erases() {
  erase_pool
  edit_config '.pools.test.max_devices = 1'
  OWNER=a sl acquire --purpose test >/dev/null
  OWNER=a sl release SE-1
  expect "b gets the only device" [ "$(OWNER=b sl acquire --purpose test)" = SE-1 ]
  expect "erased for a and again for b" [ "$(calls_of 'erase SE-1')" = 2 ]
  expect "erase before the last boot" [ "$(last_line_of 'erase SE-1')" -lt "$(last_line_of 'boot SE-1')" ]
  OWNER=b sl release SE-1
  OWNER=b sl acquire --purpose test >/dev/null
  expect "no erase when the owner is the same" [ "$(calls_of 'erase SE-1')" = 2 ]
}

test_owner_change_first_use_erases() {
  erase_pool
  set_state SE-1 Booted
  expect "first device" [ "$(sl acquire --purpose test)" = SE-1 ]
  expect "erased on first use" [ "$(calls_of 'erase SE-1')" = 1 ]
  expect "booted after the erase" [ "$(state_of SE-1)" = Booted ]
  expect "lease records a fresh boot" [ "$(jq -r .was_booted "$(lease SE-1)")" = false ]
}

test_busy_device_not_erased() {
  erase_pool
  OWNER=a sl acquire --purpose test >/dev/null
  OWNER=a sl release SE-1
  run_app_on SE-1
  expect "b skips the device with a running app" [ "$(OWNER=b sl acquire --purpose test)" = SE-2 ]
  expect "busy device not erased again" [ "$(calls_of 'erase SE-1')" = 1 ]
  expect "the device b got was erased for b" [ "$(calls_of 'erase SE-2')" = 1 ]
  expect "no lease on the busy device" [ ! -f "$(lease SE-1)" ]
}

test_erase_failure_skips_device() {
  erase_pool
  export STUB_ERASE_FAIL=SE-1
  expect "next device" [ "$(sl acquire --purpose test)" = SE-2 ]
  expect "erase of SE 1 was attempted" [ "$(calls_of 'erase SE-1')" = 1 ]
  expect "no lease on SE 1" [ ! -f "$(lease SE-1)" ]
  expect "no locks left behind" [ -z "$(ls "$SIMLEASE_STATE_DIR/locks")" ]
}

test_prepare_runs_after_erase() {
  sticky_pool
  erase_pool
  set_prepare "$PREP_RECORDER"
  expect "only the UDID on stdout" [ "$(OWNER=a sl acquire --purpose test)" = SE-1 ]
  expect "prepare saw the erase" [ "$(cat "$PREP_LOG")" = "erased SE-1 test" ]
  OWNER=a sl acquire --purpose test >/dev/null
  OWNER=a sl release SE-1
  OWNER=a sl acquire --purpose test >/dev/null
  expect "prepare ran once" [ "$(wc -l < "$PREP_LOG" | tr -d ' ')" = 1 ]
}

test_prepare_runs_after_create() {
  erase_pool
  set_prepare "$PREP_RECORDER"
  edit_config '.pools.test.auto_create = true | .pools.test.max_devices = 4'
  sl acquire --purpose test --count 3 >/dev/null
  local created
  created="$(awk -F'\t' '$2 == "iPhone SE 3" { print $1 }' "$STUB_DIR/devices.tsv")"
  expect "a device was created" [ -n "$created" ]
  expect "prepare saw the creation" grep -qx "created $created test" "$PREP_LOG"
  expect "created device not erased" [ "$(calls_of "erase $created")" = 0 ]
  expect "existing device prepared after its erase" grep -qx "erased SE-1 test" "$PREP_LOG"
  expect "fresh marker consumed" [ ! -e "$SIMLEASE_STATE_DIR/fresh/$created" ]
}

test_prepare_failure_is_not_fatal() {
  erase_pool
  set_prepare 'echo boom >&2; exit 7'
  local out
  out="$(sl acquire --purpose test 2>"$WORK/err")"
  expect "acquired anyway" [ "$out" = SE-1 ]
  expect "warning printed" grep -q 'prepare failed for SE-1 (exit 7); continuing' "$WORK/err"
  expect "lease written" [ -f "$(lease SE-1)" ]
  expect "no locks left behind" [ -z "$(ls "$SIMLEASE_STATE_DIR/locks")" ]
}

test_prepare_timeout_is_not_fatal() {
  erase_pool
  set_prepare 'sleep 30'
  export SIMLEASE_PREPARE_TIMEOUT=1
  local out start="$SECONDS"
  out="$(sl acquire --purpose test 2>"$WORK/err")"
  expect "acquired anyway" [ "$out" = SE-1 ]
  expect "timeout reported" grep -q 'prepare failed for SE-1 (exit 124)' "$WORK/err"
  expect "did not wait for the hung command" [ $(( SECONDS - start )) -lt 15 ]
  expect "no locks left behind" [ -z "$(ls "$SIMLEASE_STATE_DIR/locks")" ]
}

test_invalid_sticky_config_is_a_config_error() {
  edit_config '.pools.test.on_owner_change = "wipe"'
  local rc=0
  sl acquire --purpose test >/dev/null 2>&1 || rc=$?
  expect "exit 2" [ "$rc" = 2 ]
  expect "nothing booted" [ "$(state_of SE-1)" = Shutdown ]
}

test_heartbeat_all_mine() {
  OWNER=a sl acquire --purpose test --count 2 >/dev/null
  OWNER=b sl acquire --purpose visual >/dev/null
  age_lease SE-1
  age_lease SE-2
  age_lease PRO-1
  expect "prints nothing" [ -z "$(OWNER=a sl heartbeat --all-mine 2>&1)" ]
  expect "SE 1 refreshed" [ "$(heartbeat_of SE-1)" -gt 1 ]
  expect "SE 2 refreshed" [ "$(heartbeat_of SE-2)" -gt 1 ]
  expect "other session untouched" [ "$(heartbeat_of PRO-1)" = 1 ]
  age_lease SE-1
  OWNER=a sl heartbeat --all-mine --purpose visual
  expect "purpose filter respected" [ "$(heartbeat_of SE-1)" = 1 ]
  expect "no leases: silent success" [ -z "$(OWNER=nobody sl heartbeat --all-mine 2>&1)" ]
}

test_status_mine_prints_udids() {
  expect "nothing leased: empty" [ -z "$(OWNER=a sl status --mine --print udid)" ]
  OWNER=a sl acquire --purpose test --count 2 >/dev/null
  OWNER=b sl acquire --purpose visual >/dev/null
  expect "a's devices" [ "$(OWNER=a sl status --mine --print udid)" = "SE-1
SE-2" ]
  expect "purpose filter" [ -z "$(OWNER=a sl status --mine --print udid --purpose visual)" ]
  expect "b's device" [ "$(OWNER=b sl status --mine --print udid)" = PRO-1 ]
  age_lease PRO-1
  expect "stale lease not printed" [ -z "$(OWNER=b sl status --mine --print udid)" ]
  OWNER=a sl status --mine > "$WORK/table"
  expect "table shows mine" grep -q '^SE-1 ' "$WORK/table"
  expect "table hides others" [ -z "$(grep '^PRO-1 ' "$WORK/table" || true)" ]
}

test_last_owner_survives_release_and_gc() {
  OWNER=a sl acquire --purpose test >/dev/null
  OWNER=a sl release SE-1
  sl gc >/dev/null 2>&1
  expect "last owner kept" [ "$(last_owner_of SE-1)" = a ]
  awk -F'\t' '$1 != "SE-1"' "$STUB_DIR/devices.tsv" > "$STUB_DIR/t"
  mv "$STUB_DIR/t" "$STUB_DIR/devices.tsv"
  sl gc >/dev/null 2>&1
  expect "dropped once the device is gone" [ ! -f "$SIMLEASE_STATE_DIR/last/SE-1" ]
}

ORIGINAL_PATH="$PATH"
echo "simlease tests with $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"')"
for name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
  run_test "$name"
done
echo "$passed passed, $failed failed"
(( failed == 0 ))
