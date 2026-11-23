import SwiftUI

struct ConsoleBrowserView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.openWindow) private var openWindow
	@State private var pairing: PairTarget?
	@State private var connecting: String?
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
								busy: connecting == console.hostID || model.waking.contains(console.hostID),
								actionTitle: "Play",
								settings: { editing = console }
							) { connect(console) }
								.contextMenu {
									Button("Console Settings…") { editing = console }
									Divider()
									Button("Forget Console", role: .destructive) { model.forget(console) }
								}
						}
					}
				}

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
		guard let d = model.discoveredState(of: console) else { return "Offline · \(console.lastAddress)" }
		if let app = d.runningApp { return app }
		return d.state == .standby ? "Rest Mode" : "Ready"
	}

	private func connect(_ console: RegisteredConsole) {
		connecting = console.hostID
		Task {
			let session = await model.connect(console)
			connecting = nil
			if session != nil { openWindow(id: "stream") }
		}
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
	let busy: Bool
	let actionTitle: String
	var settings: (() -> Void)? = nil
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
					}
					.buttonStyle(.borderless)
					.foregroundStyle(.secondary)
					.help("Console Settings")
				}
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.headline).lineLimit(1)
				Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
			}
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
		}
		.padding(16)
		.background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
			.strokeBorder(.separator.opacity(hovering ? 1 : 0.5)))
		.onHover { hovering = $0 }
	}

	@ViewBuilder private var statusBadge: some View {
		let (label, color): (String, Color) = switch state {
		case .ready: ("On", .green)
		case .standby: ("Rest Mode", .orange)
		case .unknown: ("Unknown", .gray)
		case nil: ("Offline", .gray)
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
