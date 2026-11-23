import AppKit
import SwiftUI

/// The menu bar item: each paired console's state, with Play and Wake, without opening
/// the main window.
struct MenuBarContent: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow

	/// The Couchwire mark at menu bar size, as a template so it follows light and dark menus.
	static let icon: NSImage = {
		let source = NSImage(named: "CouchwireMark") ?? NSImage()
		let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
			source.draw(in: rect)
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = "Couchwire"
		return image
	}()

	var body: some View {
		Group {
			if model.registered.isEmpty {
				Text("No paired consoles")
				Button("Set Up Couchwire…") { showMain(); model.showingOnboarding = true }
			}
			ForEach(model.registered) { console in
				Section(console.nickname) {
					Text(status(of: console))
					if model.session?.console.hostID == console.hostID {
						Button("Show Stream") { openWindow(id: "stream"); NSApp.activate() }
						Button("End Session") { model.endSession() }
					} else {
						Button("Play") { play(console) }
							.disabled(model.session != nil || model.waking.contains(console.hostID))
						if model.discoveredState(of: console)?.state == .standby {
							Button("Wake Without Playing") { model.wake(console) }
								.disabled(model.waking.contains(console.hostID))
						}
					}
				}
			}
			Divider()
			Button("Open Couchwire") { showMain() }
			SettingsLink { Text("Settings…") }
				.keyboardShortcut(",")
			Divider()
			Button("Quit Couchwire") { NSApp.terminate(nil) }
				.keyboardShortcut("q")
		}
		.onAppear { model.startDiscovery() }
	}

	private func status(of console: RegisteredConsole) -> String {
		if model.waking.contains(console.hostID) { return "Waking…" }
		if model.session?.console.hostID == console.hostID { return "Streaming" }
		guard let d = model.discoveredState(of: console) else { return "Offline" }
		switch d.state {
		case .ready: return d.runningApp.map { "On · \($0)" } ?? "On"
		case .standby: return "Rest Mode"
		case .unknown: return "Unknown"
		}
	}

	private func showMain() {
		openWindow(id: "main")
		NSApp.activate()
	}

	private func play(_ console: RegisteredConsole) {
		Task {
			if await model.connect(console) != nil {
				openWindow(id: "stream")
				NSApp.activate()
			} else if model.lastError != nil {
				showMain() // the main window shows the error
			}
		}
	}
}
