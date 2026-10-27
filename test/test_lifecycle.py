"""Isolated lifecycle regression checks. Never invoke real CoreSimulator."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import signal

SCRIPT = Path(__file__).resolve().parents[1] / "bin/simlease"
UID = "11111111-1111-1111-1111-111111111111"
SOURCE = SCRIPT.read_text().split('command="${1:-}"')[0]


def scenario(label, action="resume", initial="Shutdown", owner="fixture/owner",
             expired=False, missing=False, corrupt=False, mismatch=False,
             busy=False, unavailable=False, full=False, locked=False,
             shutdown_code=0, readiness_code=0, inventory_error=False, invalid_count=False, long_readiness=False, session="fixture/owner", uid=UID):
    with tempfile.TemporaryDirectory(prefix="simlease-lifecycle-") as name:
        root = Path(name)
        state = root / "state"
        lease_dir = state / "leases"
        lease_dir.mkdir(parents=True)
        lease = dict(udid="wrong" if mismatch else UID, owner=owner,
                     purpose="visual", heartbeat_at=int(time.time()) - (5000 if expired else 0),
                     acquired_at=123, was_booted=False, name="Fixture 1", worktree="fixture")
        path = lease_dir / (UID + ".json")
        if not missing:
            path.write_text("invalid" if corrupt else json.dumps(lease))
        before = path.read_text() if path.exists() else None
        config = root / "config.json"
        config.write_text(json.dumps({"pools": {"visual": dict(model="Fixture", runtime="fixture",
            name_prefix="Fixture", release="keep-booted", max_devices=1)},
            "guards": {"max_booted_devices": 1}}))
        trace = root / "trace"
        # Replace only external OS commands; lease checks, locks, guards and heartbeats stay real.
        overrides = r''' 
now() { printf '%s' "$FIXTURE_NOW"; }
pool_devices() { [[ "$FIXTURE_UNAVAILABLE" == 1 ]] || printf '%s\tFixture 1\t%s\n' "$FIXTURE_UUID" "$FIXTURE_STATE"; }
device_state() { printf '%s' "$FIXTURE_STATE"; }
device_in_active_build() { [[ "$FIXTURE_BUSY" == 1 ]]; }
booted_count() { [[ "$FIXTURE_INVENTORY_ERROR" != 1 ]] || return 67; [[ "$FIXTURE_INVALID_COUNT" != 1 ]] || { echo invalid; return; }; printf '%s' "$FIXTURE_FULL"; }
run_readiness_stage() { printf '%s\n' "$1" >> "$FIXTURE_TRACE"; return "$FIXTURE_SHUTDOWN_CODE"; }
boot_and_probe() {
  if [[ "$FIXTURE_LONG" == 1 ]]; then
    FIXTURE_NOW=$(( FIXTURE_NOW + 1000 ))
    ! lock_is_stale "$1" || return 91
    ! claim_lock "$1" lifecycle || return 92
    # A different process may not remove the active lifecycle lock.
    bash -c 'source "$FIXTURE_SOURCE"; drop_lock "$1"' fixture "$1" && return 93
    [[ -d "$LOCK_DIR/$1" ]] || return 94
  fi
  echo readiness >> "$FIXTURE_TRACE"; return "$FIXTURE_READINESS_CODE"; }
'''
        if locked:
            lock = state / "locks" / UID
            lock.mkdir(parents=True)
            (lock / "meta").write_text(f"{os.getpid()}\n{int(time.time())}\nother\n")
        source_file = root / "functions.sh"
        source_file.write_text(SOURCE)
        env = dict(os.environ, FIXTURE_SOURCE=str(source_file), FIXTURE_LONG=str(int(long_readiness)),
                   FIXTURE_INVENTORY_ERROR=str(int(inventory_error)), FIXTURE_INVALID_COUNT=str(int(invalid_count)), SIMLEASE_CONFIG=str(config), SIMLEASE_STATE_DIR=str(state),
                   SIMLEASE_SESSION=session, FIXTURE_NOW=str(int(time.time())), FIXTURE_UUID=UID,
                   FIXTURE_STATE=initial, FIXTURE_BUSY=str(int(busy)), FIXTURE_FULL=str(int(full)),
                   FIXTURE_UNAVAILABLE=str(int(unavailable)), FIXTURE_TRACE=str(trace),
                   FIXTURE_SHUTDOWN_CODE=str(shutdown_code), FIXTURE_READINESS_CODE=str(readiness_code))
        result = subprocess.run(["bash", "-c", SOURCE + overrides +
            '\ncmd_owned_lifecycle "$1" "$2"', "fixture", action, uid],
            env=env, capture_output=True, text=True, timeout=10)
        denied = (owner != session or not session or expired or missing or corrupt or mismatch or busy
                  or unavailable or locked or inventory_error or invalid_count or initial not in ("Booted", "Shutdown")
                  or (full and initial == "Shutdown") or uid != UID)
        expected = (2 if uid != UID else 4) if denied else (shutdown_code if action == "reboot" and initial == "Booted" and shutdown_code else readiness_code)
        assert result.returncode == expected, (label, result.returncode, expected, result.stderr)
        calls = trace.read_text().splitlines() if trace.exists() else []
        expected_calls = [] if denied else (["shutdown"] if action == "reboot" and initial == "Booted" else [])
        if not denied and not (shutdown_code and expected_calls):
            expected_calls.append("readiness")
        assert calls == expected_calls, (label, calls, expected_calls)
        if denied:
            assert (path.read_text() if path.exists() else None) == before, label
        elif path.exists():
            after = json.loads(path.read_text())
            assert {k: v for k, v in after.items() if k != "heartbeat_at"} == {k: v for k, v in lease.items() if k != "heartbeat_at"}, label
        assert (state / "locks" / UID).exists() == locked, label
        if expected:
            assert not result.stdout, (label, "false success")
        else:
            assert result.stdout.strip() == UID, label
        print("PASS", label)


for label, kwargs in [
    ("resume shutdown", {}), ("resume booted", dict(initial="Booted")),
    ("reboot booted", dict(action="reboot", initial="Booted")),
    ("reboot shutdown", dict(action="reboot")),
    ("foreign owner", dict(owner="other")), ("explicit owner required", dict(session="")),
    ("expired lease", dict(expired=True)), ("missing lease", dict(missing=True)),
    ("corrupt lease retained", dict(corrupt=True)), ("UUID mismatch", dict(mismatch=True)),
    ("active build", dict(busy=True)), ("unavailable target", dict(unavailable=True)),
    ("boot capacity", dict(full=True)), ("held lock", dict(locked=True)),
    ("transitional state", dict(initial="Shutting Down")),
    ("invalid UUID", dict(uid="../../other")),
    ("shutdown failure", dict(action="reboot", initial="Booted", shutdown_code=67)),
    ("readiness failure", dict(readiness_code=1)),
    ("capacity inventory fails closed", dict(inventory_error=True)),
    ("invalid inventory fails closed", dict(invalid_count=True)),
    ("live lifecycle lock survives timeout and foreign cleanup", dict(long_readiness=True)),
]:
    scenario(label, **kwargs)
print("21 scenarios passed; no real simulator commands executed")


def concurrent_capacity():
    with tempfile.TemporaryDirectory(prefix="simlease-capacity-") as name:
        root = Path(name)
        state = root / "state"
        (state / "leases").mkdir(parents=True)
        config = root / "config.json"
        config.write_text(json.dumps({"pools": {"visual": {"model": "Fixture", "runtime": "fixture", "name_prefix": "Fixture", "release": "keep-booted", "max_devices": 2}}, "guards": {"max_booted_devices": 1}}))
        ids = ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"]
        for uid in ids:
            (state / "leases" / f"{uid}.json").write_text(json.dumps({"udid": uid, "owner": "fixture/owner", "purpose": "visual", "heartbeat_at": int(time.time()), "acquired_at": 123}))
        overrides = r'''
device_state() { echo Shutdown; }
device_in_active_build() { return 1; }
booted_count() { [[ -f "$FIXTURE_BOOTED" ]] && echo 1 || echo 0; }
boot_and_probe() { sleep 1; : > "$FIXTURE_BOOTED"; }
pool_devices() { printf '%s\tFixture 1\tShutdown\n' "$FIXTURE_UUID"; }
'''
        processes = []
        for uid in ids:
            env = dict(os.environ, SIMLEASE_CONFIG=str(config), SIMLEASE_STATE_DIR=str(state), SIMLEASE_SESSION="fixture/owner", FIXTURE_BOOTED=str(root / "booted"), FIXTURE_UUID=uid)
            processes.append(subprocess.Popen(["bash", "-c", SOURCE + overrides + '\ncmd_owned_lifecycle resume "$1"', "fixture", uid], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        results = [(p.communicate(timeout=15), p.returncode) for p in processes]
        assert sorted(code for _, code in results) == [0, 4], results
        print("PASS concurrent capacity")


concurrent_capacity()


def interrupted_lifecycle():
    with tempfile.TemporaryDirectory(prefix="simlease-signal-") as name:
        root = Path(name)
        state = root / "state"
        (state / "leases").mkdir(parents=True)
        (state / "leases" / f"{UID}.json").write_text(json.dumps({"udid": UID, "owner": "fixture/owner", "purpose": "visual", "heartbeat_at": int(time.time()), "acquired_at": 123}))
        config = root / "config.json"
        config.write_text(json.dumps({"pools": {"visual": {"model": "Fixture", "runtime": "fixture", "name_prefix": "Fixture", "release": "keep-booted", "max_devices": 1}}, "guards": {"max_booted_devices": 1}}))
        overrides = r'''
pool_devices() { printf '%s\tFixture 1\tShutdown\n' "$FIXTURE_UUID"; }
device_state() { echo Shutdown; }
device_in_active_build() { return 1; }
booted_count() { echo 0; }
boot_and_probe() { run_timeout 20 bash -c 'trap "" TERM; echo $$ > "$FIXTURE_CHILD"; exec sleep 5'; }
'''
        env = dict(os.environ, SIMLEASE_CONFIG=str(config), SIMLEASE_STATE_DIR=str(state), SIMLEASE_SESSION="fixture/owner", FIXTURE_UUID=UID, FIXTURE_CHILD=str(root / "child"), FIXTURE_LATE=str(root / "late"))
        proc = subprocess.Popen(["bash", "-c", SOURCE + overrides + '\ncmd_owned_lifecycle resume "$1"', "fixture", UID], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while not (root / "child").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            assert (root / "child").exists(), "readiness did not start"
            proc.send_signal(signal.SIGTERM)
            proc.communicate(timeout=3)
            assert proc.returncode != 0 and not (root / "late").exists(), proc.returncode
            assert not (state / "locks" / UID).exists(), "lifecycle lock leaked"
            assert (state / "leases" / f"{UID}.json").exists(), "lease lost"
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
        print("PASS interrupted lifecycle")


interrupted_lifecycle()


def stale_lock_contention():
    with tempfile.TemporaryDirectory(prefix="simlease-reclaim-") as name:
        root = Path(name)
        state = root / "state"
        lock = state / "locks" / "boot-capacity"
        lock.mkdir(parents=True)
        (lock / "meta").write_text("999999\n1\nold\n")
        config = root / "config.json"
        config.write_text("{}")
        overrides = r'''
eval "$(declare -f lock_is_stale | sed '1s/lock_is_stale/actual_lock_is_stale/')"
lock_is_stale() {
  actual_lock_is_stale "$1" || return 1
  : > "$FIXTURE_BARRIER/$FIXTURE_INDEX"
  for i in {1..30}; do [[ -f "$FIXTURE_BARRIER/1" && -f "$FIXTURE_BARRIER/2" ]] && break; sleep 0.02; done
  [[ "$FIXTURE_INDEX" != 2 ]] || sleep 0.2
  return 0
}
if claim_lock boot-capacity lifecycle; then sleep 1; drop_lock boot-capacity; exit 0; else exit 1; fi
'''
        processes = []
        for index in (1, 2):
            env = dict(os.environ, SIMLEASE_CONFIG=str(config), SIMLEASE_STATE_DIR=str(state), FIXTURE_BARRIER=str(root), FIXTURE_INDEX=str(index))
            processes.append(subprocess.Popen(["bash", "-c", SOURCE + overrides], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        results = [(p.communicate(timeout=10), p.returncode) for p in processes]
        assert sorted(code for _, code in results) == [0, 1], results
        print("PASS stale lock contention")


stale_lock_contention()
