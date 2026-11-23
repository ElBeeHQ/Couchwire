import AppKit

/// Couchwire › About Couchwire: the standard panel, credited like ElBeeHQ's other apps. "Made by" with the ElBeeHQ
/// logo, the project's links, Couchwire's licence and where to get its source (the AGPL asks for both), the
/// third-party software it includes, and that it isn't Sony's.
enum AboutPanel {
	static func show() {
		var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits()]
		// The panel prints "Version 1.2 (1.2)" when the build number is the version; Apple's apps show it once.
		let info = Bundle.main.infoDictionary
		if let short = info?["CFBundleShortVersionString"] as? String, short == info?["CFBundleVersion"] as? String {
			options[.applicationVersion] = short
			options[.version] = ""
		}
		NSApp.orderFrontStandardAboutPanel(options: options)
		NSApp.activate()
		DispatchQueue.main.async(execute: tidyLinks)
	}

	private static func credits() -> NSAttributedString {
		let centred = NSMutableParagraphStyle()
		centred.alignment = .center
		centred.paragraphSpacing = 4
		let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
		let text = NSMutableAttributedString()

		func add(_ string: String, font: NSFont = small, colour: NSColor = .labelColor, link: URL? = nil) {
			var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour, .paragraphStyle: centred]
			if let link { attributes[.link] = link }
			text.append(NSAttributedString(string: string, attributes: attributes))
		}
		func links(_ items: [(String, URL?)]) {
			for (index, item) in items.enumerated() {
				if index > 0 { add(" · ", colour: .secondaryLabelColor) }
				add(item.0, link: item.1)
			}
			add("\n")
		}

		madeBy(into: text, centred: centred)
		links([("elbeehq.com", ElBeeLinks.website), ("What’s New", ElBeeLinks.releaseNotes),
			   ("Report a Problem", ElBeeLinks.reportProblem)])
		// Short enough to fit the panel without scrolling; the full third-party list is in Notices.
		add("\nFree software under the GNU AGPL v3.0,\nprovided without warranty.\n", colour: .secondaryLabelColor)
		links([("Licence", licence("Couchwire-Licence")), ("Source Code", ElBeeLinks.source),
			   ("Notices", licence("ThirdPartyNotices")), ("Legal", ElBeeLinks.legal)])
		return text
	}

	/// Links in the credits in the accent colour without underlines, as macOS's own panels show them.
	private static func tidyLinks() {
		for window in NSApp.windows where window.isVisible {
			for view in textViews(in: window.contentView) where view.string.hasPrefix("\nMade by") {
				view.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .cursor: NSCursor.pointingHand]
			}
		}
	}

	private static func textViews(in view: NSView?) -> [NSTextView] {
		guard let view else { return [] }
		return ((view as? NSTextView).map { [$0] } ?? []) + view.subviews.flatMap { textViews(in: $0) }
	}

	/// "Made by" and the ElBeeHQ logo (E1) above the links and licences: the full-colour hive (its open cell follows Light
	/// and Dark) and the drawn "ElBeeHQ" wordmark, "HQ" in amber. The company's logo, never Couchwire's.
	private static func madeBy(into text: NSMutableAttributedString, centred: NSParagraphStyle) {
		let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
		let size: CGFloat = 16
		let hive = NSTextAttachment()
		hive.image = NSImage(named: "ElBeeHQHive")
		hive.image?.accessibilityDescription = ""   // decorative: VoiceOver reads "Made by ElBeeHQ"
		// 22 points, centred on the wordmark's capitals.
		hive.bounds = NSRect(x: 0, y: (ElBeeHQWordmark.capHeight(forSize: size) - 22) / 2, width: 22, height: 22)
		// The drawn wordmark, its Light or Dark colours by appearance, sitting on the baseline with the Q's tail below.
		let wordmark = NSTextAttachment()
		wordmark.image = NSImage(named: "ElBeeHQWordmark")
		wordmark.image?.accessibilityDescription = "ElBeeHQ"
		let height = ElBeeHQWordmark.height(forSize: size)
		wordmark.bounds = NSRect(x: 0, y: -ElBeeHQWordmark.descent(forSize: size), width: height * ElBeeHQWordmark.aspect, height: height)
		// One line, "Made by" then the logo, so the credits still end on a whole line at the panel's size.
		let line = NSMutableAttributedString(string: "Made by\u{2002}", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor])
		line.append(NSAttributedString(attachment: hive))
		line.append(NSAttributedString(string: "\u{2006}"))   // the design's 6-point gap
		line.append(NSAttributedString(attachment: wordmark))
		line.append(NSAttributedString(string: "\n"))
		let spaced = (centred.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
		spaced.paragraphSpacing = 14
		line.addAttribute(.paragraphStyle, value: spaced, range: NSRange(location: 0, length: line.length))
		// The space above is a short empty line: the credits view ignores spacing before its first paragraph.
		let gap = NSMutableParagraphStyle()
		gap.alignment = .center
		text.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8), .paragraphStyle: gap]))
		text.append(line)
	}

	/// The licence texts ship inside the app; a link to one opens it.
	private static func licence(_ file: String) -> URL? {
		Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
			?? Bundle.main.url(forResource: file, withExtension: "txt")
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
