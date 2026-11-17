# MactteryGuard

Read this in [한국어](README.ko.md).

A native macOS app that enforces a MacBook charge limit with hard rules.
Menu-bar only (`LSUIElement`, no Dock icon). Open source (MIT).

## Why

macOS's built-in 80% Charge Limit doesn't hold if you leave the cable
connected: macOS occasionally forces a full charge to **100%** for battery
calibration. During calibration, every limit is ignored, including the
built-in one.

MactteryGuard keeps the charge limit by fixed rules, with no pattern
learning, and brings the charge back down to the limit after calibration
finishes. **Calibration charging itself cannot be prevented** (macOS
forces it) — the goal is to minimize the time spent at 100%.

## Features (Step 2)

- **Charge-limit slider, 50–100%** (default 80%). Charging stops at 80%
  and resumes at or below 75% (hysteresis: limit − 5%).
- **Two control backends**
  - **Native (primary)**: syncs with macOS PowerUI charge limits. 80–100%
    uses the PowerUI slider API; below 80% writes through the system
    settings path.
  - **Adapter (fallback / discharge-back)**: physically cuts and reconnects
    charging through the SMC adapter key (CHIE). Used to discharge back to
    the limit after calibration.
- **Calibration detection**: while calibrating, the menu bar and popover
  show **"macOS calibrating"**. No control writes are made during
  calibration; the charge is brought back to the limit once it ends.
- **One-time full charge (Top Up)**: one button charges to 100%, then
  automatically returns to the limit when the adapter is unplugged and
  reconnected, or after 24 hours.
- **Forced discharge (OFF by default, opt-in)**: disconnects the adapter
  above the limit to discharge on battery. Warns about battery-cycle wear
  when enabled.
- **Daemon persistence**: the privileged helper daemon keeps enforcing the
  limit even after the UI app quits. (Changeable in settings: "Release
  charge limit when the app quits".)
- **Battery details**: cycle count, condition, and temperature in the popover.
- **Fail-open safety**: on errors, daemon exit, or removal, charging is
  always restored to allowed. Charging is never blocked below 20%.
- **Logs**: app and daemon logs saved as daily files, auto-deleted after
  30 days.

## Requirements

- macOS 26.0 or later, Apple Silicon
- Xcode 27 to build

## Building from source

**Run in Xcode**

1. Open `BatteryGuard.xcodeproj` in Xcode.
2. Make sure the run destination is **My Mac**.
3. Press `Cmd+R`. The first run may ask you to pick a signing team.
   (A personal Apple ID signature is enough. No paid Developer account needed.)

**Build in Terminal**

```sh
cd MactteryGuard
xcodebuild -project BatteryGuard.xcodeproj -target BatteryGuard -configuration Debug build
```

**Release packaging (.zip + .dmg)**

```sh
./Packaging/package.sh
# → dist/MactteryGuard-<version>.zip, dist/MactteryGuard-<version>.dmg
```

## First run — daemon registration

Charge control is handled by a root-privileged helper daemon. Turning
**charge control** on in the app popover guides you through registration.

1. Press the **Register** button; macOS asks for an administrator password.
2. If macOS asks for login-item approval, allow MactteryGuard under
   **System Settings → General → Login Items**.
   (The popover's **Open System Settings** button takes you there.)
3. Once registration completes, the popover shows the daemon status
   (backend, control state, whether the limit is registered).

## Gatekeeper bypass (running an unnotarized app)

This app is not notarized with a paid Apple Developer account, so macOS
may block the downloaded app on first launch. Use one of these:

- **Right-click launch**: right-click the app → **Open** → **Open** in the
  confirmation dialog.
- **Remove quarantine in Terminal**:

```sh
xattr -dr com.apple.quarantine /Applications/MactteryGuard.app
```

An app built from source has no quarantine attribute, so this isn't needed.

## Usage

- **Charge control toggle**: turns limit enforcement on and off.
- **Limit slider**: 50–100%. Choosing below 80% shows a note that it
  may conflict with default macOS behavior or cause drain.
  (Below 80% is experimental. The verified behavior is 80%.)
- **One-time full charge**: charges to 100% once. After reaching 100%,
  unplugging and reconnecting the adapter (or waiting 24 hours) restores
  the original limit.
- **Forced discharge**: disconnects the adapter above the limit to
  discharge. OFF by default. Enabling it shows a battery-cycle warning.
- **Release charge limit when the app quits**: when on, quitting the app
  releases daemon control. (Default OFF — the daemon keeps the limit
  even after the app quits.)
- **Open log folder**: opens the app log folder in Finder.
- **Uninstall**: restores charging to allowed, unregisters the daemon,
  and quits the app.

## Logs

| Component | Path |
| --- | --- |
| App | `~/Library/Logs/MactteryGuard/` |
| Daemon (root) | `/Library/Logs/MactteryGuard/` |

Daemon logs are root-owned; check them in Terminal with `sudo`:

```sh
sudo ls /Library/Logs/MactteryGuard/
sudo tail -f /Library/Logs/MactteryGuard/helper-*.log
```

Both logs are daily files (`mactteryguard-YYYY-MM-DD.log`,
`helper-YYYY-MM-DD.log`); files older than 30 days are auto-deleted.

## Troubleshooting

- **Daemon status "Not found"**: the helper isn't embedded in the app
  bundle. Clean Build and rebuild
  (`MactteryGuard.app/Contents/Library/LaunchDaemons/` must contain
  `MactteryGuardHelper` and `com.loveaimg.mactteryguard.helper.plist`).
- **"Waiting for approval"**: allow it under System Settings → General →
  Login Items.
- **Limit not registered**: if the MacBook is running on battery, macOS
  withdraws the limit registration. Connect the adapter and wait about
  a minute. Registration is also temporarily lifted during calibration.
- **Charged to 100%**: calibration is the most likely cause. Check
  whether the menu bar shows "macOS calibrating". Calibration can't be
  prevented; MactteryGuard brings the charge back to the limit after it ends.
- **Check the limit registration directly**:

```sh
pmset -g battlimit
```

## Manual removal (if the in-app uninstall doesn't work)

```sh
# Stop the daemon and unregister it
sudo launchctl bootout system/com.loveaimg.mactteryguard.helper
sudo rm -rf "/Library/Application Support/MactteryGuard"
sudo rm -rf /Library/Logs/MactteryGuard
rm -rf ~/Library/Logs/MactteryGuard
# Delete the app
rm -rf /Applications/MactteryGuard.app
```

Stopping the daemon restores charging to allowed (fail-open).

## Known limitations

- macOS calibration charging can't be prevented by any app. MactteryGuard
  can only bring the charge back after calibration ends.
- Limits below 80% rely on the system settings path (an undocumented
  mechanism) and may break with macOS updates.
- Direct SMC charge-block keys (CH0B/CH0C) are gated on recent firmware
  and can't be used. Only the adapter key (CHIE) is used.
- The v1 XPC connection doesn't verify the caller's code signature
  (a local mach service, accessible only on the same machine).

## License

MIT License — see [LICENSE](LICENSE).
