import AppKit
import Foundation

// MARK: - Log Writer

final class LogWriter {
    private let logDir: URL
    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var currentFileSize: UInt64 = 0
    private let maxFileSize: UInt64 = 50 * 1024 * 1024 // 50 MB

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        logDir = home.appendingPathComponent("Library/Logs/attention-thief-catcher")

        // Security: verify log directory is not a symlink
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: logDir.path, isDirectory: &isDir) {
            let attrs = try? fm.attributesOfItem(atPath: logDir.path)
            if attrs?[.type] as? FileAttributeType == .typeSymbolicLink {
                NSLog("attention-thief-catcher: SECURITY: log directory is a symlink, refusing to start")
                exit(1)
            }
        }

        do {
            try fm.createDirectory(at: logDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            NSLog("attention-thief-catcher: FATAL: cannot create log directory: \(error)")
            exit(1)
        }

        purgeOldLogs()
        rotate()
    }

    deinit {
        fileHandle?.closeFile()
    }

    private func rotate() {
        fileHandle?.closeFile()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let fileURL = logDir.appendingPathComponent("focus-\(stamp).ndjson")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        fileHandle = FileHandle(forWritingAtPath: fileURL.path)
        fileHandle?.seekToEndOfFile()
        currentFileURL = fileURL
        currentFileSize = 0
    }

    private func purgeOldLogs() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600) // 30 days
        guard let files = try? fm.contentsOfDirectory(at: logDir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for file in files where file.pathExtension == "ndjson" {
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let created = attrs[.creationDate] as? Date,
               created < cutoff {
                try? fm.removeItem(at: file)
                NSLog("attention-thief-catcher: purged old log: \(file.lastPathComponent)")
            }
        }
    }

    func write(_ dict: [String: Any]) {
        guard let handle = fileHandle else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
            var line = data
            line.append(0x0A) // newline
            handle.write(line)
            handle.synchronizeFile()
            currentFileSize += UInt64(line.count)
            if currentFileSize >= maxFileSize {
                rotate()
            }
        } catch {
            NSLog("attention-thief-catcher: JSON serialization error: \(error)")
        }
    }
}

// MARK: - Helpers

func iso8601Now() -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date())
}

func appInfo(_ app: NSRunningApplication) -> [String: Any] {
    var d: [String: Any] = [:]
    d["name"] = app.localizedName ?? "unknown"
    d["bundleID"] = app.bundleIdentifier ?? "unknown"
    d["pid"] = app.processIdentifier
    d["path"] = app.executableURL?.path ?? "unknown"
    switch app.activationPolicy {
    case .regular:    d["activationPolicy"] = "regular"
    case .accessory:  d["activationPolicy"] = "accessory"
    case .prohibited: d["activationPolicy"] = "prohibited"
    @unknown default: d["activationPolicy"] = "unknown"
    }
    return d
}

func processSnapshot() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/ps")
    proc.arguments = ["-U", NSUserName(), "-eo", "pid,ppid,%cpu,%mem,comm"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return "snapshot-error: \(error)"
    }
}

// MARK: - Anomaly Detector

final class AnomalyDetector {
    private var recentFocusTimes: [Date] = []
    private var knownBundles: Set<String> = []
    private var recentLaunches: [String: Date] = [:] // bundleID -> launch time
    private let logger: LogWriter

    init(logger: LogWriter) {
        self.logger = logger
        // Seed known bundles from currently running apps
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier {
                knownBundles.insert(bid)
            }
        }
    }

    func recordLaunch(bundleID: String) {
        recentLaunches[bundleID] = Date()
        knownBundles.insert(bundleID)
    }

    func checkActivation(app: NSRunningApplication) -> [[String: Any]] {
        var anomalies: [[String: Any]] = []
        let now = Date()

        // RAPID_FOCUS: 6+ switches in 5 seconds
        recentFocusTimes.append(now)
        recentFocusTimes = recentFocusTimes.filter { now.timeIntervalSince($0) <= 5.0 }
        if recentFocusTimes.count >= 6 {
            anomalies.append(makeAnomaly("RAPID_FOCUS",
                detail: "\(recentFocusTimes.count) focus switches in 5s window"))
        }

        // NON_REGULAR_ACTIVATION
        if app.activationPolicy != .regular {
            let policyStr: String
            switch app.activationPolicy {
            case .accessory:  policyStr = "accessory"
            case .prohibited: policyStr = "prohibited"
            default:          policyStr = "unknown"
            }
            anomalies.append(makeAnomaly("NON_REGULAR_ACTIVATION",
                detail: "\(app.localizedName ?? "?") has policy \(policyStr)"))
        }

        // UNKNOWN_BUNDLE
        if let bid = app.bundleIdentifier, !knownBundles.contains(bid) {
            knownBundles.insert(bid)
            anomalies.append(makeAnomaly("UNKNOWN_BUNDLE",
                detail: "New bundle: \(bid)"))
        }

        // JUST_LAUNCHED_ACTIVATION
        if let bid = app.bundleIdentifier, let launchTime = recentLaunches[bid] {
            let elapsed = now.timeIntervalSince(launchTime)
            if elapsed < 2.0 {
                anomalies.append(makeAnomaly("JUST_LAUNCHED_ACTIVATION",
                    detail: "\(bid) activated \(String(format: "%.1f", elapsed))s after launch"))
            }
        }

        // Capture process snapshot on any anomaly
        if !anomalies.isEmpty {
            let snapshot = processSnapshot()
            for i in anomalies.indices {
                anomalies[i]["processSnapshot"] = snapshot
            }
        }

        return anomalies
    }

    private func makeAnomaly(_ type: String, detail: String) -> [String: Any] {
        return [
            "event": "ANOMALY",
            "timestamp": iso8601Now(),
            "anomalyType": type,
            "detail": detail
        ]
    }
}

