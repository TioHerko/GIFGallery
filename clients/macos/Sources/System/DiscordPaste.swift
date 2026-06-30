import AppKit
import Carbon.HIToolbox

enum DiscordPaste {
    static let bundleID = "com.hnc.Discord"

    enum PasteError: LocalizedError {
        case notRunning
        case activationFailed
        case accessibilityDenied

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "Discord isn't running. Launch it and try again."
            case .activationFailed:
                return "Couldn't bring Discord to the front."
            case .accessibilityDenied:
                return "GIF Gallery needs Accessibility access to send keystrokes to Discord. Grant it in System Settings → Privacy & Security → Accessibility, then try again."
            }
        }
    }

    static func send(_ text: String) async throws {
        guard let discord = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID })
        else {
            throw PasteError.notRunning
        }

        // Prompts the user the first time; subsequent calls just report state.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        guard AXIsProcessTrustedWithOptions(options) else {
            throw PasteError.accessibilityDenied
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard discord.activate() else {
            throw PasteError.activationFailed
        }

        // Poll briefly for Discord to actually become frontmost.
        for _ in 0..<20 {
            if discord.isActive { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard discord.isActive else { throw PasteError.activationFailed }

        let pid = discord.processIdentifier
        let src = CGEventSource(stateID: .combinedSessionState)

        post(key: CGKeyCode(kVK_ANSI_V), flags: .maskCommand, pid: pid, source: src)
        try? await Task.sleep(for: .milliseconds(60))
        post(key: CGKeyCode(kVK_Return), flags: [], pid: pid, source: src)
    }

    private static func post(key: CGKeyCode, flags: CGEventFlags, pid: pid_t, source: CGEventSource?) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) {
            down.flags = flags
            down.postToPid(pid)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) {
            up.flags = flags
            up.postToPid(pid)
        }
    }
}
