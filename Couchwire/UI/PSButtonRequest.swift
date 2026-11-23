import GameController
import SwiftUI

/// During setup: asks macOS for the PS (Home) button as soon as a controller is connected, so macOS
/// shows its own "Allow / Don't Allow" prompt while you're looking at setup, rather than partway into
/// your first stream. macOS asks once per app; after that only System Settings › Game Controllers ›
/// Home Button Overrides changes it. The request is dropped again when setup closes, so the PS button
/// works as normal on the Mac until a stream starts.
struct PSButtonRequest<Placeholder: View>: View {
	/// Drawn as a box (on its own) or as a plain row (in a list of rows).
	var boxed = true
	/// Shown while no controller is connected.
	@ViewBuilder var placeholder: Placeholder
	@Environment(AppModel.self) private var model
	@Environment(\.openURL) private var openURL
	@State private var controllerName: String?

	var body: some View {
		Group {
			if let controllerName {
				HStack(alignment: .top, spacing: 12) {
					Image(systemName: "gamecontroller")
						.font(.title3)
						.foregroundStyle(.tint)
						.frame(width: 28)
					VStack(alignment: .leading, spacing: 4) {
						Text("\(controllerName) connected").font(.callout.weight(.semibold))
						Text("macOS may ask whether Couchwire can respond to the PS button. Click **Allow**, so the PS button opens your PS5’s menu instead of Games on your Mac.")
							.font(.callout)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						Button("Missed it? Open Game Controllers Settings") {
							openURL(URL(string: "x-apple.systempreferences:com.apple.Game-Controller-Settings.extension")!)
						}
						.buttonStyle(.link)
						.font(.callout)
						.help("Add Couchwire to Home Button Overrides")
					}
				}
				.padding(boxed ? 14 : 0)
				.frame(maxWidth: .infinity, alignment: .leading)
				.background(boxed ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 10))
			} else {
				placeholder
			}
		}
		.onAppear(perform: refresh)
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect).receive(on: RunLoop.main)) { _ in refresh() }
		.onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect).receive(on: RunLoop.main)) { _ in refresh() }
		// A stream claims the button for itself; leave it be if one is running.
		.onDisappear { if model.session == nil { Self.request(false) } }
	}

	private func refresh() {
		let pad = Self.controllersWithHome.first
		controllerName = pad.map { $0.vendorName ?? "Controller" }
		if pad != nil { Self.request(true) }
	}

	private static var controllersWithHome: [GCController] {
		GCController.controllers().filter { $0.extendedGamepad?.buttonHome != nil }
	}

	private static func request(_ on: Bool) { PSButton.request(on) }
}

extension PSButtonRequest where Placeholder == EmptyView {
	init(boxed: Bool = true) { self.init(boxed: boxed) { EmptyView() } }
}

enum PSButton {
	/// Asks for (or hands back) the Home button on every connected controller.
	static func request(_ on: Bool) {
		for c in GCController.controllers() {
			c.extendedGamepad?.buttonHome?.preferredSystemGestureState = on ? .disabled : .enabled
		}
	}
}
