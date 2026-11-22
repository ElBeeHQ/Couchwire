import SwiftUI

struct PairingSheet: View {
	@Environment(AppModel.self) private var model
	@Environment(\.dismiss) private var dismiss
	@State var target: PairTarget
	@State private var pin = ""
	@State private var working = false
	@State private var error: String?

	var body: some View {
		@Bindable var model = model
		VStack(alignment: .leading, spacing: 16) {
			Text(target.name.map { "Pair with \($0)" } ?? "Pair with a Console")
				.font(.title2.weight(.semibold))
			Text("On your PS5, go to Settings › System › Remote Play › Link Device, then enter the code shown on screen.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			Form {
				if target.name == nil {
					TextField("IP Address", text: $target.address, prompt: Text("192.168.1.20"))
				}
				TextField("PSN Account ID", text: $model.accountID, prompt: Text("Base64, e.g. AbCdEfGhIjk="))
					.help("Your PSN account ID, Base64-encoded. This is not your sign-in ID or email.")
				TextField("Code", text: $pin, prompt: Text("8 digits"))
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
