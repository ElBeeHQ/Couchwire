import GameController
import SwiftUI

/// The slim strip that drops down from the top of the stream: status, controller battery,
/// and the session actions that are otherwise only in the menu bar.
struct StreamControls: View {
	let session: StreamSession
	@Binding var showStats: Bool
	let isFullScreen: Bool
	let toggleFullScreen: () -> Void
	let endSession: () -> Void
	/// The Sound popover is open; the window keeps the strip up meanwhile.
	@Binding var showingSound: Bool
	@State private var confirmingSleep = false

	var body: some View {
		HStack(spacing: 6) {
			// Status: which console, how responsive it feels right now, controller charge.
			HStack(spacing: 10) {
				Circle().fill(LatencyRating(ms: session.stats.observedMs).color).frame(width: 9, height: 9)
					.accessibilityLabel("Responsiveness: \(LatencyRating(ms: session.stats.observedMs).label)")
				VStack(alignment: .leading, spacing: 1) {
					Text(session.console.nickname).font(.system(size: 13, weight: .semibold))
					Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
				}
				ControllerBatteryView()
					.padding(.leading, 6)
			}
			.padding(.leading, 6)
			.padding(.trailing, 10)

			Divider().frame(height: 30)

			action(showStats ? "chart.bar.xaxis" : "chart.bar", showStats ? "Hide Stats" : "Show Stats",
				   help: "Show or hide the performance panel (⌥⌘I)", highlighted: showStats) {
				showStats.toggle()
			}
			action(session.micOn ? "mic.fill" : "mic.slash", "Microphone",
				   help: session.micProblem ?? (session.micOn ? "Stop sending your voice to the PS5 (⌃⌘M)" : "Talk in game and party chat (⌃⌘M)"),
				   highlighted: session.micOn) {
				session.toggleMicrophone()
			}
			action(soundSymbol, session.soundMuted ? "Muted" : "Sound",
				   help: "Game sound volume, or mute it (⌃⌘S mutes)", highlighted: session.soundMuted) {
				showingSound.toggle()
			}
			.popover(isPresented: $showingSound, arrowEdge: .bottom) {
				SoundPopover(session: session)
			}
			action(isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
				   isFullScreen ? "Exit Full Screen" : "Full Screen",
				   help: isFullScreen ? "Return to a window (Esc or fn F)" : "Fill the display (fn F)", action: toggleFullScreen)
			action("moon.zzz", "Rest Mode", help: "Put the console into rest mode and end the session") {
				confirmingSleep = true
			}
			action("xmark.circle", "End Session", help: "Disconnect and close this window (⇧⌘W)", destructive: true, action: endSession)
		}
		.padding(6)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
		.shadow(color: .black.opacity(0.35), radius: 14, y: 5)
		.environment(\.colorScheme, .dark)
		.confirmationDialog("Put \(session.console.nickname) into rest mode?", isPresented: $confirmingSleep) {
			Button("Rest Mode") {
				session.putConsoleToSleep()
			}
		} message: {
			Text("The console goes into rest mode and this session ends. Press Play to wake it again.")
		}
	}

	private var soundSymbol: String {
		if session.soundMuted || session.volume == 0 { return "speaker.slash.fill" }
		return session.volume < 0.34 ? "speaker.wave.1.fill" : session.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
	}

	private var statusLine: String {
		let ms = session.stats.observedMs
		return ms > 0 ? String(format: "%.0f ms button to screen", ms) : "Measuring…"
	}

	/// A labelled toolbar-style button: icon over a short caption, like a Mac toolbar.
	private func action(_ symbol: String, _ title: String, help: String, highlighted: Bool = false,
						destructive: Bool = false, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Image(systemName: symbol)
					.font(.system(size: 17, weight: .medium))
					.frame(height: 20)
				Text(title)
					.font(.system(size: 10.5, weight: .medium))
					.fixedSize()
			}
			.foregroundStyle(destructive ? AnyShapeStyle(.red) : highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
			.frame(minWidth: 64)
			.padding(.vertical, 7)
			.padding(.horizontal, 4)
			.contentShape(RoundedRectangle(cornerRadius: 10))
		}
		.buttonStyle(StripButtonStyle())
		.help(help)
		.accessibilityLabel(title)
		.accessibilityHint(help)
	}
}

/// Game sound: a volume slider and a mute switch. The PS5's own volume is separate.
private struct SoundPopover: View {
	@Bindable var session: StreamSession

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Game Sound").font(.headline)
			HStack(spacing: 8) {
				Image(systemName: "speaker.fill").foregroundStyle(.secondary).accessibilityHidden(true)
				Slider(value: $session.volume, in: 0...1)
					.frame(width: 160)
					.disabled(session.soundMuted)
					.accessibilityLabel("Game volume")
					.accessibilityValue("\(Int((session.volume * 100).rounded())) percent")
				Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).accessibilityHidden(true)
			}
			Toggle("Mute", isOn: $session.soundMuted)
				.toggleStyle(.switch)
				.help("Silence the game on this Mac (⌃⌘S). Your microphone isn't affected.")
		}
		.padding(14)
	}
}

/// Subtle hover and press highlight for the strip's buttons.
private struct StripButtonStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		StripButton(configuration: configuration)
	}

	private struct StripButton: View {
		let configuration: ButtonStyleConfiguration
		@State private var hovering = false
		var body: some View {
			configuration.label
				.background(
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.fill(.white.opacity(configuration.isPressed ? 0.18 : hovering ? 0.1 : 0))
				)
				.onHover { hovering = $0 }
		}
	}
}

/// Battery level of the current controller, from GameController. Hidden when the
/// controller doesn't report one.
struct ControllerBatteryView: View {
	var body: some View {
		TimelineView(.periodic(from: .now, by: 10)) { _ in
			if let battery = (GCController.current ?? GCController.controllers().first)?.battery {
				let level = Int((battery.batteryLevel * 100).rounded())
				HStack(spacing: 6) {
					Image(systemName: symbol(level: level, state: battery.batteryState))
						.font(.system(size: 18))
						.symbolRenderingMode(.hierarchical)
						.foregroundStyle(level <= 15 && battery.batteryState != .charging ? .red : .primary)
					VStack(alignment: .leading, spacing: 1) {
						Text("\(level)%").font(.system(size: 13, weight: .semibold)).monospacedDigit()
						Text(battery.batteryState == .charging ? "Charging" : "Controller")
							.font(.system(size: 11)).foregroundStyle(.secondary)
					}
				}
				.help(battery.batteryState == .charging ? "Controller charging" : battery.batteryState == .full ? "Controller fully charged" : "Controller battery")
			}
		}
	}

	private func symbol(level: Int, state: GCDeviceBattery.State) -> String {
		if state == .charging { return "battery.100percent.bolt" }
		switch level {
		case ..<13: return "battery.0percent"
		case ..<38: return "battery.25percent"
		case ..<63: return "battery.50percent"
		case ..<88: return "battery.75percent"
		default: return "battery.100percent"
		}
	}
}
