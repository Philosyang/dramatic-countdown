# DramaticCountdown

A macOS menu bar app that shows a countdown to your next calendar event.

## Features

- Shows a `((•))` broadcast icon in the menu bar — icon only when the next event is >1 hour away
- Displays countdown: `Event in 25m` (>1 min) or `Event in 42s` (<1 min)
- Configurable one-time blink alerts at specific thresholds (e.g. T-30m, T-15m, T-5m)
- Continuous red background blinking in the final 10 seconds
- Shows `Event is live!` with a solid red background at T-0
- Uses EventKit to fetch the next calendar event within 24 hours
- **Focus mode awareness** with two toggleable options:
  - **Prevent blinks in Focus** — suppresses all blink animations (including "is live!" background) when a macOS Focus mode is active
  - **Hide event text in Focus** — shows only the broadcast icon with no event text, useful when screen sharing during a meeting

## Requirements

- macOS 13.0 or later
- Swift 5.9+
- Calendar access permission (the app will request it on first launch)

## Build and Run

```bash
swift build
swift run
```

For a release build:

```bash
swift build -c release
# Binary at .build/release/DramaticCountdown
```

Or use the convenience script:

```bash
./run.sh
```

## Configuration

Create a `config.json` in the project root or at `~/.config/dramatic-countdown/config.json`:

```json
{
  "blink_alerts": ["30m", "15m", "10m", "5m", "2m", "1m"]
}
```

Each entry is a time-before-event threshold that triggers a single 500ms red blink in the menu bar. Supports `s` (seconds), `m` (minutes), and `h` (hours) suffixes.

## Launch at Login

To start DramaticCountdown automatically when you boot your Mac, create a Launch Agent plist.

1. Create the file at `~/Library/LaunchAgents/com.dramatic-countdown.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.org/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dramatic-countdown</string>
    <key>ProgramArguments</key>
    <array>
        <string>/full/path/to/dramatic-countdown/.build/release/DramaticCountdown</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/full/path/to/dramatic-countdown</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
```

Replace `/full/path/to/dramatic-countdown` with the actual path to your cloned repo.

2. Load the agent (starts it now and on future boots):

```bash
launchctl load ~/Library/LaunchAgents/com.dramatic-countdown.plist
```

3. To stop and remove from login:

```bash
launchctl unload ~/Library/LaunchAgents/com.dramatic-countdown.plist
```

After updating the code, rebuild with `swift build -c release` — the launch agent will pick up the new binary on next launch.

## Permissions

### Calendar Access

On first run, macOS will prompt you to grant calendar access. If denied, the menu bar will show "No calendar access". You can change this later in System Settings > Privacy & Security > Calendars.

### Full Disk Access (for Focus mode detection)

The Focus mode toggles ("Prevent blinks in Focus" and "Hide event text in Focus") require **Full Disk Access** for the binary. macOS protects the `~/Library/DoNotDisturb/` directory, so the app cannot detect Focus state without this permission.

To grant it:

1. Open **System Settings → Privacy & Security → Full Disk Access**
2. Click **+** and add the built binary at:
   ```
   /path/to/dramatic-countdown/.build/release/DramaticCountdown
   ```
3. Restart the app:
   ```bash
   launchctl kickstart -k gui/$(id -u)/com.dramatic-countdown
   ```

Without Full Disk Access, the Focus toggles will have no effect (Focus is never detected).
