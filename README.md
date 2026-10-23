# simlease

Machine-wide leases for iOS simulators, so several coding agents (or humans and agents) can share one Mac without fighting over devices.

When a few Claude Code / Codex sessions run tests in parallel, each one tends to pick "some iPhone" by hand, boot extra devices, create new ones, and forget to shut them down. The result is two runs on the same simulator, `Domain is tearing down`, a load average in the hundreds and gigabytes of simulator data nobody needs. `simlease` replaces that with one rule: **every run takes a lease from a pool and gives it back.**

- **Pools by purpose.** `test` = iPhone SE for automated tests, `visual` = iPhone 17 Pro for looking at the app. The pool, not the agent, decides the device type, runtime and limits.
- **Exclusive leases.** A device with a live lease, a running `xcodebuild`/`xctest` that targets it, or an app process running on it is never handed out.
- **Healthy devices only.** `acquire` boots the device, waits for `bootstatus`, probes it with `simctl listapps`, and restarts it once if it does not answer.
- **Cleanup that respects people.** `gc` shuts down only what simlease booted and nobody holds. A simulator you started from the Xcode GUI is left alone.
- **Plain files.** One bash script, `jq`, and a state directory. No daemon; a launchd agent runs `gc` every 15 minutes.

## Install

Requires macOS with Xcode and `jq` (`brew install jq`).

```bash
git clone https://github.com/anivaros/simlease.git
cd simlease
./install.sh
```

This installs `~/.local/bin/simlease`, writes `~/.config/simlease/config.json` from [`config.example.json`](config.example.json) if you do not have one, and loads the `dev.simlease.gc` launchd agent. Options: `--prefix DIR`, `--no-agent`, `--uninstall` (keeps config and state).

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
| `doctor` | Resolved pools, their devices and `status`. |
| `version` | Prints the version. |

Exit codes: `0` ok, `2` usage or config error, `3` nothing acquired, `4` partial failure (for example a lease owned by someone else).

The lease owner is `SIMLEASE_SESSION`, or `user@<git toplevel or cwd>` when it is unset. Set it explicitly in agents: two shells of the same session must agree on it.

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
- `release` (required): `shutdown` shuts the device down on release, `restore` shuts it down only if simlease booted it, `keep-booted` leaves it running (for a device a human is looking at).
- `gui`: open Simulator.app after acquiring.
- `lease_ttl_seconds`: a lease without a heartbeat for this long is stale. Default 1200.

Guards:

- `max_booted_devices`: `acquire` will not boot another device past this many booted simulators; it waits or exits 3 instead.
- `auto_created_device_ttl_hours`: `gc` deletes auto-created devices unleased for this long.
- `sweep_unleased_booted`: `gc` shuts down booted devices in `shutdown` pools that simlease booted and nobody leases.

Environment: `SIMLEASE_STATE_DIR` (default `~/Library/Application Support/simlease`), `SIMLEASE_SIMCTL_TIMEOUT` (120 s per `simctl` call), `SIMLEASE_BOOTSTATUS_TIMEOUT` (180 s), `SIMLEASE_LOCK_STALE_SECONDS` (420 s).

## What gc touches

`gc` is what makes leases safe to forget, so it is deliberately conservative:

1. A lease whose heartbeat is older than the pool TTL, on a device with no active build or app process, is released. In pools whose release policy is not `shutdown` the stale lease is kept (a person may still be watching the device) unless you pass `--aggressive`.
2. Lock directories left by killed processes are removed once their owner process is gone or they are older than `SIMLEASE_LOCK_STALE_SECONDS`.
3. With `sweep_unleased_booted`, booted devices in `shutdown` pools are shut down only when simlease booted them, nobody leases them, and nothing runs on them. Devices booted from Xcode, `simctl` or Simulator.app are never swept.
4. Auto-created devices unleased for `auto_created_device_ttl_hours` are deleted.

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
test/run.sh             # bash on PATH
test/run.sh /bin/bash   # macOS bash 3.2
```

The tests run `simlease` against a fake `xcrun simctl` ([`test/stub/xcrun`](test/stub/xcrun)) in a temporary state directory, so they never touch your real simulators.

## License

[MIT](LICENSE)
