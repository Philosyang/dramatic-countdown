import AppKit
import EventKit

// MARK: - Config

struct Config {
    /// Thresholds (in seconds) at which to do a one-time blink alert
    var blinkAlerts: [Int] = [30 * 60, 15 * 60, 10 * 60, 5 * 60, 2 * 60]

    static func load() -> Config {
        var config = Config()

        // Look for config at ~/.config/dramatic-countdown/config.json
        let configDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dramatic-countdown")
        let configFile = configDir.appendingPathComponent("config.json")

        // Also check next to executable / cwd
        let candidates = [
            configFile,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("config.json"),
        ]

        for candidate in candidates {
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let data = try? Data(contentsOf: candidate),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let alerts = json["blink_alerts"] as? [String] else {
                continue
            }

            config.blinkAlerts = alerts.compactMap { parseDuration($0) }.sorted(by: >)
            print("Loaded config from \(candidate.path): blink_alerts = \(config.blinkAlerts)s")
            break
        }

        return config
    }

    /// Parse strings like "30m", "15m", "2m", "90s", "1h" into seconds
    static func parseDuration(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let suffix = trimmed.last!
        let numberPart = String(trimmed.dropLast())

        guard let value = Int(numberPart) else { return nil }

        switch suffix {
        case "s": return value
        case "m": return value * 60
        case "h": return value * 3600
        default:
            // Try parsing the whole thing as seconds
            return Int(trimmed)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var updateTimer: Timer?
    private var blinkTimer: Timer?
    private var blinkVisible = true
    private var blinkText = ""
    private var liveUntil: Date?
    private var liveEventTitle: String?

    private let eventStore = EKEventStore()
    private var calendarAccessGranted = false
    private var currentEvent: EKEvent?

    private var config = Config()
    /// Tracks which blink alert thresholds have already fired for the current event
    private var firedBlinkAlerts: Set<Int> = []
    /// Timer that ends a one-time blink
    private var oneTimeBlink: Timer?

    // Focus mode preferences (persisted via UserDefaults)
    private let defaults = UserDefaults.standard
    private let kPreventBlinksInFocus = "preventBlinksInFocus"
    private let kHideTextInFocus = "hideTextInFocus"
    private let kExcludeDeclined = "excludeDeclinedEvents"

    private var preventBlinksInFocus: Bool {
        get { defaults.object(forKey: kPreventBlinksInFocus) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kPreventBlinksInFocus) }
    }
    private var hideTextInFocus: Bool {
        get { defaults.object(forKey: kHideTextInFocus) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kHideTextInFocus) }
    }
    private var excludeDeclinedEvents: Bool {
        get { defaults.object(forKey: kExcludeDeclined) as? Bool ?? true }
        set { defaults.set(newValue, forKey: kExcludeDeclined) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        config = Config.load()

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setupIcon()

        buildMenu()
        requestCalendarAccess()

        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(updateTimer!, forMode: .common)

        update()
    }

    private func setupIcon() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        if let icon = NSImage(systemSymbolName: "dot.radiowaves.left.and.right", accessibilityDescription: "broadcast") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            button.image = icon.withSymbolConfiguration(config)
            button.image?.isTemplate = true
        }
    }

    // MARK: - Visibility

    private func showStatusItem() {
        statusItem.isVisible = true
    }


    // MARK: - Calendar Access

    private func requestCalendarAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.calendarAccessGranted = granted
                    if !granted {
                        self?.showStatusItem()
                        self?.statusItem.button?.title = " No calendar access"
                        if let error = error {
                            print("Calendar access error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { [weak self] granted, error in
                DispatchQueue.main.async {
                    self?.calendarAccessGranted = granted
                    if !granted {
                        self?.showStatusItem()
                        self?.statusItem.button?.title = " No calendar access"
                        if let error = error {
                            print("Calendar access error: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Focus Detection

    private func isFocusActive() -> Bool {
        let assertionsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

        guard let data = try? Data(contentsOf: assertionsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let store = json["data"] as? [[String: Any]] else {
            return false
        }

        for entry in store {
            if let records = entry["storeAssertionRecords"] as? [[String: Any]], !records.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: - Menu

    private func buildMenu() {
        let menu = NSMenu()

        let eventInfoItem = NSMenuItem(title: "No upcoming events", action: nil, keyEquivalent: "")
        eventInfoItem.tag = 100
        menu.addItem(eventInfoItem)

        menu.addItem(NSMenuItem.separator())

        let preventBlinksItem = NSMenuItem(title: "Prevent blinks in Focus", action: #selector(togglePreventBlinks(_:)), keyEquivalent: "")
        preventBlinksItem.target = self
        preventBlinksItem.tag = 200
        preventBlinksItem.state = preventBlinksInFocus ? .on : .off
        menu.addItem(preventBlinksItem)

        let hideTextItem = NSMenuItem(title: "Hide event text in Focus", action: #selector(toggleHideText(_:)), keyEquivalent: "")
        hideTextItem.target = self
        hideTextItem.tag = 201
        hideTextItem.state = hideTextInFocus ? .on : .off
        menu.addItem(hideTextItem)

        let excludeDeclinedItem = NSMenuItem(title: "Exclude declined events", action: #selector(toggleExcludeDeclined(_:)), keyEquivalent: "")
        excludeDeclinedItem.target = self
        excludeDeclinedItem.tag = 202
        excludeDeclinedItem.state = excludeDeclinedEvents ? .on : .off
        menu.addItem(excludeDeclinedItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshAction), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func togglePreventBlinks(_ sender: NSMenuItem) {
        preventBlinksInFocus.toggle()
        sender.state = preventBlinksInFocus ? .on : .off
        update()
    }

    @objc private func toggleHideText(_ sender: NSMenuItem) {
        hideTextInFocus.toggle()
        sender.state = hideTextInFocus ? .on : .off
        update()
    }

    @objc private func toggleExcludeDeclined(_ sender: NSMenuItem) {
        excludeDeclinedEvents.toggle()
        sender.state = excludeDeclinedEvents ? .on : .off
        currentEvent = nil
        firedBlinkAlerts.removeAll()
        update()
    }

    @objc private func refreshAction() {
        currentEvent = nil
        liveUntil = nil
        liveEventTitle = nil
        firedBlinkAlerts.removeAll()
        stopBlinking()
        update()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Update Loop

    private func update() {
        let now = Date()
        let focusActive = isFocusActive()
        let suppressBlinks = focusActive && preventBlinksInFocus
        let suppressText = focusActive && hideTextInFocus

        // If we're in "LIVE" mode, show that until the timer expires
        if let liveEnd = liveUntil, let title = liveEventTitle {
            if now < liveEnd {
                showStatusItem()
                stopBlinking()
                if suppressText {
                    setStatusText("")
                } else if suppressBlinks {
                    setStatusText(" \(title) is live!")
                } else {
                    blinkText = " \(title) is live!"
                    applyBlinkStyle(highlighted: true)
                }
                return
            } else {
                liveUntil = nil
                liveEventTitle = nil
                firedBlinkAlerts.removeAll()
                currentEvent = nil
                applyBlinkStyle(highlighted: false)
            }
        }

        guard calendarAccessGranted else { return }

        let event = fetchNextEvent()

        // Detect event change — reset alert tracking
        if event?.eventIdentifier != currentEvent?.eventIdentifier {
            firedBlinkAlerts.removeAll()
        }
        currentEvent = event

        // Update menu event info
        if let menuItem = statusItem.menu?.item(withTag: 100) {
            if let event = event {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                let timeStr = formatter.string(from: event.startDate)
                menuItem.title = "\(event.title ?? "Event") at \(timeStr)"
            } else {
                menuItem.title = "No upcoming events"
            }
        }

        guard let event = event else {
            showStatusItem()
            stopBlinking()
            setStatusText("")
            return
        }

        let secondsUntil = event.startDate.timeIntervalSince(now)
        let title = event.title ?? "Event"
        let totalSeconds = Int(secondsUntil)

        // At 0s — go LIVE
        if totalSeconds <= 0 {
            showStatusItem()
            stopBlinking()
            liveEventTitle = title
            liveUntil = now.addingTimeInterval(5)
            if suppressText {
                setStatusText("")
            } else if suppressBlinks {
                setStatusText(" \(title) is live!")
            } else {
                blinkText = " \(title) is live!"
                applyBlinkStyle(highlighted: true)
            }
            currentEvent = nil
            return
        }

        // More than 1 hour away — show icon only, no text
        if totalSeconds > 3600 {
            showStatusItem()
            stopBlinking()
            setStatusText("")
            return
        }

        // Show the status item
        showStatusItem()

        // Format the countdown
        let displayText: String
        if suppressText {
            displayText = ""
        } else if totalSeconds >= 60 {
            let minutes = totalSeconds / 60
            displayText = " \(title) in \(minutes)m"
        } else {
            displayText = " \(title) in \(totalSeconds)s"
        }

        // Check one-time blink alerts (T-30m, T-15m, etc.)
        if !suppressBlinks {
            checkBlinkAlerts(secondsRemaining: totalSeconds, displayText: displayText)
        }

        // Under 10 seconds: continuous blink
        if totalSeconds <= 10 && !suppressBlinks {
            startBlinking(text: displayText)
        } else if oneTimeBlink == nil {
            // Only set normal text if we're not in a one-time blink
            stopBlinking()
            setStatusText(displayText)
        }

    }

    // MARK: - One-Time Blink Alerts

    private func checkBlinkAlerts(secondsRemaining: Int, displayText: String) {
        for threshold in config.blinkAlerts {
            guard !firedBlinkAlerts.contains(threshold) else { continue }

            // Fire when we cross the threshold (within a 2-second window to avoid missing it)
            if secondsRemaining <= threshold && secondsRemaining > threshold - 2 {
                firedBlinkAlerts.insert(threshold)
                fireOneTimeBlink(text: displayText)
                break
            }
        }
    }

    private func fireOneTimeBlink(text: String) {
        oneTimeBlink?.invalidate()

        blinkText = text
        applyBlinkStyle(highlighted: true)

        oneTimeBlink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.oneTimeBlink = nil
            self.applyBlinkStyle(highlighted: false)
            self.setStatusText(text)
        }
        RunLoop.main.add(oneTimeBlink!, forMode: .common)
    }

    // MARK: - Event Fetching

    private func fetchNextEvent() -> EKEvent? {
        let now = Date()
        let endDate = now.addingTimeInterval(24 * 60 * 60)

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: now, end: endDate, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        let futureEvents = events
            .filter { $0.startDate > now }
            .filter { event in
                guard excludeDeclinedEvents else { return true }
                guard let attendees = event.attendees else { return true }
                let me = attendees.first { $0.isCurrentUser }
                return me?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }

        return futureEvents.first
    }

    // MARK: - Display Helpers

    private func setStatusText(_ text: String) {
        guard let button = statusItem.button else { return }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: NSColor.controlTextColor]
        )
    }

    // MARK: - Blinking

    private func startBlinking(text: String) {
        blinkText = text
        applyBlinkStyle(highlighted: blinkVisible)

        guard blinkTimer == nil else { return }

        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.blinkVisible.toggle()
            self.applyBlinkStyle(highlighted: self.blinkVisible)
        }
        RunLoop.main.add(blinkTimer!, forMode: .common)
    }

    private func applyBlinkStyle(highlighted: Bool) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true

        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let textColor: NSColor = highlighted ? .white : .controlTextColor

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor,
            .font: font
        ]
        button.attributedTitle = NSAttributedString(string: blinkText, attributes: attributes)

        if let image = button.image {
            let tinted = image.copy() as! NSImage
            tinted.isTemplate = true
            button.image = tinted
            button.contentTintColor = highlighted ? .white : nil
        }

        if highlighted {
            button.layer?.backgroundColor = NSColor.systemRed.cgColor
            button.layer?.cornerRadius = 6
        } else {
            button.layer?.backgroundColor = nil
        }
    }

    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkVisible = true
        if let button = statusItem.button {
            button.layer?.backgroundColor = nil
            button.contentTintColor = nil
        }
    }

}

// MARK: - Main Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
