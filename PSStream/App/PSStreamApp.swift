import SwiftUI

@main
struct PSStreamApp: App {
	@State private var model = AppModel()

	var body: some Scene {
		Window("PSStream", id: "main") {
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
			CommandGroup(after: .windowArrangement) {
				Button("End Session") { model.endSession() }
					.keyboardShortcut("w", modifiers: [.command, .shift])
					.disabled(model.session == nil)
			}
		}

		Settings {
			SettingsView()
				.environment(model)
		}
	}
}
