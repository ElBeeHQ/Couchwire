import AVFoundation
import GameController
import SwiftUI
import os

struct StreamWindowView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismissWindow) private var dismissWindow
	@AppStorage("showStats") private var showStats = false
	@AppStorage("psButtonTipSeen") private var psButtonTipSeen = false
	@State private var window = StreamWindowState()
	@State private var controlsVisible = false
	@State private var hoveringControls = false
	@State private var hideTask: Task<Void, Never>?

	var body: some View {
		// Only the black backdrop sizes the window. Everything else is an overlay, which
		// doesn't count towards the window's minimum size: a tall stats panel inside a ZStack
		// raised the minimum above the windowed size, so macOS couldn't leave full screen.
		Color.black
			.frame(minWidth: 640, minHeight: 360)
			.overlay {
				if let session = model.session {
					VideoLayerView(layer: session.displayLayer, stats: session.statsCollector)
						// A quiet retry swaps in a new session with its own layer: build a fresh view for it,
						// or the window keeps the old, empty layer and stays black.
						.id(ObjectIdentifier(session))
				} else if model.reconnecting == nil, model.reconnectError == nil {
					Text("No active session").foregroundStyle(.secondary)
				}
			}
			.overlay {
				if let session = model.session {
					overlay(for: session)
				} else if let console = model.reconnecting {
					StatusPanel {
						ProgressView().controlSize(.large)
						Text(model.reconnectReason == .lowerQuality
							 ? "Restarting \(console.nickname) at lower quality…"
							 : "Network changed. Reconnecting to \(console.nickname)…")
							.multilineTextAlignment(.center)
						Button("Cancel") {
							model.endSession()
							dismissWindow(id: "stream")
						}
						.keyboardShortcut(.cancelAction)
					}
				} else if let error = model.reconnectError {
					StatusPanel {
						Image(systemName: "exclamationmark.triangle").font(.system(size: 32))
						Text(error).multilineTextAlignment(.center)
						Button("Close") {
							model.endSession()
							dismissWindow(id: "stream")
						}
						.keyboardShortcut(.defaultAction)
					}
				}
			}
			.overlay(alignment: .topTrailing) {
				if showStats, let session = model.session, session.phase == .streaming {
					StatsOverlay(stats: session.stats)
						.padding(16)
						.padding(.top, controlsVisible ? controlsTop + 72 : 0)
				}
			}
			.overlay(alignment: .bottom) {
				if let session = model.session, session.phase == .streaming, session.struggling,
				   !session.strugglingDismissed, model.canLowerQuality(session) {
					StrugglingBanner(
						reason: session.struggleReason,
						airDrop: session.airDropMayCause,
						lower: { model.reconnectAtLowerQuality() },
						dismiss: { session.strugglingDismissed = true })
					.padding(24)
					.transition(.move(edge: .bottom).combined(with: .opacity))
				} else if let session = model.session, session.phase == .streaming, !psButtonTipSeen {
					PSButtonTip(done: { withAnimation { psButtonTipSeen = true } })
						.padding(24)
						.transition(.move(edge: .bottom).combined(with: .opacity))
				}
			}
			.overlay {
				if let session = model.session, session.phase == .streaming {
					controls(for: session)
				}
			}
			.ignoresSafeArea()
		.background(WindowConfigurator(state: window))
		.onDisappear { model.endSession() }
		.onChange(of: model.controlsRequest) { showControls(sticky: false) }
		.onChange(of: model.session?.phase) { _, phase in
			guard phase == .streaming, let s = model.session else { return }
			if model.profile(for: s.console.hostID).autoFullScreen, !window.isFullScreen {
				window.toggleFullScreen()
			}
		}
	}

	// MARK: Stream controls

	@ViewBuilder
	private func controls(for session: StreamSession) -> some View {
		ZStack(alignment: .top) {
			// Hot zone along the top edge, like the toolbar reveal in a full-screen Mac app.
			Color.clear
				.frame(maxWidth: .infinity)
				.frame(height: controlsTop + 34)
				.contentShape(Rectangle())
				.onContinuousHover { phase in
					if case .active = phase { showControls(sticky: false) }
				}
			// A sibling of the hot zone, not an overlay on it, so the whole strip is clickable
			// even where it extends below the zone.
			if controlsVisible {
				StreamControls(
					session: session,
					showStats: $showStats,
					isFullScreen: window.isFullScreen,
					toggleFullScreen: { window.toggleFullScreen() },
					endSession: {
						model.endSession()
						dismissWindow(id: "stream")
					})
				.onHover { hoveringControls = $0; if !$0 { scheduleHide() } }
				.padding(.top, controlsTop)
				.transition(.move(edge: .top).combined(with: .opacity))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.overlay { CursorHider(active: !controlsVisible) }
		.animation(.snappy(duration: 0.2), value: controlsVisible)
	}

	/// In full screen, pointing at the top edge also slides down the menu bar and title bar,
	/// so the strip sits just below them instead of underneath.
	private var controlsTop: CGFloat {
		window.isFullScreen ? window.revealedChromeHeight + 8 : 10
	}

	private func showControls(sticky: Bool) {
		controlsVisible = true
		scheduleHide()
	}

	private func scheduleHide() {
		hideTask?.cancel()
		hideTask = Task {
			try? await Task.sleep(for: .seconds(2.5))
			guard !Task.isCancelled else { return }
			if !hoveringControls { controlsVisible = false }
		}
	}

	@ViewBuilder
	private func overlay(for session: StreamSession) -> some View {
		switch session.phase {
		case .connecting:
			StatusPanel {
				ProgressView().controlSize(.large)
				let reconnecting = model.reconnecting != nil
				if session.internet != nil {
					Text(reconnecting
						 ? (model.reconnectReason == .lowerQuality ? "Restarting \(session.console.nickname) at lower quality over the internet" : "Network changed. Reconnecting to \(session.console.nickname) over the internet")
						 : "Connecting to \(session.console.nickname) over the internet")
						.multilineTextAlignment(.center)
					Text(internetStepText(session.internetStep, reconnecting: reconnecting, attempt: model.reconnectAttempt))
						.font(.callout)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
					Button("Cancel") {
						model.endSession()
						dismissWindow(id: "stream")
					}
					.keyboardShortcut(.cancelAction)
				} else {
					Text(reconnecting
						 ? (model.reconnectReason == .lowerQuality ? "Restarting \(session.console.nickname) at lower quality…" : "Network changed. Reconnecting to \(session.console.nickname)…")
						 : "Connecting to \(session.console.nickname)…")
					if session.waitingForRelease {
						Text("Waiting for your PS5 to let go of the last stream…")
							.font(.callout)
							.foregroundStyle(.secondary)
							.multilineTextAlignment(.center)
						Button("Cancel") {
							model.endSession()
							dismissWindow(id: "stream")
						}
						.keyboardShortcut(.cancelAction)
					}
				}
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
			EmptyView()
		}
	}
}

/// What an internet connection is doing, for the Connecting panel. It can take up to a minute.
/// PlayStation Network wakes the console if it's resting, but it's usually awake, so the console
/// step doesn't say "waking". After a network change the console is still holding the old stream,
/// which is what that step is waiting for, and a retry says so rather than looking like a fresh start.
private func internetStepText(_ step: CWPSNStep?, reconnecting: Bool, attempt: Int) -> String {
	let text = switch step {
	case CW_PSN_STEP_SESSION: "Contacting PlayStation Network…"
	case CW_PSN_STEP_CONSOLE: reconnecting
		? "Waiting for your PS5 to let go of the old stream. This can take up to a minute…"
		: "Asking your PS5 to start Remote Play…"
	case CW_PSN_STEP_CONNECTION: "Opening a direct connection to your PS5…"
	case CW_PSN_STEP_STREAM: "Starting the stream…"
	default: "Getting ready…"
	}
	return reconnecting && attempt > 1 ? "Try \(attempt): " + text : text
}

/// Shown when the stream keeps stuttering: offers to reconnect at lower quality.
private struct StrugglingBanner: View {
	let reason: StruggleDetector.Reason
	/// AirDrop's link was active: say turning AirDrop off may help.
	let airDrop: Bool
	let lower: () -> Void
	let dismiss: () -> Void

	var body: some View {
		HStack(spacing: 14) {
			Image(systemName: "wifi.exclamationmark")
				.font(.title2)
				.foregroundStyle(.orange)
			VStack(alignment: .leading, spacing: 2) {
				Text("Your connection is struggling").font(.headline)
				Text((reason == .loss ? "Video is getting lost on the way." : "Frames are arriving late and unevenly.")
					 + " Lower the quality for a smoother picture. The stream restarts, which takes a few seconds."
					 + (airDrop ? " AirDrop can also cause this: try turning it off in Control Centre." : ""))
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Button("Lower Quality", action: lower)
				.buttonStyle(.borderedProminent)
			Button(action: dismiss) {
				Image(systemName: "xmark")
			}
			.buttonStyle(.borderless)
			.help("Keep this quality")
		}
		.padding(16)
		.frame(maxWidth: 560)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.environment(\.colorScheme, .dark)
	}
}

/// Shown once, the first time you stream with a controller that has a PS (Home) button.
/// macOS keeps that button for its Games overlay unless the app is on the Home Button
/// Overrides list, which only you can change. Couchwire can't tell whether it's on the list.
private struct PSButtonTip: View {
	let done: () -> Void
	@State private var hasHomeButton = Self.controllerHasHomeButton

	private static var controllerHasHomeButton: Bool {
		GCController.controllers().contains { $0.extendedGamepad?.buttonHome != nil }
	}

	var body: some View {
		Group {
			if hasHomeButton {
				HStack(spacing: 14) {
					Image(systemName: "gamecontroller")
						.font(.title2)
					VStack(alignment: .leading, spacing: 2) {
						Text("Does the PS button open Games on your Mac?").font(.headline)
						Text("To send it to your PS5 instead, add Couchwire to Home Button Overrides in Game Controllers settings. You only need to do this once.")
							.font(.callout)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					Button("Open Settings") {
						if let url = URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension") {
							NSWorkspace.shared.open(url)
						}
						done()
					}
					.buttonStyle(.borderedProminent)
					Button(action: done) {
						Image(systemName: "xmark")
					}
					.buttonStyle(.borderless)
					.help("Don’t show this again")
				}
				.padding(16)
				.frame(maxWidth: 560)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
				.environment(\.colorScheme, .dark)
			}
		}
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect).receive(on: RunLoop.main)) { _ in
			hasHomeButton = Self.controllerHasHomeButton
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
			if event.modifierFlags.contains(.command) { super.keyDown(with: event); return }
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

/// The stream window's AppKit side: full-screen state and the toggle.
@MainActor
@Observable
final class StreamWindowState {
	@ObservationIgnored weak var window: NSWindow?
	var isFullScreen = false

	/// How far the menu bar and title bar reach into the window when they slide down over a
	/// full-screen window.
	var revealedChromeHeight: CGFloat {
		let titleBar = NSWindow.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .titled).height - 100
		// On displays with a camera housing the full-screen window starts below the menu bar,
		// so only the title bar overlaps it.
		let notch = (window?.screen?.safeAreaInsets.top ?? 0) > 0
		let menuBar = notch ? 0 : (NSApp.mainMenu?.menuBarHeight ?? 24)
		return titleBar + menuBar
	}

	func toggleFullScreen() {
		guard let window else { return }
		Self.allowFullScreen(window)
		// The strip's button takes focus from the stream; give it back after the toggle.
		window.makeKeyAndOrderFront(nil)
		window.toggleFullScreen(nil)
	}

	/// SwiftUI marks this window as auxiliary (a companion to the main window) and keeps
	/// re-applying that, including as it enters full screen. macOS won't take an auxiliary window
	/// out of full screen, and won't offer full screen for one at all. Make it a primary window;
	/// call this before every full-screen change and right after entering.
	static func allowFullScreen(_ w: NSWindow) {
		var behavior = w.collectionBehavior
		behavior.remove([.fullScreenNone, .fullScreenAuxiliary, .auxiliary])
		behavior.insert([.fullScreenPrimary, .primary])
		if behavior != w.collectionBehavior {
			w.collectionBehavior = behavior
		}
	}



}

/// Locks the windowed stream to 16:9 and makes it behave like a game window. In full screen
/// the lock is lifted so the window covers the whole display, as any native full-screen app
/// does; the video is letterboxed inside it if the display isn't 16:9.
private struct WindowConfigurator: NSViewRepresentable {
	let state: StreamWindowState

	func makeNSView(context: Context) -> NSView {
		let v = HostView()
		v.onWindow = { w in context.coordinator.attach(w, state: state) }
		return v
	}

	func updateNSView(_ nsView: NSView, context: Context) {}
	func makeCoordinator() -> Coordinator { Coordinator() }

	/// Reports its window as soon as it is placed in one, rather than guessing when.
	final class HostView: NSView {
		var onWindow: ((NSWindow) -> Void)?
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if let window { onWindow?(window) }
		}
	}

	@MainActor
	final class Coordinator {
		private var observers: [NSObjectProtocol] = []
		private var keyMonitor: Any?
		private weak var attached: NSWindow?

		func attach(_ w: NSWindow, state: StreamWindowState) {
			guard w !== attached else { return }
			attached = w
			state.window = w
			// SwiftUI finishes configuring its window after the view moves into it and would
			// overwrite these (dropping full-screen support), so apply them on the next turn
			// of the run loop, and again whenever the window comes to the front.
			DispatchQueue.main.async {
				state.isFullScreen = w.styleMask.contains(.fullScreen)
				if !state.isFullScreen { lockAspect(w, snap: true) }
				Self.configure(w)
			}

			let nc = NotificationCenter.default
			observers.forEach(nc.removeObserver)
			observers = [
				nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
					MainActor.assumeIsolated { Self.configure(w) }
				},
				// SwiftUI re-marks the window auxiliary on its own schedule (entering and leaving
				// full screen among others). Check on every window update and correct it only
				// when it has changed, so full screen stays available in both directions.
				nc.addObserver(forName: NSWindow.didUpdateNotification, object: w, queue: .main) { _ in
					MainActor.assumeIsolated { StreamWindowState.allowFullScreen(w) }
				},
				nc.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: w, queue: .main) { _ in
					MainActor.assumeIsolated {
						// Any aspect constraint stops the full-screen frame from covering the display.
						w.contentResizeIncrements = NSSize(width: 1, height: 1)
						state.isFullScreen = true
					}
				},
				nc.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: w, queue: .main) { _ in
					// SwiftUI marks the window auxiliary again while entering; undo that once it's
					// done, so the green button, the View menu and Esc can all bring it back out.
					DispatchQueue.main.async { MainActor.assumeIsolated { StreamWindowState.allowFullScreen(w) } }
				},
				nc.addObserver(forName: NSWindow.didExitFullScreenNotification, object: w, queue: .main) { _ in
					MainActor.assumeIsolated {
						state.isFullScreen = false
						lockAspect(w, snap: true)
					}
				},
			]
			// Esc leaves full screen wherever focus is in the window, as in QuickTime. Esc isn't
			// mapped to a console button, so the game never needs it.
			if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
			keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] event in
				guard event.keyCode == 53, let w, event.window === w, w.styleMask.contains(.fullScreen) else { return event }
				StreamWindowState.allowFullScreen(w)
				w.toggleFullScreen(nil)
				return nil
			}
		}

		private static func configure(_ w: NSWindow) {
			StreamWindowState.allowFullScreen(w)
			guard !w.styleMask.contains(.fullScreen) else { return }
			// A stream can't be resumed after relaunch, so never reopen this window at launch.
			if w.isRestorable { w.isRestorable = false }
			if w.backgroundColor != .black { w.backgroundColor = .black }
			if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
			if w.isMovableByWindowBackground { w.isMovableByWindowBackground = false }
		}

		deinit {
			observers.forEach(NotificationCenter.default.removeObserver)
			if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
		}
	}
}

