import SwiftUI

struct PairingSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State var target: PairTarget
	@State private var pin = ""
	@State private var working = false
	@State private var error: String?
	@State private var signingIn = false

	var body: some View {
		@Bindable var model = model
		VStack(alignment: .leading, spacing: 16) {
			Text(target.name.map { "Pair with \($0)" } ?? "Pair with a Console")
				.font(.title2.weight(.semibold))
			VStack(alignment: .leading, spacing: 6) {
				step(1, "On your PS5, go to **Settings › System › Remote Play** and choose **Link Device**.")
				step(2, "The TV shows an 8-digit code. Type it below and click Pair.")
			}
			Text("If the code disappears before you finish, choose Link Device again for a new one.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Form {
				if target.name == nil {
					TextField("PS5 IP Address", text: $target.address, prompt: Text("e.g. 192.168.1.20"))
				}
				LabeledContent("PSN Account") {
					HStack {
						if model.accountID.isEmpty {
							Text("Not signed in").foregroundStyle(.secondary)
						} else {
							Label(model.accountID, systemImage: "checkmark.circle.fill")
								.labelStyle(AccountLabelStyle())
						}
						Button(model.accountID.isEmpty ? "Sign In…" : "Change…") { signingIn = true }
					}
				}
				TextField("Code from TV", text: $pin, prompt: Text("8 digits"))
					.font(.body.monospacedDigit())
			}
			.formStyle(.grouped)
			.disabled(working)

			if let error {
				Label(error, systemImage: "exclamationmark.triangle.fill")
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button {
					pair()
				} label: {
					if working { ProgressView().controlSize(.small) } else { Text("Pair") }
				}
				.keyboardShortcut(.defaultAction)
				.disabled(working || target.address.isEmpty || pin.filter(\.isNumber).count != 8 || model.accountID.isEmpty)
			}
		}
		.padding(24)
		.frame(width: 440)
		.sheet(isPresented: $signingIn) {
			PSNSignInSheet { model.accountID = $0 }
		}
	}

	private func pair() {
		working = true
		error = nil
		Task {
			do {
				try await model.pair(address: target.address, isPS5: target.isPS5, pin: pin)
				dismiss()
			} catch {
				self.error = error.localizedDescription
			}
			working = false
		}
	}
}

private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
	HStack(alignment: .top, spacing: 8) {
		Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
		Text(text).fixedSize(horizontal: false, vertical: true)
	}
}

private struct AccountLabelStyle: LabelStyle {
	func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: 4) {
			configuration.icon.foregroundStyle(.green)
			configuration.title.font(.body.monospaced()).foregroundStyle(.secondary)
		}
	}
}
