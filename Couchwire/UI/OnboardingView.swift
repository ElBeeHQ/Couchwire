import SwiftUI

/// First-run setup: switch on Remote Play on the console, sign in to get the Account ID,
/// then pair. Shown over the console list until a console is paired; reopen it from
/// Help › Set Up Couchwire….
struct OnboardingView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@AppStorage("onboardingComplete") private var complete = false
	@State private var step = Step.remotePlay
	@State private var signingIn = false
	@State private var manualID = ""
	@State private var pairing: PairTarget?

	enum Step: Int, CaseIterable {
		case remotePlay, signIn, pair
		var title: String {
			switch self {
			case .remotePlay: "Turn On Remote Play"
			case .signIn: "Sign In to PlayStation Network"
			case .pair: "Pair Your Console"
			}
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			Group {
				switch step {
				case .remotePlay: remotePlay
				case .signIn: signIn
				case .pair: pair
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
			.padding(28)
			Divider()
			footer
		}
		.frame(width: 560, height: 470)
		.sheet(isPresented: $signingIn) {
			PSNSignInSheet { model.accountID = $0 }
		}
		.sheet(item: $pairing) { PairingSheet(target: $0) }
		.onAppear { model.startDiscovery() }
	}

	// MARK: Chrome

	private var header: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 10) {
				Image("CouchwireMark")
					.resizable().scaledToFit()
					.frame(width: 26, height: 26)
					.foregroundStyle(.tint)
				Text("Set Up Couchwire").font(.headline)
				Spacer()
				Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
					.font(.callout).foregroundStyle(.secondary)
			}
			HStack(spacing: 6) {
				ForEach(Step.allCases, id: \.self) { s in
					Capsule()
						.fill(s.rawValue <= step.rawValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
						.frame(height: 4)
				}
			}
			Text(step.title).font(.title2.weight(.semibold))
		}
		.padding([.horizontal, .top], 28)
		.padding(.bottom, 18)
	}

	private var footer: some View {
		HStack {
			if step == .remotePlay {
				Button("Set Up Later") { finish() }
			} else {
				Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
			}
			Spacer()
			switch step {
			case .remotePlay:
				Button("Continue") { step = .signIn }.keyboardShortcut(.defaultAction)
			case .signIn:
				Button("Continue") { step = .pair }
					.keyboardShortcut(.defaultAction)
					.disabled(model.accountID.isEmpty)
			case .pair:
				Button("Done") { finish() }
					.keyboardShortcut(.defaultAction)
					.disabled(model.registered.isEmpty)
			}
		}
		.padding(.horizontal, 28)
		.padding(.vertical, 16)
	}

	private func finish() {
		complete = true
		dismiss()
	}

	// MARK: Steps

	private var remotePlay: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text("On your PS5, switch on Remote Play and let the console wake from the network. You only need to do this once.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			instruction(1, "Settings › System › Remote Play", "Turn on **Enable Remote Play**.")
			instruction(2, "Settings › System › Power Saving › Features Available in Rest Mode",
						"Turn on **Stay Connected to the Internet** and **Enable Turning On PS5 from Network**, so Couchwire can wake it.")
			instruction(3, "Same network", "Connect your Mac and PS5 to the same network. Ethernet on both gives the lowest latency.")
		}
	}

	private var signIn: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text("Pairing needs your PSN Account ID. Couchwire only saves that ID; your password goes straight to Sony and is never stored.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			if model.accountID.isEmpty {
				Button {
					signingIn = true
				} label: {
					Label("Sign In with PlayStation Network…", systemImage: "person.crop.circle")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				DisclosureGroup("Enter Account ID manually") {
					HStack {
						TextField("Account ID", text: $manualID, prompt: Text("Base64, e.g. AbCdEfGhIjk="))
							.textFieldStyle(.roundedBorder)
							.font(.body.monospaced())
						Button("Use") { model.accountID = manualID.trimmingCharacters(in: .whitespaces) }
							.disabled(Data(base64Encoded: manualID.trimmingCharacters(in: .whitespaces))?.count != 8)
					}
					.padding(.top, 6)
				}
			} else {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Signed in").font(.headline)
						Text(model.accountID).font(.body.monospaced()).foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
				}
				Button("Use a Different Account…") { signingIn = true }
					.buttonStyle(.link)
			}
		}
	}

	private var pair: some View {
		VStack(alignment: .leading, spacing: 14) {
			if let paired = model.registered.first {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("\(paired.nickname) is paired").font(.headline)
						Text("Click Done, then Play on its card to start streaming.").foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
				}
			} else {
				Text("Choose your console, then enter the code from **Settings › System › Remote Play › Link Device** on the PS5.")
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if model.registered.isEmpty {
				if model.unpaired.isEmpty {
					HStack(spacing: 10) {
						ProgressView().controlSize(.small)
						Text("Looking for consoles on your network…").foregroundStyle(.secondary)
					}
					.padding(.vertical, 8)
				}
				ForEach(model.unpaired) { host in
					HStack {
						Image("CouchwireMark").resizable().scaledToFit().frame(width: 22, height: 22).foregroundStyle(.tint)
						VStack(alignment: .leading) {
							Text(host.name).font(.headline)
							Text(host.address).font(.caption).foregroundStyle(.secondary)
						}
						Spacer()
						Button("Pair…") { pairing = PairTarget(address: host.address, name: host.name, isPS5: host.isPS5) }
					}
					.padding(10)
					.background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
				}
				Button("Add by IP Address…") { pairing = PairTarget(address: "", name: nil, isPS5: true) }
					.buttonStyle(.link)
			}
		}
	}

	private func instruction(_ n: Int, _ path: String, _ detail: LocalizedStringKey) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Text("\(n)")
				.font(.callout.weight(.semibold))
				.frame(width: 24, height: 24)
				.background(.tint.opacity(0.15), in: Circle())
				.foregroundStyle(.tint)
			VStack(alignment: .leading, spacing: 3) {
				Text(path).font(.callout.weight(.semibold))
				Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
		}
	}
}
