# simlease

Machine-wide leases for iOS simulators, so several coding agents (or humans and agents) can share one Mac without fighting over devices.

When a few Claude Code / Codex sessions run tests in parallel, each one tends to pick "some iPhone" by hand, boot extra devices, create new ones, and forget to shut them down. The result is two runs on the same simulator, `Domain is tearing down`, a load average in the hundreds and gigabytes of simulator data nobody needs. `simlease` replaces that with one rule: **every run takes a lease from a pool and gives it back.**

- **Pools by purpose.** `test` = iPhone SE for automated tests, `visual` = iPhone 17 Pro for looking at the app. The pool, not the agent, decides the device type, runtime and limits.
- **Exclusive leases.** A device with a live lease, a running `xcodebuild`/`xctest` that has its UDID in its arguments, or a running app is never handed out.
- **Healthy devices only.** `acquire` boots the device, waits for `bootstatus`, probes it with `simctl listapps`, and restarts it once if it does not answer.
- **Devices go off when nobody needs them.** A release in a `shutdown` pool shuts the device down and removes its logs and temp files. `gc` reclaims stale leases and shuts down unleased devices that simlease booted. It does not touch a simulator that you booted yourself and never leased.
- **Plain files.** One bash script, `jq`, and a state directory. No daemon; a launchd agent runs `gc` every 15 minutes.

## Install

Requires macOS with Xcode and `jq` (`brew install jq`). It runs on the bash 3.2 that macOS ships and on newer ones; CI tests both.

```bash
git clone https://github.com/anivaros/simlease.git
cd simlease
./install.sh
```

