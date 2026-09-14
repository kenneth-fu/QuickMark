import SwiftUI

/// The host app exists mainly so macOS has somewhere to find the extension.
/// It earns its keep by reporting whether the extension actually registered,
/// which is the one thing that tends to go wrong.
struct ContentView: View {
    @State private var status: ExtensionStatus = .checking

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            statusRow
            instructions
            Spacer(minLength: 0)
            footer
        }
        .padding(26)
        .frame(width: 460)
        .task { status = await ExtensionStatus.current() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("QuickMark")
                    .font(.title2.weight(.semibold))
                Text("Rendered Markdown in Finder's Quick Look")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 9) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.tint)
            Text(status.message)
                .font(.callout)
            Spacer()
            if status == .notRegistered {
                Button("Re-register") {
                    Task {
                        await ExtensionStatus.reregister()
                        status = await ExtensionStatus.current()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Getting started")
                .font(.subheadline.weight(.semibold))
            step(1, "Keep this app in your Applications folder.")
            step(2, "Select any .md file in Finder and press Space.")
            step(3, "If nothing changes, toggle QuickMark off and on under System Settings, General, Login Items & Extensions, Quick Look.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Open Quick Look Settings") {
                ExtensionStatus.openQuickLookSettings()
            }
            Spacer()
            Text(Bundle.main.shortVersion)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Extension status

enum ExtensionStatus: Equatable {
    case checking
    case registered
    case notRegistered
    case unknown

    var symbolName: String {
        switch self {
        case .checking: return "clock"
        case .registered: return "checkmark.circle.fill"
        case .notRegistered: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .checking: return .secondary
        case .registered: return .green
        case .notRegistered: return .orange
        case .unknown: return .secondary
        }
    }

    var message: String {
        switch self {
        case .checking: return "Checking extension registration…"
        case .registered: return "Preview extension is registered."
        case .notRegistered: return "Preview extension is not registered yet."
        case .unknown: return "Could not determine extension status."
        }
    }

    /// Asks pluginkit which Quick Look preview extensions macOS knows about.
    static func current() async -> ExtensionStatus {
        guard let output = await run(
            "/usr/bin/pluginkit",
            ["-m", "-p", "com.apple.quicklook.preview", "-v"]
        ) else {
            return .unknown
        }
        return output.contains(extensionBundleID) ? .registered : .notRegistered
    }

    /// Nudges LaunchServices to rescan this app bundle.
    static func reregister() async {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework"
            + "/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = await run(lsregister, ["-f", Bundle.main.bundlePath])
        _ = await run("/usr/bin/pluginkit", ["-a", extensionPath])
    }

    static func openQuickLookSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!
        NSWorkspace.shared.open(url)
    }

    private static var extensionBundleID: String {
        (Bundle.main.bundleIdentifier ?? "com.puiwaifu.QuickMark") + ".PreviewExtension"
    }

    private static var extensionPath: String {
        Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("PreviewExtension.appex")
            .path ?? ""
    }

    private static func run(_ launchPath: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: String(decoding: data, as: UTF8.self))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

private extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }
}
