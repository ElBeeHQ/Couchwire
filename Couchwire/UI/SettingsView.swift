import SwiftUI

struct SettingsView: View {
	@Environment(AppModel.self) private var model
	@State private var signingIn = false

	private var videoFooter: String {
		var parts: [String] = []
		parts.append(model.autoQuality
			? "Each stream starts at what your connection can handle, up to the settings above: lower over the internet and on mobile hotspots. Couchwire learns from every session."
			: "Every stream uses the settings above.")
		switch model.smoothing {
		case .off: break
		case .automatic:
			parts.append("Smoothing holds frames back for a moment when they arrive unevenly, so play looks steady. On a steady network it adds no delay; on a mobile hotspot it works hardest, for a smoother picture but more delay.")
		case .balanced:
			parts.append("Smoothing holds frames back for a moment when they arrive unevenly, so play looks steady. On a steady network it adds no delay.")
		case .steadiest:
			parts.append("Steadiest smoothing also covers the rare long gaps of mobile networks, for the smoothest picture but more delay.")
		}
		return parts.joined(separator: " ")
	}

	var body: some View {
		TabView {
			videoTab
				.tabItem { Label("Video", systemImage: "play.rectangle") }
			accountTab
				.tabItem { Label("Account", systemImage: "person.crop.circle") }
			Form { UpdateSettingsSection() }
				.formStyle(.grouped)
				.tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
		}
		.frame(width: 460)
		.fixedSize()
		.sheet(isPresented: $signingIn) {
			PSNSignInSheet { model.signedIn($0) }
		}
		.task { await model.checkPSNSignIn() }
	}

	private var videoTab: some View {
		@Bindable var model = model
		return Form {
			Section {
				StreamSettingsFields(settings: $model.settings)
				Toggle("Adjust quality to the connection", isOn: $model.autoQuality)
				Picker("Smoothing", selection: $model.smoothing) {
					ForEach(SmoothingMode.allCases) { Text($0.name).tag($0) }
				}
			} footer: {
				Text(videoFooter)
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section {
				Text("For the lowest latency, connect your Mac and PS5 with Ethernet, and play in full screen so macOS Game Mode turns on.")
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.formStyle(.grouped)
	}

	private var accountTab: some View {
		@Bindable var model = model
		return Form {
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
				Text("Needed once, to pair with a console. Signing in saves only your Account ID, unless Internet Play is on.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			Section {
				Toggle("Play over the internet", isOn: Binding(
					get: { model.internetPlay },
					set: { on in
						model.internetPlay = on
						// Internet play needs a sign-in to keep; ask for one straight away.
						if on, !model.psnSignedIn { signingIn = true }
					}))
				if model.internetPlay {
					LabeledContent("PlayStation Network") {
						HStack {
							Text(model.psnSignedIn ? "Signed in" : "Not signed in")
								.foregroundStyle(model.psnSignedIn ? Color.secondary : Color.orange)
							Button(model.psnSignedIn ? "Sign Out" : "Sign In…") {
								if model.psnSignedIn { model.signOutOfPSN() } else { signingIn = true }
							}
						}
					}
					Toggle("Try harder on difficult networks", isOn: $model.forcePortGuessing)
				}
			} header: {
				Text("Internet Play")
			} footer: {
				Text(model.forcePortGuessing && model.internetPlay
					 ? "Play your PS5 away from home. Couchwire stays signed in to PlayStation Network, with the sign-in kept in your Mac’s Keychain. Trying harder helps on mobile hotspots and some routers, but connecting takes longer."
					 : "Play your PS5 away from home. Couchwire stays signed in to PlayStation Network, with the sign-in kept in your Mac’s Keychain. Turn this off to sign out and delete it.")
					.font(.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.formStyle(.grouped)
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
