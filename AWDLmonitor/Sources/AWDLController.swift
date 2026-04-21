import AppKit
import Combine
import Foundation

@MainActor
final class AWDLController: ObservableObject {
    enum Mode {
        case activeProtection
        case restored
        case unknown
    }

    @Published private(set) var mode: Mode = .unknown
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    var menuBarSymbolName: String {
        switch mode {
        case .activeProtection:
            return "wifi.slash"
        case .restored:
            return "wifi"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }

    var statusLine: String {
        if isBusy {
            return "Applying changes..."
        }

        switch mode {
        case .activeProtection:
            return "Protection is active. awdl0 will be forced down."
        case .restored:
            return "Default AWDL behavior is restored."
        case .unknown:
            return "Checking current AWDL state..."
        }
    }

    private let service = AWDLService()
    private var refreshTimer: Timer?

    init() {
        refreshStatus()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
    }

    func turnOff() {
        runAction {
            try self.service.enableProtection()
        }
    }

    func turnOn() {
        runAction {
            try self.service.disableProtection()
        }
    }

    func refreshStatus() {
        do {
            mode = try service.currentMode()
            if !isBusy {
                errorMessage = nil
            }
        } catch {
            mode = .unknown
            errorMessage = error.localizedDescription
        }
    }

    private func runAction(_ action: @escaping () throws -> Void) {
        isBusy = true
        errorMessage = nil

        Task {
            defer {
                isBusy = false
                refreshStatus()
            }

            do {
                try action()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct AWDLService {
    private let helperInstallPath = "/Library/PrivilegedHelperTools/com.awdlmonitor.awdlkiller"
    private let plistInstallPath = "/Library/LaunchDaemons/com.awdlmonitor.awdlkiller.plist"
    private let launchdLabel = "com.awdlmonitor.awdlkiller"

    func currentMode() throws -> AWDLController.Mode {
        let daemonRunning = try shell("/usr/bin/pgrep", arguments: ["-f", helperInstallPath]).exitCode == 0
        if daemonRunning {
            return .activeProtection
        }

        let awdlInfo = try shell("/sbin/ifconfig", arguments: ["awdl0"])
        if awdlInfo.standardOutput.contains("UP") || awdlInfo.standardOutput.contains("RUNNING") {
            return .restored
        }

        return .unknown
    }

    func enableProtection() throws {
        let helperURL = try bundledHelperURL()
        let plistURL = try writeLaunchDaemonPlist()

        let script = """
        /usr/bin/install -o root -g wheel -m 755 "\(helperURL.path)" "\(helperInstallPath)"
        /usr/bin/install -o root -g wheel -m 644 "\(plistURL.path)" "\(plistInstallPath)"
        /bin/launchctl bootout system "\(plistInstallPath)" >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "\(plistInstallPath)"
        /bin/launchctl enable system/\(launchdLabel) >/dev/null 2>&1 || true
        /bin/launchctl kickstart -k system/\(launchdLabel)
        """

        try runAdministratorScript(script)
    }

    func disableProtection() throws {
        let script = """
        /bin/launchctl bootout system "\(plistInstallPath)" >/dev/null 2>&1 || true
        /sbin/ifconfig awdl0 up
        """

        try runAdministratorScript(script)
    }

    private func bundledHelperURL() throws -> URL {
        guard let helperURL = Bundle.main.resourceURL?.appending(path: "awdlkiller-helper"),
              FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AWDLServiceError.missingHelper
        }

        return helperURL
    }

    private func writeLaunchDaemonPlist() throws -> URL {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(launchdLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperInstallPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """

        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.awdlmonitor.awdlkiller.plist")
        try plist.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    private func runAdministratorScript(_ script: String) throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("awdlmonitor-admin-\(UUID().uuidString).sh")
        let wrappedScript = """
        #!/bin/sh
        set -eu
        \(script)
        /bin/rm -f "$0"
        """
        try wrappedScript.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)

        let appleScriptSource = """
        do shell script "/bin/sh " & quoted form of "\(fileURL.path)" with administrator privileges
        """

        var errorInfo: NSDictionary?
        guard let scriptObject = NSAppleScript(source: appleScriptSource) else {
            throw AWDLServiceError.appleScriptCreationFailed
        }

        scriptObject.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Administrator privileges were not granted."
            throw AWDLServiceError.commandFailed(message)
        }
    }

    private func shell(_ launchPath: String, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw AWDLServiceError.commandFailed(error.localizedDescription)
        }

        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

struct CommandResult {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

enum AWDLServiceError: LocalizedError {
    case missingHelper
    case appleScriptCreationFailed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHelper:
            return "Bundled awdlkiller helper was not found in the app resources."
        case .appleScriptCreationFailed:
            return "Failed to create the administrator authorization prompt."
        case let .commandFailed(message):
            return message
        }
    }
}
