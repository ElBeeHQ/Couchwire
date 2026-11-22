import SwiftUI

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@State private var signingIn = false

	var body: some View {
		@Bindable var model = model
		Form {
			Section("Video") {
				Picker("Resolution", selection: $model.settings.resolution) {
					ForEach(StreamSettings.Resolution.allCases) { Text($0.rawValue).tag($0) }
				}
				Picker("Frame Rate", selection: $model.settings.fps) {
					Text("30 fps").tag(30)
					Text("60 fps").tag(60)
				}
				Picker("Codec", selection: $model.settings.codec) {
					ForEach(StreamSettings.Codec.allCases) { Text($0.rawValue).tag($0) }
				}
				LabeledContent("Bitrate") {
					HStack {
						Slider(value: Binding(
							get: { Double(model.settings.bitrate) },
							set: { model.settings.bitrate = Int($0) }), in: 5_000...50_000, step: 1_000)
						Text("\(model.settings.bitrate / 1000) Mbps")
							.monospacedDigit()
							.frame(width: 64, alignment: .trailing)
					}
				}
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
