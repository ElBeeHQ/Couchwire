import SwiftUI

@main
struct CouchwireApp: App {
	@State private var model: AppModel
	@AppStorage("showStats") private var showStats = false

	init() {
		// Must run before AppModel loads consoles and settings from UserDefaults.
		LegacyDefaults.migrateIfNeeded()
		_model = State(initialValue: AppModel())
	}

	var body: some Scene {
		Window("Couchwire", id: "main") {
			ConsoleBrowserView()
				.environment(model)
				.frame(minWidth: 560, minHeight: 380)
		}
		.windowToolbarStyle(.unified)
		.defaultSize(width: 760, height: 480)

		Window("Remote Play", id: "stream") {
			StreamWindowView()
				.environment(model)
		}
		.windowStyle(.hiddenTitleBar)
		.defaultSize(width: 1280, height: 720)
		.commands {
			CommandGroup(after: .toolbar) {
				Button("Show Stream Controls") { model.controlsRequest += 1 }
					.keyboardShortcut("c", modifiers: [.command, .control])
					.disabled(model.session == nil)
				Toggle("Show Performance Stats", isOn: $showStats)
					.keyboardShortcut("i", modifiers: [.command, .option])
			}
			CommandGroup(after: .windowArrangement) {
				Button("End Session") { model.endSession() }
					.keyboardShortcut("w", modifiers: [.command, .shift])
					.disabled(model.session == nil)
			}
		}

		.commands {
			CommandGroup(replacing: .help) {
				Button("Set Up Couchwire…") { model.showingOnboarding = true }
			}
		}

		MenuBarExtra {
			MenuBarContent()
				.environment(model)
		} label: {
			Image(nsImage: MenuBarContent.icon)
		}

		Settings {
			SettingsView()
				.environment(model)
		}
	}
}
