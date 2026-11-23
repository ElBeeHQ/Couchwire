import Combine
import Sparkle
import SwiftUI

/// In-app updates through Sparkle. The feed (SUFeedURL) and the EdDSA public key that every
/// update must be signed with (SUPublicEDKey) are in Info.plist; scripts/package.sh signs
/// each DMG and writes the appcast.
@MainActor
final class Updater: ObservableObject {
	static let shared = Updater()

	private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
	@Published private(set) var canCheckForUpdates = false
	private var observation: AnyCancellable?

	private init() {
		observation = controller.updater.publisher(for: \.canCheckForUpdates)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] in self?.canCheckForUpdates = $0 }
	}

	var automaticallyChecks: Bool {
		get { controller.updater.automaticallyChecksForUpdates }
		set {
			controller.updater.automaticallyChecksForUpdates = newValue
			objectWillChange.send()
		}
	}

	func checkForUpdates() { controller.checkForUpdates(nil) }
}

/// "Check for Updates…" for the app menu.
struct CheckForUpdatesButton: View {
	@ObservedObject private var updater = Updater.shared

	var body: some View {
		Button("Check for Updates…") { updater.checkForUpdates() }
			.disabled(!updater.canCheckForUpdates)
	}
}

/// Settings row for automatic update checks.
struct UpdateSettingsSection: View {
	@ObservedObject private var updater = Updater.shared

	var body: some View {
		Section("Updates") {
			Toggle("Automatically check for updates", isOn: Binding(
				get: { updater.automaticallyChecks },
				set: { updater.automaticallyChecks = $0 }))
			LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
			HStack {
				Spacer()
				CheckForUpdatesButton()
			}
		}
	}
}
