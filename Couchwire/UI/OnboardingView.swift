import SwiftUI

/// First-run setup: what Couchwire needs, switching on Remote Play on the PS5, signing in to
/// get the Account ID, then pairing. Shown over the console list until a console is paired;
/// reopen it from Help › Set Up Couchwire….
struct OnboardingView: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@Environment(\.openURL) private var openURL
	@AppStorage("onboardingComplete") private var complete = false
	@State private var step = Step.welcome
	@State private var signingIn = false
	@State private var manualID = ""
	@State private var pairing: PairTarget?
	@State private var searchingTooLong = false

	enum Step: Int, CaseIterable {
		case welcome, remotePlay, signIn, pair
		var title: String {
			switch self {
			case .welcome: "Welcome to Couchwire"
			case .remotePlay: "Get Your PS5 Ready"
			case .signIn: "Connect Your PlayStation Account"
			case .pair: "Pair Your PS5"
			}
		}
	}

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			ScrollView {
				Group {
					switch step {
					case .welcome: welcome
					case .remotePlay: remotePlay
					case .signIn: signIn
					case .pair: pair
					}
				}
				.frame(maxWidth: .infinity, alignment: .topLeading)
				.padding(28)
			}
			Divider()
			footer
		}
		.frame(width: 580, height: 540)
		.sheet(isPresented: $signingIn) {
			PSNSignInSheet { id in
				model.accountID = id
				// Signed in: nothing else to do on this step.
				if step == .signIn {
					Task { try? await Task.sleep(for: .seconds(1.2)); if step == .signIn { step = .pair } }
				}
			}
		}
		.sheet(item: $pairing) { PairingSheet(target: $0) }
		.onAppear { model.startDiscovery() }
		.task(id: step) {
			// Only offer troubleshooting once discovery has had a fair chance.
			searchingTooLong = false
			guard step == .pair else { return }
			try? await Task.sleep(for: .seconds(10))
			searchingTooLong = true
		}
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
			if step == .welcome {
				Button("Set Up Later") { finish() }
			} else {
				Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
			}
			Spacer()
			switch step {
			case .welcome:
				Button("Get Started") { step = .remotePlay }.keyboardShortcut(.defaultAction)
			case .remotePlay:
				Button("I’ve Done This") { step = .signIn }.keyboardShortcut(.defaultAction)
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

	private var welcome: some View {
		VStack(alignment: .leading, spacing: 20) {
			Text("Couchwire streams your PS5 to this Mac, so you can play your games here with a DualSense or other controller. Setup takes about two minutes and you only do it once.")
				.fixedSize(horizontal: false, vertical: true)
			Text("You’ll need").font(.headline)
			VStack(alignment: .leading, spacing: 14) {
				need("playstation.logo", "Your PS5, switched on", "You’ll change two settings on it and read a code from the TV.")
				need("person.crop.circle", "Your PlayStation Network sign-in", "The same account you use on the PS5.")
				need("wifi", "The same network", "Your Mac and PS5 on the same home network. A wired connection on both gives the smoothest picture.")
				need("gamecontroller", "A controller", "Connect a DualSense to your Mac with a USB cable or Bluetooth. You can do this later.")
			}
		}
	}

	private var remotePlay: some View {
		VStack(alignment: .leading, spacing: 18) {
			Text("Remote Play is off on a new PS5. Use your controller on the PS5 to change these settings.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			instruction(1, "Settings › System › Remote Play",
						"Turn on **Enable Remote Play**. This lets the PS5 accept streams from other devices.")
			instruction(2, "Settings › System › Power Saving › Features Available in Rest Mode",
						"Turn on **Stay Connected to the Internet** and **Enable Turning On PS5 from Network**. Then Couchwire can wake the PS5 from rest mode, so you don’t have to walk over to it.")
			instruction(3, "Leave the PS5 on",
						"Keep it on the home screen for the next steps; you’ll need it to show a pairing code.")
		}
	}

	private var signIn: some View {
		VStack(alignment: .leading, spacing: 18) {
			if model.accountID.isEmpty {
				Text("The PS5 only streams to devices linked to one of its accounts. Sign in with the PlayStation Network account you use on your PS5, and Couchwire will fetch your account’s ID for linking.")
					.fixedSize(horizontal: false, vertical: true)
				Button {
					signingIn = true
				} label: {
					Label("Sign In with PlayStation Network…", systemImage: "person.crop.circle")
						.frame(maxWidth: .infinity)
				}
				.buttonStyle(.borderedProminent)
				.controlSize(.large)
				VStack(alignment: .leading, spacing: 8) {
					reassurance("lock.fill", "You sign in on Sony’s own page. Couchwire never sees or stores your password.")
					reassurance("person.text.rectangle", "Only your Account ID is saved: a number that identifies your account for Remote Play.")
					reassurance("rectangle.portrait.and.arrow.right", "You’re signed out again straight away. Couchwire doesn’t keep a PSN session.")
				}
				DisclosureGroup("Having trouble signing in?") {
					VStack(alignment: .leading, spacing: 8) {
						Text("If you already know your Account ID (for example from another Remote Play app), paste it here instead.")
							.font(.callout).foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
						HStack {
							TextField("Account ID", text: $manualID, prompt: Text("12 characters ending in =, e.g. AbCdEfGhIjk="))
								.textFieldStyle(.roundedBorder)
								.font(.body.monospaced())
							Button("Use") { model.accountID = manualID.trimmingCharacters(in: .whitespaces) }
								.disabled(Data(base64Encoded: manualID.trimmingCharacters(in: .whitespaces))?.count != 8)
						}
					}
					.padding(.top, 6)
				}
			} else {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text("Your account is connected").font(.headline)
						Text("Account ID \(model.accountID)").font(.callout.monospaced()).foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
				}
				Text("Click Continue to pair your PS5.").foregroundStyle(.secondary)
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
						Text("You’re all set. Click Done, then Play on your PS5’s card to start streaming.").foregroundStyle(.secondary)
					}
				} icon: {
					Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
				}
			} else {
				Text("Pairing links this Mac to your PS5, once. Choose your PS5 below, then type in the code it shows.")
					.fixedSize(horizontal: false, vertical: true)
				if model.unpaired.isEmpty {
					HStack(spacing: 10) {
						ProgressView().controlSize(.small)
						Text("Looking for your PS5 on this network…").foregroundStyle(.secondary)
					}
					.padding(.vertical, 8)
					if searchingTooLong { notFoundHelp }
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
							.buttonStyle(.borderedProminent)
					}
					.padding(10)
					.background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
				}
				Button("Add by IP Address…") { pairing = PairTarget(address: "", name: nil, isPS5: true) }
					.buttonStyle(.link)
			}
		}
	}

	private var notFoundHelp: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Can’t find your PS5?").font(.headline)
			bullet("Check the PS5 is switched on (not in rest mode) and showing its home screen.")
			bullet("Check your Mac and PS5 are on the same network. Guest Wi-Fi networks often keep devices apart.")
			bullet("Allow Couchwire to find devices on your network: System Settings › Privacy & Security › Local Network.")
			HStack {
				Button("Open Local Network Settings") {
					openURL(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
				}
				Text("or use Add by IP Address, with the address from the PS5’s Settings › Network › Connection Status.")
					.font(.caption).foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
	}

	// MARK: Pieces

	private func need(_ symbol: String, _ title: String, _ detail: String) -> some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: symbol)
				.font(.title3)
				.foregroundStyle(.tint)
				.frame(width: 28)
			VStack(alignment: .leading, spacing: 2) {
				Text(title).font(.callout.weight(.semibold))
				Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private func reassurance(_ symbol: String, _ text: String) -> some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
			Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
		}
	}

	private func bullet(_ text: String) -> some View {
		HStack(alignment: .top, spacing: 8) {
			Text("•").foregroundStyle(.secondary)
			Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
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
