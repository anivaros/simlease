# simlease

Machine-wide leases for iOS simulators, so several coding agents (or humans and agents) can share one Mac without fighting over devices.

When a few Claude Code / Codex sessions run tests in parallel, each one tends to pick "some iPhone" by hand, boot extra devices, create new ones, and forget to shut them down. The result is two runs on the same simulator, `Domain is tearing down`, a load average in the hundreds and gigabytes of simulator data nobody needs. `simlease` replaces that with one rule: **every run takes a lease from a pool and gives it back.**

- **Pools by purpose.** `test` = iPhone SE for automated tests, `visual` = iPhone 17 Pro for looking at the app. The pool, not the agent, decides the device type, runtime and limits.
- **Exclusive leases.** A device with a live lease, a running `xcodebuild`/`xctest` that has its UDID in its arguments, or a running app is never handed out.
- **Healthy devices only.** `acquire` boots the device, waits for `bootstatus`, probes it with `simctl listapps`, and restarts it once if it does not answer.
- **Devices go off when nobody needs them.** A release in a `shutdown` pool shuts the device down and removes its logs and temp files. `gc` reclaims stale leases and shuts down unleased devices that simlease booted. It does not touch a simulator that you booted yourself and never leased.
- **Plain files.** One bash script, `jq`, and a state directory. No daemon; a launchd agent runs `gc` every 15 minutes.

## Install

Requires macOS with Xcode, `jq` and bash 5 (`brew install jq bash`). Homebrew's bash must come before `/bin` on `PATH`: macOS ships bash 3.2, and simlease refuses to run on it.

```bash
git clone https://github.com/anivaros/simlease.git
cd simlease
./install.sh
```

This installs `~/.local/bin/simlease`, writes `~/.config/simlease/config.json` from [`config.example.json`](config.example.json) if you do not have one, and loads the `dev.simlease.gc` launchd agent, which runs `gc` with the bash 5 found on `PATH`. Options: `--prefix DIR`, `--no-agent`, `--uninstall` (keeps config and state).

To update, run `simlease update`. It downloads `bin/simlease` from the `main` branch and replaces the installed script. Leases, config and the launchd agent stay as they are. `update` always installs what `main` has, even if your copy is newer. It refuses a symlink or a script that git tracks: run `git pull` there instead. Version 0.1.0 has no `update`: update it once with `git pull` and `./install.sh`.

Check what the pools resolve to on your machine:

```bash
simlease doctor
```

## Usage

```bash
export SIMLEASE_SESSION="claude/$(basename "$PWD")"   # same value for acquire, heartbeat and release

udid="$(simlease acquire --purpose test --wait 300)"
trap 'simlease release "$udid"' EXIT

xcodebuild test -scheme App -destination "platform=iOS Simulator,id=$udid"
```

Two devices for a multi-device test:

```bash
simlease acquire --purpose test --count 2 --print destination
# platform=iOS Simulator,id=…
# platform=iOS Simulator,id=…
```

Runs longer than the pool's `lease_ttl_seconds` must refresh the lease, otherwise `gc` may reclaim it:

```bash
while sleep 300; do simlease heartbeat "$udid"; done &
```

### Commands

| Command | What it does |
| --- | --- |
| `acquire --purpose P [--count N] [--wait S] [--print udid\|destination]` | Leases N healthy devices from pool P, booting them if needed. Waits up to S seconds for free devices, then exits 3 and releases any partial set. |
| `release <udid>… [--force]` | Ends your lease and applies the pool's release policy. Refuses leases owned by another session unless `--force`. |
| `release --all-mine [--purpose P]` | Releases every lease owned by `SIMLEASE_SESSION`. |
| `heartbeat <udid>…` | Extends your lease. |
| `status` | Leases, their owners and ages, held locks, booted devices, active builds, load. |
| `gc [--dry-run] [--aggressive]` | Reclaims dead sessions' devices (see below). |
| `reclaim-unleased --purpose P <udid>` | Shuts down one unleased device that simlease booted. |
| `resume <udid>` | Boots and checks a device held by the current session's live lease. |
| `reboot <udid>` | Restarts and checks a device held by the current session's live lease. |
| `doctor` | Resolved pools, their devices and `status`. |
| `version` | Prints the version. |
| `update` (or `upgrade`) | Replaces the installed script with the latest one from `main`. Set `SIMLEASE_UPDATE_URL` to use another source. |

Exit codes: `0` ok, `1` update failed, `2` usage or config error, `3` nothing acquired, `4` partial failure (for example a lease owned by someone else). A failed tool such as `jq` or `simctl` can end the run with its own exit code.

The lease owner is `SIMLEASE_SESSION`, or `user@<git toplevel or cwd>` when it is unset. Set it explicitly in agents: two shells of the same session must agree on it.

`resume` and `reboot` require an explicit `SIMLEASE_SESSION` matching the live lease. They retain the lease and refuse unavailable devices, active builds, and booting beyond the configured limit. A failed restart can leave the device shut down; the lease remains in place.

## Configuration

`~/.config/simlease/config.json` (override with `SIMLEASE_CONFIG`):

