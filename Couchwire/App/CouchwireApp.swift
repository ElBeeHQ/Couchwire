import SwiftUI

@main
enum Launcher {
	static func main() {
		// Hosting the unit tests: start nothing (no consoles, discovery, updates or windows).
		if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
			TestHostApp.main()
		} else {
			CouchwireApp.main()
		}
	}
}

/// The app as the CouchwireTests host: just enough for XCTest to run in.
private struct TestHostApp: App {
	var body: some Scene { Settings { EmptyView() } }
}

struct CouchwireApp: App {
	@State private var model: AppModel
	@AppStorage("showStats") private var showStats = false

	init() {
		Self.raiseOpenFileLimit()
		// Must run before AppModel loads consoles and settings from UserDefaults.
		LegacyDefaults.migrateIfNeeded()
		_model = State(initialValue: AppModel())
		_ = Updater.shared  // start Sparkle's scheduled checks at launch
	}

	/// macOS gives an app 256 open files and sockets. A connect over the internet can open 250 probe sockets at
	/// once, so the app ran out and quit. 1024 leaves room and keeps every socket number below select()'s limit.
	private static func raiseOpenFileLimit() {
		var limit = rlimit()
		guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < 1024 else { return }
		limit.rlim_cur = min(1024, limit.rlim_max)
		setrlimit(RLIMIT_NOFILE, &limit)
	}

	var body: some Scene {
		Window("Couchwire", id: "main") {
			ConsoleBrowserView()
				.environment(model)
				.preferredColorScheme(AppModel.demoColorScheme)
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
				Button(model.session?.micOn == true ? "Turn Microphone Off" : "Turn Microphone On") {
					model.session?.toggleMicrophone()
				}
				.keyboardShortcut("m", modifiers: [.command, .control])
				.disabled(model.session?.phase != .streaming)
				Button(model.session?.soundMuted == true ? "Unmute Game Sound" : "Mute Game Sound") {
					model.session?.soundMuted.toggle()
				}
				.keyboardShortcut("s", modifiers: [.command, .control])
				.disabled(model.session == nil)
			}
			CommandGroup(after: .windowArrangement) {
				Button("End Session") { model.endSession() }
					.keyboardShortcut("w", modifiers: [.command, .shift])
					.disabled(model.session == nil)
			}
		}

		.commands {
			CommandGroup(replacing: .appInfo) {
				Button("About Couchwire") { AboutPanel.show() }
				CheckForUpdatesButton()
			}
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