This installs `~/.local/bin/simlease`, writes `~/.config/simlease/config.json` from [`config.example.json`](config.example.json) if you do not have one, and loads the `dev.simlease.gc` launchd agent, which runs `gc`. Options: `--prefix DIR`, `--no-agent`, `--uninstall` (keeps config and state).

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
| `heartbeat --all-mine [--purpose P]` | Extends every lease owned by `SIMLEASE_SESSION`. Prints nothing and exits 0 also when there are none. Exits 4 when a lease is locked by another command and could not be extended. |
| `status [--mine] [--purpose P]` | Leases, their owners and ages, held locks, booted devices, active builds, load. `--mine` and `--purpose` filter the leases. |
| `status --mine --print udid [--purpose P]` | Prints the UDIDs of your live leases, one per line; empty output when there are none. |
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
- `sticky` (`true` or `false`): prefer the device this session used last (see [Sticky pools](#sticky-pools)). Default `false`.
- `on_owner_change`: `none` (default) or `erase`. With `erase`, `acquire` shuts down and erases a device before handing it to a session that was not its last owner, including its first use.
- `prepare`: a shell command run after a device is auto-created or erased, while it is shut down and before it boots. It gets `SIMLEASE_UDID`, `SIMLEASE_PURPOSE` and `SIMLEASE_POOL_EVENT` (`created` or `erased`) in the environment; its output goes to stderr. A non-zero exit or a timeout (`SIMLEASE_PREPARE_TIMEOUT`, default 300 s) prints a warning and the acquire continues with the device as it is. The command runs in its own process group; simlease stops the whole group on a timeout and when the command returns, so nothing it started keeps changing a device that is already handed out. It runs while simlease holds the machine-wide boot lock, so other sessions' boots wait for it.

Guards:

- `max_booted_devices`: `acquire` will not boot another device past this many booted simulators; it waits or exits 3 instead.
- `auto_created_device_ttl_hours`: `gc` deletes auto-created devices unleased for this long. The time counts from the last release.
- `sweep_unleased_booted`: `gc` shuts down booted devices in `shutdown` pools that simlease booted and nobody leases.

Environment: `SIMLEASE_STATE_DIR` (default `~/Library/Application Support/simlease`), `SIMLEASE_SIMCTL_TIMEOUT` (120 s per `simctl` call), `SIMLEASE_BOOTSTATUS_TIMEOUT` (180 s), `SIMLEASE_RESTART_PAUSE_SECONDS` (3 s between a failed boot and the retry), `SIMLEASE_LOCK_STALE_SECONDS` (420 s), `SIMLEASE_PREPARE_TIMEOUT` (300 s), `SIMLEASE_SIM_DEVICES_DIR` (`~/Library/Developer/CoreSimulator/Devices`), `SIMLEASE_SIM_LOGS_DIR` (`~/Library/Logs/CoreSimulator`).

### Sticky pools

A worktree is often used by several sessions in a row, over days, and wants its simulator back with the app still installed and logged in. A different worktree wants a clean device. Give each worktree a stable `SIMLEASE_SESSION` (for example `agent/<worktree>`) and opt the pool in:

```json
"agent": {
  "model": "iPhone 17 Pro",
  "name_prefix": "Agent Pool",
  "max_devices": 3,
  "auto_create": false,
  "release": "shutdown",
  "gui": false,
  "lease_ttl_seconds": 3600,
  "sticky": true,
  "on_owner_change": "erase",
  "prepare": "my-tool setup \"$SIMLEASE_UDID\""
}
```

- simlease remembers the last owner of every device in `<state>/last/<udid>`. Release and `gc` keep it; it goes away only with the device.
- With `sticky`, `acquire` tries free devices in this order: the ones this session used last, then never-leased ones, then the rest, least recently used first (an acquire or a heartbeat counts as use), so a session that has been away longest loses its device first. So a worktree whose lease expired or was released gets its old device back as long as nobody else took it.
- With `sticky`, `acquire --count 1` by a session that already holds a live lease in the pool returns that device (booting it again if it was shut down) instead of leasing a second one. This is not exclusive: two shells of one session share the device, also while a build or an app runs on it, and a `release` from either shell releases it for both. Give shells that must not share a device different `SIMLEASE_SESSION` values. A held device that is already booted comes back without waiting for another session's boot. A held device that left the pool (another `model`, a newer runtime) is released and a pool device is leased instead.
- With `on_owner_change: "erase"`, a device that changes hands is erased first, so the next worktree never sees another one's app data. A device with an active build or a running app is busy and is neither erased nor handed out. The erase happens only after the boot checks pass, so a device is never erased for a session that then does not get it.
- Without the erase, a sticky pool tells the new owner instead: `acquire` prints `simlease: note: <name> (<udid>) is yours now. <session> used it before and no longer holds it, so it may have leftover apps, logins and settings. Change or remove whatever you need.` on stderr. The wording matters to agents: a note that only named the previous user made them ask before uninstalling its app. Erasing costs time and brings back first-run system prompts, so pools whose sessions all build the same app may prefer the note.
- An erase that fails skips the device as unhealthy. `prepare` failures never fail the acquire.

## What gc touches

`gc` is what makes leases safe to forget, so it is deliberately conservative:

1. A lease whose heartbeat is older than the pool TTL, on a device with no active `xcodebuild` or `xctest`, is released. An app that is still running keeps the lease for one more TTL: a session that only drives the app sends no heartbeat. After twice the TTL the app counts as left behind by an agent that quit. In pools whose release policy is not `shutdown` the stale lease is kept (a person may still be watching the device) unless you pass `--aggressive`.
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

Heartbeat runs longer than the pool TTL with `simlease heartbeat <udid>` (or `simlease heartbeat --all-mine`). Never shut down or delete a device you did not lease.
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
test/run.sh             # bash on PATH; tests run in parallel, one temp folder each
test/run.sh /bin/bash   # macOS bash 3.2
python3 test/test_lifecycle.py  # isolated lifecycle and ownership checks
python3 test/test_lifecycle_mutation.py  # verify ownership and expiry checks detect regressions
```

The tests run `simlease` against a fake `xcrun simctl` ([`test/stub/xcrun`](test/stub/xcrun)) in a temporary state directory, so they never touch your real simulators.

## License

[MIT](LICENSE)
