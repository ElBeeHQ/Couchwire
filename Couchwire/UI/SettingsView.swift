import SwiftUI

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@State private var signingIn = false
	@AppStorage(ControllerInput.touchGesturesKey) private var touchGestures = false

	var body: some View {
		@Bindable var model = model
		Form {
			Section("Video") {
				StreamSettingsFields(settings: $model.settings)
			}
			Section {
				Toggle("Send Touchpad Swipes", isOn: $touchGestures)
			} header: {
				Text("Controller")
			} footer: {
				Text("Over Remote Play the PS5 treats any finger on the touchpad as a press. Leave this off unless a game needs swipes; clicking the touchpad always works.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				LabeledContent("PSN Account ID") {
					HStack {
						Text(model.accountID.isEmpty ? "Not signed in" : model.accountID)
							.font(.body.monospaced())
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
						Button(model.accountID.isEmpty ? "Sign In…" : "Change…") { signingIn = true }
					}
				}
				TextField("Enter Manually", text: $model.accountID, prompt: Text("Base64, e.g. AbCdEfGhIjk="))
			} header: {
				Text("Account")
			} footer: {
				Text("Needed once, to pair with a console. Signing in only saves your Account ID.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section {
				Text("For the lowest latency, connect your Mac and PS5 with Ethernet, and play in full screen so macOS Game Mode turns on.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
		.fixedSize()
		.sheet(isPresented: $signingIn) {
			PSNSignInSheet { model.accountID = $0 }
		}
	}
}

/// Resolution, frame rate, codec and bitrate pickers, shared by app-wide and per-console settings.
struct StreamSettingsFields: View {
	@Binding var settings: StreamSettings

	var body: some View {
		Picker("Resolution", selection: $settings.resolution) {
			ForEach(StreamSettings.Resolution.allCases) { Text($0.rawValue).tag($0) }
		}
		Picker("Frame Rate", selection: $settings.fps) {
			Text("30 fps").tag(30)
			Text("60 fps").tag(60)
		}
		Picker("Codec", selection: $settings.codec) {
			ForEach(StreamSettings.Codec.allCases) { c in
				Text(c.rawValue).tag(c)
			}
		}
		if settings.codec == .hevcHDR {
			Text("HDR shows when the game outputs it and HDR is on in the PS5's screen settings. Best on an XDR or HDR display.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
		}
		LabeledContent("Bitrate") {
			HStack {
				Slider(value: Binding(
					get: { Double(settings.bitrate) },
					set: { settings.bitrate = Int($0) }), in: 5_000...50_000, step: 1_000)
				Text("\(settings.bitrate / 1000) Mbps")
					.monospacedDigit()
					.frame(width: 64, alignment: .trailing)
			}
		}
	}
}
