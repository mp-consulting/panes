import AppKit
import PanesCore
import Security
import Synchronization

/// Checks GitHub once a day for a newer release, and installs it when asked.
///
/// A file downloaded here gets no quarantine flag, so Gatekeeper never looks at it: the signature
/// checks in `installUpdate` are the only gate. The disk image must be notarized and signed with
/// the team's Developer ID, and the app copied out of it must carry Panes's identifier and that
/// same signature, which also keeps the Accessibility grant across the update.
@MainActor @Observable final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case installing(Release, InstallStep)
        case failed(String)
    }

    enum InstallStep: Equatable {
        /// `expected` is 0 while the size is unknown.
        case downloading(received: Int64, expected: Int64)
        case verifying
    }

    private(set) var state: State = .idle
    /// Off for development builds: without the team's signature there is no safe way to replace them.
    let isEnabled: Bool
    let currentVersion: AppVersion?

    private let store: Store
    @ObservationIgnored private var schedule: Task<Void, Never>?

    private static let lastCheckKey = "lastUpdateCheck"
    private nonisolated static let developerID = #"anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "4HWBUF2R8D""#
    private nonisolated static let appRequirement = #"identifier "com.mpconsulting.Panes" and "# + developerID
    private nonisolated static let diskImageRequirement = "notarized and " + developerID

    init(store: Store) {
        self.store = store
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        isEnabled = Self.satisfies(Bundle.main.bundleURL, Self.appRequirement)
    }

    var availableRelease: Release? {
        if case let .available(release) = state { release } else { nil }
    }

    /// Checks now if a day has passed, then looks again every hour (a Mac that slept through the
    /// due time catches up within the hour).
    func start() {
        guard isEnabled, schedule == nil else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func checkIfDue() async {
        let lastCheck = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard store.config.checkForUpdates, UpdateSchedule.isDue(lastCheck: lastCheck) else { return }
        await check()
    }

    func check() async {
        switch state {
        case .checking, .installing: return
        default: break
        }
        guard isEnabled else { return }
        state = .checking
        do {
            var request = URLRequest(url: Release.latestURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Panes/\(currentVersion?.description ?? "dev")", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.expectOK(response)
            let release = try Release(gitHubJSON: data)
            UserDefaults.standard.set(Date.now, forKey: Self.lastCheckKey)
            if let currentVersion, release.version > currentVersion {
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch Release.Failure.noDiskImage {
            // Published but still building: not an error, and the next check will see it.
            state = .upToDate
        } catch {
            state = .failed("Couldn't check for updates: \(error.localizedDescription)")
        }
    }

    /// Why Panes can't replace itself where it runs, if it can't; the release page is offered instead.
    var installBlocker: String? {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") {
            return "Move Panes to the Applications folder to install updates from here."
        }
        if (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "Panes is running from a read-only disk. Copy it to Applications first."
        }
        if !FileManager.default.isWritableFile(atPath: folder.path) {
            return "Your account can't write to \(folder.path(percentEncoded: false)). Download the update instead."
        }
        return nil
    }

    func install(_ release: Release) async {
        guard installBlocker == nil else { return }
        state = .installing(release, .downloading(received: 0, expected: 0))
        do {
            try await Self.installUpdate(release, over: Bundle.main.bundleURL) { [weak self] step in
                Task { @MainActor in self?.advance(release, to: step) }
            }
            relaunch()
        } catch {
            state = .failed("Couldn't install Panes \(release.version): \(error.localizedDescription)")
        }
    }

    /// Byte counts arrive from URLSession's threads and may land out of order, so they never move
    /// the bar back, nor undo the step after the download.
    private func advance(_ release: Release, to step: InstallStep) {
        guard case let .installing(current, currentStep) = state, current == release else { return }
        switch (currentStep, step) {
        case (.verifying, _): return
        case let (.downloading(had, _), .downloading(received, _)) where received < had: return
        default: state = .installing(release, step)
        }
    }

    // MARK: Installing

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    @concurrent private nonisolated static func installUpdate(
        _ release: Release, over app: URL, progress: @escaping @Sendable (InstallStep) -> Void
    ) async throws {
        let files = FileManager.default
        // On the app's volume, so the final swap is a rename rather than a copy. Resolved, because
        // diskutil only knows a mount point by its real path (/private/var/…, not /var/…).
        let work = realPath(try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true))
        defer { try? files.removeItem(at: work) }

        let observer = DownloadObserver { progress(.downloading(received: $0, expected: max($1, 0))) }
        let (download, response) = try await URLSession.shared.download(from: release.diskImageURL, delegate: observer)
        try expectOK(response)
        progress(.verifying)
        let image = work.appending(path: "Panes.dmg")
        try files.moveItem(at: download, to: image)
        guard satisfies(image, diskImageRequirement) else {
            throw InstallError("the download isn't a notarized disk image signed by Panes's developer.")
        }

        let mountPoint = work.appending(path: "image")
        try run("/usr/sbin/diskutil", "image", "attach", "--mountOptions", "nobrowse", "--readOnly",
                "--mountPoint", mountPoint.path, image.path)
        defer { eject(mountPoint) }

        // Checked after the copy: what gets installed is this copy, not what was on the image.
        let staged = work.appending(path: "Panes.app")
        try files.copyItem(at: mountPoint.appending(path: "Panes.app"), to: staged)
        guard satisfies(staged, appRequirement, flags: [.checkNestedCode]) else {
            throw InstallError("the app in the download isn't signed by Panes's developer.")
        }
        let info = NSDictionary(contentsOf: staged.appending(path: "Contents/Info.plist"))
        guard let version = (info?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
              version == release.version
        else { throw InstallError("the download holds a different version than the release.") }

        _ = try files.replaceItemAt(app, withItemAt: staged)
    }

    /// Waits for this process to exit, then opens the new copy: two instances would fight over the hotkeys.
    private func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do {
            try waiter.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Panes was updated. Quit and reopen it to finish.")
        }
    }

    private nonisolated static func expectOK(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw InstallError("GitHub answered with status \(status).") }
    }

    /// A plain eject first; a forced one if something (Spotlight, say) still has the volume open.
    /// It's read-only and finished with, so forcing loses nothing.
    private nonisolated static func eject(_ mountPoint: URL) {
        if (try? run("/usr/sbin/diskutil", "eject", mountPoint.path)) == nil {
            try? run("/usr/sbin/diskutil", "eject", "force", mountPoint.path)
        }
    }

    private nonisolated static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    private nonisolated static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError("\(URL(filePath: tool).lastPathComponent) failed with status \(process.terminationStatus).")
        }
    }

    private nonisolated static func satisfies(_ url: URL, _ requirement: String, flags: SecCSFlags = []) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled
        else { return false }
        let checks = flags.union([.checkAllArchitectures, .strictValidate])
        return SecStaticCodeCheckValidity(code, checks, compiled) == errSecSuccess
    }
}

/// Reports a download's byte counts. The task's own `didWriteData` callback never reaches a delegate
/// passed to the async `download(from:delegate:)`, but the task itself can be watched once it exists.
private final class DownloadObserver: NSObject, URLSessionTaskDelegate, Sendable {
    private let onBytes: @Sendable (_ received: Int64, _ expected: Int64) -> Void
    private let observation = Mutex<NSKeyValueObservation?>(nil)

    init(onBytes: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onBytes = onBytes
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let watch = task.observe(\.countOfBytesReceived) { [onBytes] task, _ in
            onBytes(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
        }
        observation.withLock { $0 = watch }
    }
}

extension SecCSFlags {
    static let checkAllArchitectures = SecCSFlags(rawValue: kSecCSCheckAllArchitectures)
    static let strictValidate = SecCSFlags(rawValue: kSecCSStrictValidate)
    static let checkNestedCode = SecCSFlags(rawValue: kSecCSCheckNestedCode)
}
