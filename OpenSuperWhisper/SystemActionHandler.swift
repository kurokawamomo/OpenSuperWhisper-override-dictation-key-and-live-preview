import Foundation

/// The action to run when KeyEventHandler resolves a tap (as opposed to a
/// hold). Selected by `AppPreferences.tapAction`.
enum TapAction: String, CaseIterable, Identifiable {
    case none
    case launchSiri
    case customScript

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .launchSiri: return "Launch Siri"
        case .customScript: return "Custom Script"
        }
    }
}

/// Executes OS-level actions triggered by a resolved tap. Kept separate
/// from `KeyEventHandler` so tap/hold detection stays independent of what a
/// tap actually does.
final class SystemActionHandler {
    static let shared = SystemActionHandler()

    private init() {}

    func performTapAction() {
        let action = TapAction(rawValue: AppPreferences.shared.tapAction) ?? .none

        switch action {
        case .none:
            break
        case .launchSiri:
            launchSiri()
        case .customScript:
            runCustomScript()
        }
    }

    private func launchSiri() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Siri"]
            do {
                try process.run()
            } catch {
                print("SystemActionHandler: Failed to launch Siri: \(error)")
            }
        }
    }

    private func runCustomScript() {
        let path = AppPreferences.shared.tapActionCustomScriptPath
        print("SystemActionHandler: Custom script tap action is not implemented yet (configured path: \(path))")
    }
}
