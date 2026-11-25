import SwiftUI

struct ConsoleBrowserView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	@State private var pairing: PairTarget?
	@State private var connecting: String?
	@State private var connectTask: Task<Void, Never>?
	@State private var editing: RegisteredConsole?
	@AppStorage("onboardingComplete") private var onboardingComplete = false

	var body: some View {
		@Bindable var model = model
		ScrollView {
			VStack(alignment: .leading, spacing: 24) {
				if !model.registered.isEmpty {
					section("My Consoles") {
						ForEach(model.registered) { console in
							ConsoleCard(
								title: console.nickname,
								subtitle: subtitle(for: console),
								state: model.discoveredState(of: console)?.state,
								waking: model.waking.contains(console.hostID),
								internet: model.playsOverInternet(console),
								busy: connecting == console.hostID || model.waking.contains(console.hostID),
								actionTitle: "Play",
								settings: { editing = console },
								cancel: connecting == console.hostID ? { cancelConnect() } : nil
							) { connect(console) }
								.contextMenu {
									Button("Console Settings…") { editing = console }
									Divider()
									Button("Forget Console", role: .destructive) { model.forget(console) }
								}
						}
					}
				}

				if !model.registered.isEmpty, model.unpaired.isEmpty {
					// Already set up and nothing new nearby: a quiet line, not a big spinner.
					HStack(spacing: 8) {
						ProgressView().controlSize(.mini)
						Text("Looking for other consoles on your network…")
					}
					.font(.callout)
					.foregroundStyle(.secondary)
				} else {
					section("Nearby") {
						if model.unpaired.isEmpty {
							HStack(spacing: 10) {
								ProgressView().controlSize(.small)
								Text("Looking for consoles on your network…")
									.foregroundStyle(.secondary)
							}
							.frame(maxWidth: .infinity, minHeight: 120)
						}
						ForEach(model.unpaired) { host in
							ConsoleCard(
								title: host.name,
								subtitle: host.address,
								state: host.state,
								busy: false,
								actionTitle: "Pair…"
							) { pairing = PairTarget(address: host.address, name: host.name, isPS5: host.isPS5) }
						}
					}
				}
			}
			.padding(24)
		}
		.navigationTitle("Couchwire")
		.toolbar {
			ToolbarItem {
				Button {
					pairing = PairTarget(address: "", name: nil, isPS5: true)
				} label: {
					Label("Add Console by IP Address", systemImage: "plus")
				}
				.help("Pair with a console by IP address")
			}
		}
		.sheet(item: $pairing) { target in
			PairingSheet(target: target)
		}
		.sheet(item: $editing) { console in
			ConsoleSettingsSheet(console: console)
		}
		.sheet(isPresented: $model.showingOnboarding) {
			OnboardingView()
		}
		.alert("Couldn’t Connect", isPresented: Binding(
			get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
		) {
			Button("OK") { model.lastError = nil }
		} message: {
			Text(model.lastError ?? "")
		}
		.onAppear {
			model.startDiscovery()
			// Existing users who already paired skip setup.
			if !onboardingComplete, model.registered.isEmpty { model.showingOnboarding = true }
		}
	}

	private func subtitle(for console: RegisteredConsole) -> String {
		// While waking the PS5 drops off the network for a few seconds; that isn't "Offline".
		if model.waking.contains(console.hostID) { return "Waking up…" }
		if model.playsOverInternet(console) { return "Away · Play over the internet" }
		guard let d = model.discoveredState(of: console) else { return "Offline · \(console.lastAddress)" }
		if let app = d.runningApp { return app }
		// The badge already says On or Rest Mode, so the subtitle says what Play will do.
		guard d.state == .standby else { return "Home network · \(d.address)" }
		return model.profile(for: console.hostID).autoWake ? "Play wakes it up" : "Wake from Rest Mode is off"
	}

	private func connect(_ console: RegisteredConsole) {
		// Play on another console while one is still connecting: that one stops, this one goes ahead.
		connectTask?.cancel()
		connecting = console.hostID
		connectTask = Task {
			let session = await model.connect(console)
			if Task.isCancelled {
				// Cancelled (state already cleared, maybe for a newer connect). If this connect had just
				// started a session, end that one, never one started since.
				if let session {
					if model.session === session { model.endSession() } else { session.stop() }
				}
				return
			}
			connectTask = nil
			connecting = nil
			if session != nil { openWindow(id: "stream") }
		}
	}

	/// Stops a connect that's still waking the console or getting ready.
	private func cancelConnect() {
		connectTask?.cancel()
		connectTask = nil
		connecting = nil
	}

	@ViewBuilder
	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title).font(.title3.weight(.semibold))
			LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
				content()
			}
		}
	}
}

struct PairTarget: Identifiable {
	let id = UUID()
	var address: String
	var name: String?
	var isPS5: Bool
}

struct ConsoleCard: View {
	let title: String
	let subtitle: String
	let state: DiscoveredConsole.State?
	var waking = false
	var internet = false
	let busy: Bool
	let actionTitle: String
	var settings: (() -> Void)? = nil
	/// While busy connecting: stops it.
	var cancel: (() -> Void)? = nil
	let action: () -> Void
	@State private var hovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack {
				Image("CouchwireMark")
					.resizable()
					.scaledToFit()
					.frame(width: 34, height: 34)
					.foregroundStyle(.tint)
				Spacer()
				statusBadge
				if let settings {
					Button(action: settings) {
						Image(systemName: "slider.horizontal.3")
							.padding(4)
							.contentShape(Rectangle())
					}
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Console Settings")
					.accessibilityLabel("Settings for \(title)")
				}
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.headline).lineLimit(1)
				Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
			}
			if busy, let cancel {
				Button(action: cancel) {
					HStack(spacing: 8) {
						ProgressView().controlSize(.small)
						Text("Cancel")
					}
					.frame(maxWidth: .infinity)
				}
				.buttonStyle(.bordered)
				.controlSize(.large)
				.help("Stop connecting")
			} else {
				Button(action: action) {
					if busy {
						ProgressView().controlSize(.small).frame(maxWidth: .infinity)
					} else {
						Text(actionTitle).frame(maxWidth: .infinity)
					}
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				.disabled(busy)
				.accessibilityLabel(busy ? "\(actionTitle), busy" : "\(actionTitle) \(title)")
			}
		}
		.padding(16)
		.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
			.strokeBorder(.separator.opacity(hovering ? 1 : 0.5)))
		.onHover { hovering = $0 }
	}

	@ViewBuilder private var statusBadge: some View {
		let (label, color): (String, Color) = switch (waking, state) {
		case (true, _): ("Waking", .orange)
		case (_, nil) where internet: ("Internet", .blue)
		case (_, .ready): ("On", .green)
		case (_, .standby): ("Rest Mode", .orange)
		case (_, .unknown): ("Unknown", .gray)
		case (_, nil): ("Offline", .gray)
		}
		Label(label, systemImage: "circle.fill")
			.labelStyle(BadgeLabelStyle(color: color))
			.font(.caption)
			.foregroundStyle(.secondary)
	}
}

private struct BadgeLabelStyle: LabelStyle {
	let color: Color
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.icon.font(.system(size: 7)).foregroundStyle(color)
			configuration.title
		}
	}
}
