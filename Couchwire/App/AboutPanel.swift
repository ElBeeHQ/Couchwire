import AppKit
import SwiftUI

/// Couchwire › About Couchwire: a small window credited like ElBeeHQ's other apps. The icon, name and version,
/// "Made by" with the ElBeeHQ logo, the project's links, then Couchwire's licence and where to get its source
/// (the AGPL asks for both), and the third-party software it includes.
enum AboutPanel {
	private static var window: NSWindow?

	static func show() {
		if window == nil {
			let hosting = NSHostingController(rootView: AboutView())
			let w = NSWindow(contentViewController: hosting)
			w.title = "About Couchwire"
			w.styleMask = [.titled, .closable, .fullSizeContentView]
			w.titlebarAppearsTransparent = true
			w.titleVisibility = .hidden
			w.isMovableByWindowBackground = true
			w.isReleasedWhenClosed = false
			w.center()
			window = w
		}
		window?.makeKeyAndOrderFront(nil)
		NSApp.activate()
	}

	/// The licence texts ship inside the app; a link to one opens it.
	static func licence(_ file: String) -> URL? {
		Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
			?? Bundle.main.url(forResource: file, withExtension: "txt")
	}
}

private struct AboutView: View {
	private var version: String {
		Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
	}

	var body: some View {
		VStack(spacing: 0) {
			Image(nsImage: NSApp.applicationIconImage)
				.resizable()
				.frame(width: 88, height: 88)
			Text("Couchwire")
				.font(.title2.weight(.semibold))
				.padding(.top, 10)
			Text("Version \(version)")
				.font(.callout)
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.padding(.top, 2)

			madeBy
				.padding(.top, 22)
			HStack(spacing: 18) {
				Link("Website", destination: ElBeeLinks.website)
				Link("What’s New", destination: ElBeeLinks.releaseNotes)
				Link("Report a Problem", destination: ElBeeLinks.reportProblem)
			}
			.font(.callout)
			.padding(.top, 12)

			VStack(spacing: 4) {
				Text("Free software under the GNU AGPL v3.0, without warranty.")
				HStack(spacing: 4) {
					footLink("Licence", AboutPanel.licence("Couchwire-Licence"))
					Text("·")
					footLink("Source Code", ElBeeLinks.source)
					Text("·")
					footLink("Notices", AboutPanel.licence("ThirdPartyNotices"))
					Text("·")
					footLink("Legal", ElBeeLinks.legal)
				}
				Text("© 2026 ElBeeHQ")
					.padding(.top, 6)
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.top, 26)
		}
		.multilineTextAlignment(.center)
		.padding(.horizontal, 28)
		.padding(.top, 34)
		.padding(.bottom, 22)
		.frame(width: 340)
	}

	/// "Made by" and the ElBeeHQ logo (E1): the full-colour hive (its open cell follows Light and Dark) and the
	/// drawn "ElBeeHQ" wordmark, "HQ" in amber. The company's logo, never Couchwire's.
	private var madeBy: some View {
		let size: CGFloat = 15
		let height = ElBeeHQWordmark.height(forSize: size)
		return HStack(spacing: 6) {
			Text("Made by")
				.font(.callout)
				.foregroundStyle(.secondary)
				.padding(.trailing, 2)
			Image("ElBeeHQHive")
				.resizable()
				.frame(width: 20, height: 20)
				.accessibilityHidden(true)
			Image("ElBeeHQWordmark")
				.resizable()
				.frame(width: height * ElBeeHQWordmark.aspect, height: height)
				// Sit the capitals on the line, with the Q's tail below.
				.offset(y: ElBeeHQWordmark.descent(forSize: size) / 2)
				.accessibilityLabel("ElBeeHQ")
		}
		.accessibilityElement(children: .combine)
	}

	@ViewBuilder
	private func footLink(_ title: String, _ url: URL?) -> some View {
		if let url { Link(title, destination: url) } else { Text(title) }
	}
}

/// The ElBeeHQ company logo's drawn "ElBeeHQ" wordmark (Nunito 900 outlines, shared with ElBeeHQ's other apps).
enum ElBeeHQWordmark {
	/// The drawing's height for a given type size: from the caps' top to the Q's tail, 925 of 1000 units.
	static func height(forSize size: CGFloat) -> CGFloat { size * 0.925 }
	/// Width over height of the drawing.
	static let aspect: CGFloat = 4120.0 / 925.0
	/// How far the Q's tail goes below the baseline, for a given type size (209 of 1000 units).
	static func descent(forSize size: CGFloat) -> CGFloat { size * 0.209 }
	/// The caps' height for a given type size (705 of 1000 units).
	static func capHeight(forSize size: CGFloat) -> CGFloat { size * 0.705 }
}

/// ElBeeHQ's addresses for Couchwire, in one place.
enum ElBeeLinks {
	static let website = URL(string: "https://elbeehq.com")!
	static let releaseNotes = URL(string: "https://github.com/ElBeeHQ/Couchwire/blob/main/CHANGELOG.md")!
	static let reportProblem = URL(string: "https://github.com/ElBeeHQ/Couchwire/issues")!
	static let source = URL(string: "https://github.com/ElBeeHQ/Couchwire")!
	static let legal = URL(string: "https://elbeehq.com/legal.html")!
}