// MARK: - Focus Monitor

final class FocusMonitor {
    private let logger: LogWriter
    private let detector: AnomalyDetector
    private var lastFrontmostPID: pid_t = -1
    private var pollTimer: Timer?
    private var snapshotTimer: Timer?

    init() {
        logger = LogWriter()
        detector = AnomalyDetector(logger: logger)
        logStartup()
        setupNotifications()
        setupPolling()
        setupPeriodicSnapshot()
    }

    // MARK: Startup

    private func logStartup() {
        var entry: [String: Any] = [
            "event": "DAEMON_START",
            "timestamp": iso8601Now(),
            "pid": ProcessInfo.processInfo.processIdentifier
        ]
        // Log all currently running regular apps
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { appInfo($0) }
        entry["runningApps"] = apps

        if let front = NSWorkspace.shared.frontmostApplication {
            entry["frontmostApp"] = appInfo(front)
            lastFrontmostPID = front.processIdentifier
        }
        logger.write(entry)
    }

    // MARK: 1. Event Monitor (notifications)

    private func setupNotifications() {
        let nc = NSWorkspace.shared.notificationCenter

        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleActivation(app)
        }

        nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.logEvent("APP_DEACTIVATED", app: app)
        }

        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let bid = app.bundleIdentifier {
                self?.detector.recordLaunch(bundleID: bid)
            }
            self?.logEvent("APP_LAUNCHED", app: app)
        }

        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                       object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.logEvent("APP_TERMINATED", app: app)
        }

        // Sleep / Wake
        nc.addObserver(forName: NSWorkspace.willSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SYSTEM_WILL_SLEEP")
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SYSTEM_DID_WAKE")
            // Capture snapshot after wake — prime suspect window
            self?.logPeriodicSnapshot(reason: "post_wake")
        }

        // Screen lock/unlock
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SCREENS_DID_SLEEP")
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SCREENS_DID_WAKE")
        }

        // Session active/resign
        nc.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SESSION_BECAME_ACTIVE")
        }
        nc.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification,
                       object: nil, queue: .main) { [weak self] _ in
            self?.logSystemEvent("SESSION_RESIGNED_ACTIVE")
        }
    }

    private func handleActivation(_ app: NSRunningApplication) {
        logEvent("APP_ACTIVATED", app: app)
        lastFrontmostPID = app.processIdentifier

        let anomalies = detector.checkActivation(app: app)
        for a in anomalies {
            var entry = a
            entry["triggerApp"] = appInfo(app)
            logger.write(entry)
        }
    }

    private func logEvent(_ event: String, app: NSRunningApplication) {
        var entry = appInfo(app)
        entry["event"] = event
        entry["timestamp"] = iso8601Now()
        logger.write(entry)
    }

    private func logSystemEvent(_ event: String) {
        logger.write([
            "event": event,
            "timestamp": iso8601Now()
        ])
    }

    // MARK: 2. Polling Safety Net

    private func setupPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollFrontmost()
        }
    }

    private func pollFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            logger.write([
                "event": "POLL_NO_FRONTMOST",
                "timestamp": iso8601Now()
            ])
            return
        }

        let pid = front.processIdentifier
        if pid != lastFrontmostPID {
            // Notification missed — the safety net caught a change
            var entry = appInfo(front)
            entry["event"] = "POLL_FOCUS_CHANGE"
            entry["timestamp"] = iso8601Now()
            entry["previousPID"] = lastFrontmostPID
            logger.write(entry)

            lastFrontmostPID = pid

            let anomalies = detector.checkActivation(app: front)
            for a in anomalies {
                var anomalyEntry = a
                anomalyEntry["triggerApp"] = appInfo(front)
                anomalyEntry["detectedBy"] = "poll"
                logger.write(anomalyEntry)
            }
        }

        // Check if frontmost app owns the menu bar (regular policy)
        if front.activationPolicy != .regular {
            var entry = appInfo(front)
            entry["event"] = "POLL_ANOMALY_NON_REGULAR_FRONTMOST"
            entry["timestamp"] = iso8601Now()
            logger.write(entry)
        }
    }

    // MARK: 3. Periodic Snapshots

    private func setupPeriodicSnapshot() {
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 300.0, repeats: true) { [weak self] _ in
            self?.logPeriodicSnapshot(reason: "periodic")
        }
    }

    private func logPeriodicSnapshot(reason: String) {
        let snapshot = processSnapshot()
        var entry: [String: Any] = [
            "event": "PROCESS_SNAPSHOT",
            "timestamp": iso8601Now(),
            "reason": reason,
            "processSnapshot": snapshot
        ]
        if let front = NSWorkspace.shared.frontmostApplication {
            entry["frontmostApp"] = appInfo(front)
        }
        logger.write(entry)
    }
}

// MARK: - Main

// Keep a strong reference so the monitor isn't deallocated
let monitor = FocusMonitor()
_ = monitor // suppress unused warning

// Run the main RunLoop — this keeps the process alive and delivers
// NSWorkspace notifications + Timer callbacks.
RunLoop.main.run()
