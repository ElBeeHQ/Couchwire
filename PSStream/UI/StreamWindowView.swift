import AVFoundation
import SwiftUI

struct StreamWindowView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismissWindow) private var dismissWindow
	@AppStorage("showStats") private var showStats = false

	var body: some View {
		ZStack {
			Color.black
			if let session = model.session {
				VideoLayerView(layer: session.displayLayer, stats: session.statsCollector)
				overlay(for: session)
				if showStats, session.phase == .streaming {
					StatsOverlay(stats: session.stats)
						.padding(16)
						.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				}
			} else {
				Text("No active session").foregroundStyle(.secondary)
			}
		}
		.ignoresSafeArea()
		.frame(minWidth: 640, minHeight: 360)
		.background(WindowConfigurator())
		.onDisappear { model.endSession() }
	}

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.phase {
		case .connecting:
			StatusPanel {
				ProgressView().controlSize(.large)
				Text("Connecting to \(session.console.nickname)…")
			}
		case .needsPIN(let incorrect):
			PINPrompt(incorrect: incorrect) { session.submitPIN($0) }
		case .ended(let error):
			StatusPanel {
				Image(systemName: error == nil ? "checkmark.circle" : "exclamationmark.triangle")
					.font(.system(size: 32))
				Text(error ?? "Session ended")
					.multilineTextAlignment(.center)
				Button("Close") {
					model.endSession()
					dismissWindow(id: "stream")
				}
				.keyboardShortcut(.defaultAction)
			}
		case .streaming:
			CursorHider()
		}
	}
}

private struct StatusPanel<Content: View>: View {
	@ViewBuilder let content: Content
	var body: some View {
		VStack(spacing: 14) { content }
			.padding(28)
			.frame(maxWidth: 360)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
			.environment(\.colorScheme, .dark)
	}
}

private struct PINPrompt: View {
	let incorrect: Bool
	let submit: (String) -> Void
	@State private var pin = ""

	var body: some View {
		StatusPanel {
			Text("Enter Login Passcode").font(.headline)
			if incorrect { Text("Incorrect passcode, try again.").foregroundStyle(.red) }
			SecureField("Passcode", text: $pin)
				.textFieldStyle(.roundedBorder)
				.frame(width: 160)
				.onSubmit { submit(pin) }
			Button("Continue") { submit(pin) }
				.keyboardShortcut(.defaultAction)
				.disabled(pin.isEmpty)
		}
	}
}

/// Hosts the AVSampleBufferDisplayLayer directly as the view's backing layer, so frames
/// go from the hardware decoder to the compositor without passing through SwiftUI.
struct VideoLayerView: NSViewRepresentable {
	let layer: AVSampleBufferDisplayLayer
	let stats: StreamStats

	func makeNSView(context: Context) -> NSView {
		let view = LayerHostView()
		view.stats = stats
		view.wantsLayer = true
		view.layer = CALayer()
		view.layer?.backgroundColor = .black
		layer.frame = view.bounds
		layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
		view.layer?.addSublayer(layer)
		return view
	}

	func updateNSView(_ nsView: NSView, context: Context) {}

	final class LayerHostView: NSView {
		var stats: StreamStats?
		private var displayLink: CADisplayLink?

		override var isOpaque: Bool { true }
		override var acceptsFirstResponder: Bool { true }
		// Swallow key events so typing doesn't beep; keys reach the console via GCKeyboard.
		override func keyDown(with event: NSEvent) {
			if event.modifierFlags.contains(.command) { super.keyDown(with: event) }
		}
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			window?.makeFirstResponder(self)
			displayLink?.invalidate()
			displayLink = nil
			guard window != nil else { return }
			// Tracks the refresh cadence of whichever display the window is on, so we can
			// tell how long each decoded frame waits for the next refresh.
			let link = displayLink(target: self, selector: #selector(tick(_:)))
			link.add(to: .main, forMode: .common)
			displayLink = link
		}

		@objc private func tick(_ link: CADisplayLink) {
			stats?.vsync(timestamp: link.timestamp, duration: link.targetTimestamp - link.timestamp)
		}
	}
}

/// Locks the stream window to 16:9 and makes it behave like a game window.
private struct WindowConfigurator: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let v = NSView()
		DispatchQueue.main.async {
			guard let w = v.window else { return }
			w.contentAspectRatio = NSSize(width: 16, height: 9)
			w.collectionBehavior.insert(.fullScreenPrimary)
			w.backgroundColor = .black
			w.titlebarAppearsTransparent = true
			w.isMovableByWindowBackground = false
		}
		return v
	}
	func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hides the cursor while it is over the stream (it reappears when moved out or on Esc to the menu).
private struct CursorHider: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView { TrackingView() }
	func updateNSView(_ nsView: NSView, context: Context) {}

	final class TrackingView: NSView {
		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			trackingAreas.forEach(removeTrackingArea)
			addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
		}
		override func mouseEntered(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(true) }
		override func mouseMoved(with event: NSEvent) { NSCursor.setHiddenUntilMouseMoves(true) }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
	}
}
