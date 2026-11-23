import SwiftUI

/// Per-console preferences: stream quality, waking from rest mode and full screen.
struct ConsoleSettingsSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	let console: RegisteredConsole
	@State private var profile = ConsoleProfile()
	@State private var custom = StreamSettings()

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Form {
				Section {
					Toggle("Use Custom Stream Settings", isOn: Binding(
						get: { profile.customStream != nil },
						set: { profile.customStream = $0 ? custom : nil }))
					if profile.customStream != nil {
						StreamSettingsFields(settings: Binding(
							get: { profile.customStream ?? custom },
							set: { custom = $0; profile.customStream = $0 }))
					}
				} header: {
					Text("Video")
				} footer: {
					if profile.customStream == nil {
						Text("Uses the settings from Couchwire Settings.")
							.font(.caption)
							.foregroundStyle(.secondary)
					}
				}
				Section("When Connecting") {
					Toggle("Wake from Rest Mode", isOn: $profile.autoWake)
					Toggle("Open in Full Screen", isOn: $profile.autoFullScreen)
				}
			}
			.formStyle(.grouped)

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Done") {
					model.profiles[console.hostID] = profile
					dismiss()
				}
				.keyboardShortcut(.defaultAction)
			}
			.padding([.horizontal, .bottom], 20)
		}
		.frame(width: 460)
		.navigationTitle("\(console.nickname) Settings")
		.onAppear {
			profile = model.profile(for: console.hostID)
			custom = profile.customStream ?? model.settings
		}
	}
}