/// 16:9 for live resizes, and snap the current size to it (keeping the width) so there are no bars.
@MainActor
private func lockAspect(_ w: NSWindow, snap: Bool) {
	w.contentAspectRatio = NSSize(width: 16, height: 9)
	if snap {
		let size = w.contentLayoutRect.size
		w.setContentSize(NSSize(width: size.width, height: (size.width * 9 / 16).rounded()))
	}
}

/// Hides the pointer over the stream once it stops moving, like QuickTime; moving the mouse
/// brings it back. Stays visible while the stream controls are showing.
private struct CursorHider: NSViewRepresentable {
	/// False while the stream controls are showing, so the pointer can reach them.
	var active = true

	func makeNSView(context: Context) -> NSView { TrackingView() }
	func updateNSView(_ nsView: NSView, context: Context) {
		(nsView as? TrackingView)?.active = active
	}

	final class TrackingView: NSView {
		private var hideTimer: Timer?
		private var inside = false
		var active = true {
			didSet { if active != oldValue { scheduleHide() } }
		}

		override func updateTrackingAreas() {
			super.updateTrackingAreas()
			trackingAreas.forEach(removeTrackingArea)
			addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
		}
		override func mouseEntered(with event: NSEvent) { inside = true; scheduleHide() }
		override func mouseExited(with event: NSEvent) { inside = false; hideTimer?.invalidate() }
		override func mouseMoved(with event: NSEvent) { inside = true; scheduleHide() }
		override func hitTest(_ point: NSPoint) -> NSView? { nil }
		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { hideTimer?.invalidate() } else { scheduleHide(after: 0.1) }
		}

		private func scheduleHide(after delay: TimeInterval = 1.0) {
			hideTimer?.invalidate()
			guard active else { return }
			hideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
				guard let self, active, let window, window.isKeyWindow else { return }
				// The pointer may be over the view without an "entered" event yet (e.g. at launch).
				let p = window.mouseLocationOutsideOfEventStream
				guard inside || bounds.contains(convert(p, from: nil)) else { return }
				NSCursor.setHiddenUntilMouseMoves(true)
			}
		}
	}
}