```json
{
  "pools": {
    "test": {
      "model": "iPhone SE (3rd generation)",
      "name_prefix": "iPhone SE",
      "max_devices": 4,
      "auto_create": true,
      "release": "shutdown",
      "gui": false,
      "lease_ttl_seconds": 1200
    }
  },
  "guards": {
    "max_booted_devices": 6,
    "auto_created_device_ttl_hours": 24,
    "sweep_unleased_booted": true
  }
}
```

Pool keys:

- `model` (required): exact device type name from `xcrun simctl list devicetypes`. Matching is by device type identifier, so `iPhone 17 Pro` never returns an `iPhone 17 Pro Max`.
- `runtime`: runtime identifier such as `com.apple.CoreSimulator.SimRuntime.iOS-27-0`. Defaults to the newest available iOS runtime.
- `name_prefix` (required): only devices named `<prefix> <N>` belong to the pool, so Xcode's default `iPhone SE (3rd generation)` stays out of an `iPhone SE` pool. Auto-created devices get the next free `<prefix> <N>`.
- `max_devices` (required): pool size, including auto-created devices.
- `auto_create`: create a new device when every pool device is taken.
- `release` (required): `shutdown` shuts the device down on release, `restore` shuts it down only if simlease booted it, `keep-booted` leaves it running. In `restore` and `keep-booted` pools `gc` keeps stale leases unless you pass `--aggressive`. When a release, the `gc` sweep or `reclaim-unleased` shuts a device down, simlease removes the device's logs and temp files: `data/tmp`, `data/Library/Logs`, the `os_log` store (`data/var/db/diagnostics`, `data/var/db/uuidtext`), each app's `tmp` and `~/Library/Logs/CoreSimulator/<udid>`. Apps, their data and settings stay.
- `gui`: open Simulator.app after acquiring.
- `lease_ttl_seconds`: a lease without a heartbeat for this long is stale. Default 1200.

Guards:

- `max_booted_devices`: `acquire` will not boot another device past this many booted simulators; it waits or exits 3 instead.
- `auto_created_device_ttl_hours`: `gc` deletes auto-created devices unleased for this long. The time counts from the last release.
- `sweep_unleased_booted`: `gc` shuts down booted devices in `shutdown` pools that simlease booted and nobody leases.

Environment: `SIMLEASE_STATE_DIR` (default `~/Library/Application Support/simlease`), `SIMLEASE_SIMCTL_TIMEOUT` (120 s per `simctl` call), `SIMLEASE_BOOTSTATUS_TIMEOUT` (180 s), `SIMLEASE_RESTART_PAUSE_SECONDS` (3 s between a failed boot and the retry), `SIMLEASE_LOCK_STALE_SECONDS` (420 s), `SIMLEASE_SIM_DEVICES_DIR` (`~/Library/Developer/CoreSimulator/Devices`), `SIMLEASE_SIM_LOGS_DIR` (`~/Library/Logs/CoreSimulator`).

## What gc touches

`gc` is what makes leases safe to forget, so it is deliberately conservative:

1. A lease whose heartbeat is older than the pool TTL, on a device with no active `xcodebuild` or `xctest`, is released. An app that is still running does not keep the device: an agent that quits leaves its app behind. In pools whose release policy is not `shutdown` the stale lease is kept (a person may still be watching the device) unless you pass `--aggressive`.
2. Lock directories left by killed processes are removed once their owner process is gone. A lock with no readable owner pid is removed when it is older than `SIMLEASE_LOCK_STALE_SECONDS`.
3. With `sweep_unleased_booted`, booted devices in `shutdown` pools are shut down only when simlease booted them, nobody leases them, and no `xcodebuild` or `xctest` uses them. Devices booted from Xcode, `simctl` or Simulator.app are never swept.
4. Auto-created devices unleased for `auto_created_device_ttl_hours` are deleted, but only when they are shut down. A booted one may be in use from Xcode without a lease.

Run `simlease gc --dry-run` to see what it would do.

## Using it with coding agents

Put the rule where every agent reads it (`AGENTS.md`, `CLAUDE.md`, …):

```markdown
## Simulators
Never pick, boot or create simulators by hand. Take them from simlease:

    export SIMLEASE_SESSION=<agent>/<worktree>
    simlease acquire --purpose test --count 1 --print destination   # tests: iPhone SE
    simlease acquire --purpose visual                              # looking at the app: iPhone 17 Pro
    trap 'simlease release --all-mine' EXIT

Heartbeat runs longer than the pool TTL with `simlease heartbeat <udid>`. Never shut down or delete a device you did not lease.
```

And make the rule mechanical. For Claude Code, deny direct device management in `~/.claude/settings.json`:

```json
{
  "permissions": {
    "deny": [
      "Bash(xcrun simctl boot *)",
      "Bash(xcrun simctl create *)",
      "Bash(xcrun simctl clone *)",
      "Bash(xcrun simctl delete *)",
      "Bash(xcrun simctl erase *)"
    ]
  }
}
```

## Development

```bash
test/run.sh             # bash 5 on PATH; tests run in parallel, one temp folder each
python3 test/test_lifecycle.py  # isolated lifecycle and ownership checks
python3 test/test_lifecycle_mutation.py  # verify ownership and expiry checks detect regressions
```

The tests run `simlease` against a fake `xcrun simctl` ([`test/stub/xcrun`](test/stub/xcrun)) in a temporary state directory, so they never touch your real simulators.

## License

[MIT](LICENSE)
