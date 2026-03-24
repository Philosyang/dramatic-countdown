# DramaticCountdown

A macOS menu bar app that shows a countdown to your next calendar event with dramatic flair.

## Features

- Shows countdown to the next calendar event in the menu bar (e.g. "Team sync in 5:23")
- Blinks/pulses the menu bar text when under 60 seconds remain
- Plays a BBC news countdown sound effect during the final 15 seconds
- Shows "LIVE" indicator when the event starts
- Uses EventKit to fetch real calendar events within the next 24 hours

## Requirements

- macOS 13.0 or later
- Swift 5.9+
- Calendar access permission (the app will request it on first launch)

## Build and Run

```bash
swift build
swift run
```

Or use the convenience script:

```bash
./run.sh
```

## Audio File

To enable the countdown sound effect, add a `bbc-countdown.mp3` file in one of these locations:

1. `Sources/DramaticCountdown/Resources/bbc-countdown.mp3` (bundled with the build)
2. Next to the built executable
3. In the current working directory
4. In a `Resources/` subdirectory of the current working directory

The app works fine without the audio file -- it will just skip the sound effect.

## Calendar Access

On first run, macOS will prompt you to grant calendar access. If denied, the menu bar will show "No calendar access". You can change this later in System Settings > Privacy & Security > Calendars.
