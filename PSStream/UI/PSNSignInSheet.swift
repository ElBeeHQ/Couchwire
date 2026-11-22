import SwiftUI
import WebKit

/// Sheet hosting Sony's own PlayStation Network sign-in page. Credentials are entered
/// directly into Sony's page; PSStream only sees the redirect carrying the OAuth code.
struct PSNSignInSheet: View {
	@Environment(\.dismiss) private var dismiss
	let onAccountID: (String) -> Void

	@State private var phase: Phase = .loading
	@State private var attempt = 0

	enum Phase: Equatable {
		case loading, ready, resolving, failed(String)
	}

	var body: some View {
		VStack(spacing: 0) {
			HStack {
				Label("Sign in to PlayStation Network", systemImage: "lock.fill")
					.font(.headline)
				Spacer()
				if phase == .loading || phase == .resolving {
					ProgressView().controlSize(.small)
				}
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 12)

			Divider()

			ZStack {
				PSNWebView(attempt: attempt,
						   onLoaded: { if phase == .loading { phase = .ready } },
						   onRedirect: handleRedirect(_:),
						   onError: { phase = .failed($0) })
					.id(attempt)
				switch phase {
				case .resolving:
					overlayMessage { ProgressView(); Text("Getting your Account ID…") }
				case .failed(let message):
					overlayMessage {
						Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.orange)
						Text(message).multilineTextAlignment(.center)
						Button("Try Again") { phase = .loading; attempt += 1 }
					}
				default:
					EmptyView()
				}
			}

			Divider()

			HStack {
				Text("Only your Account ID is saved. You stay signed out of PSN in PSStream.")
					.font(.caption)
					.foregroundStyle(.secondary)
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
			}
			.padding(12)
		}
		.frame(width: 520, height: 700)
	}

	private func handleRedirect(_ url: URL) {
		phase = .resolving
		Task {
			do {
				let id = try await PSNAuth.accountID(fromRedirect: url)
				onAccountID(id)
				dismiss()
			} catch {
				phase = .failed(error.localizedDescription)
			}
		}
	}

	@ViewBuilder
	private func overlayMessage<C: View>(@ViewBuilder _ content: () -> C) -> some View {
		VStack(spacing: 12) { content() }
			.padding(24)
			.frame(maxWidth: 360)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(.regularMaterial)
	}
}

private struct PSNWebView: NSViewRepresentable {
	let attempt: Int
	let onLoaded: () -> Void
	let onRedirect: (URL) -> Void
	let onError: (String) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		let web = WKWebView(frame: .zero, configuration: config)
		web.navigationDelegate = context.coordinator
		web.load(URLRequest(url: PSNAuth.authorizeURL))
		return web
	}

	func updateNSView(_ nsView: WKWebView, context: Context) {
		context.coordinator.parent = self
	}

	final class Coordinator: NSObject, WKNavigationDelegate {
		var parent: PSNWebView
		private var handled = false

		init(_ parent: PSNWebView) { self.parent = parent }

		func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
			guard let url = action.request.url, PSNAuth.isRedirect(url) else { return .allow }
			if !handled {
				handled = true
				await MainActor.run { parent.onRedirect(url) }
			}
			return .cancel
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			parent.onLoaded()
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			report(error)
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
			report(error)
		}

		private func report(_ error: Error) {
			// Cancelling the redirect navigation surfaces as a cancellation error; ignore it.
			let ns = error as NSError
			if handled || ns.code == NSURLErrorCancelled || ns.code == 102 /* WebKitErrorFrameLoadInterruptedByPolicyChange */ { return }
			parent.onError(error.localizedDescription)
		}
	}
}
