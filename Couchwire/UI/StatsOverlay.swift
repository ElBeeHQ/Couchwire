import SwiftUI

/// Performance panel shown over the stream (⌥⌘I). Leads with one measured button-to-screen
/// figure and a bar showing where that time goes, then explains each number in plain words.
struct StatsOverlay: View {
	let stats: StreamStats.Snapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			headline
			breakdown
			section("Connection") {
				item("Round trip", roundTrip, "Time for a message to reach the PS5 and come back. Under 10 ms is excellent.",
					 warn: stats.networkRttMs > 20)
				item("Jitter", stats.pingMs == nil ? "—" : ms(stats.pingJitterMs),
					 "How much the round trip varies. Low jitter means smooth, steady play.", warn: stats.pingJitterMs > 3)
				item("Packet loss", String(format: "%.1f%%", stats.packetLoss * 100),
					 "Data that never arrived. Anything above 0 can cause stutters or blocky frames.", warn: stats.packetLoss > 0.01)
				item("Bitrate", String(format: "%.1f Mbps", stats.bitrateMbps),
					 "How much video the PS5 is sending. It rises in busy, detailed scenes.")
			}
			section("Video") {
				item("Stream", "\(stats.resolution) \(stats.codec)" + (stats.dynamicRange == "SDR" || stats.dynamicRange.isEmpty ? "" : " · \(stats.dynamicRange)"),
					 String(format: "%.0f fps on a %.0f Hz display.", stats.fps, stats.refreshHz))
				item("Decode", "\(ms(stats.decodeAvgMs)) · \(ms(stats.decodeMaxMs)) worst",
					 "Time your Mac takes to unpack each frame.", warn: stats.decodeMaxMs > 16)
				item("Lost frames", "\(stats.framesLost)" + (stats.decodeErrors > 0 ? " · \(stats.decodeErrors) errors" : ""),
					 "Frames that were dropped on the way. An occasional one is normal on Wi-Fi.",
					 warn: stats.framesLost > 0 || stats.decodeErrors > 0)
			}
			if stats.history.count > 2 {
				section("Frame pacing") {
					FramePacingGraph(history: stats.history, targetMs: targetMs)
						.frame(height: 56)
					HStack(spacing: 12) {
						legend(.white.opacity(0.75), "Time between frames")
						legend(.cyan, "Decode")
						legend(.green.opacity(0.7), "Target")
					}
					.font(.system(size: 10.5))
					.foregroundStyle(.secondary)
					Text("A flat white line on the green target is perfectly smooth. Spikes are frames that arrived late.")
						.font(.system(size: 11))
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Text("Couchwire can’t see the time the PS5 spends running the game and encoding video, so the real total is a little higher.")
				.font(.system(size: 10.5))
				.foregroundStyle(.tertiary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.font(.system(size: 12).monospacedDigit())
		.padding(16)
		.frame(width: 360, alignment: .leading)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
		.shadow(color: .black.opacity(0.35), radius: 14, y: 5)
		.environment(\.colorScheme, .dark)
		.allowsHitTesting(false)
	}

	// MARK: Headline

	private var headline: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Text(ms(stats.observedMs))
					.font(.system(size: 30, weight: .semibold, design: .rounded))
				Text(rating.label)
					.font(.system(size: 12, weight: .semibold))
					.padding(.horizontal, 8)
					.padding(.vertical, 3)
					.background(rating.color.opacity(0.22), in: Capsule())
					.foregroundStyle(rating.color)
			}
			Text("From pressing a button to seeing it on screen")
				.foregroundStyle(.secondary)
		}
	}

	private var rating: (label: String, color: Color) {
		switch stats.observedMs {
		case ..<20: ("Excellent", .green)
		case ..<35: ("Good", .yellow)
		default: ("Noticeable", .orange)
		}
	}

	// MARK: Where the time goes

	private var parts: [(String, Double, Color, String)] {
		[
			("Controller", stats.controllerMs, .purple, rateNote),
			("Network", stats.networkRttMs, .blue, "There and back over your network"),
			("Decode", stats.decodeAvgMs, .cyan, "Your Mac unpacking the frame"),
			("Display", stats.displayWaitAvgMs, .green, "Waiting for the screen’s next refresh"),
		]
	}

	private var rateNote: String {
		stats.inputRateHz > 0 ? "Reports \(Int(stats.inputRateHz.rounded())) times a second" : "Waiting for the controller"
	}

	private var breakdown: some View {
		VStack(alignment: .leading, spacing: 8) {
			GeometryReader { geo in
				let total = max(parts.reduce(0) { $0 + $1.1 }, 0.001)
				HStack(spacing: 2) {
					ForEach(parts, id: \.0) { part in
						RoundedRectangle(cornerRadius: 3)
							.fill(part.2)
							.frame(width: max(3, (geo.size.width - 6) * part.1 / total))
					}
				}
			}
			.frame(height: 8)
			Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
				ForEach(parts, id: \.0) { part in
					GridRow {
						Circle().fill(part.2).frame(width: 7, height: 7)
						Text(part.0)
						Text(ms(part.1)).gridColumnAlignment(.trailing)
						Text(part.3).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
					}
				}
			}
		}
	}

	// MARK: Building blocks

	private var roundTrip: String {
		if let ping = stats.pingMs {
			return ms(ping) + (stats.pingLost > 0 ? " · \(stats.pingLost) lost" : "")
		}
		return ms(stats.rttMs) + " (at start)"
	}

	private var targetMs: Double { stats.fps > 1 ? 1000 / stats.fps.rounded() : 1000 / 60 }

	private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title.uppercased())
				.font(.system(size: 10.5, weight: .semibold))
				.tracking(0.6)
				.foregroundStyle(.secondary)
			content()
		}
		.padding(.top, 2)
	}

	private func item(_ label: String, _ value: String, _ note: String, warn: Bool = false) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(label).fontWeight(.medium)
				Spacer()
				Text(value).foregroundStyle(warn ? .orange : .primary)
			}
			Text(note)
				.font(.system(size: 11))
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private func ms(_ v: Double) -> String {
		String(format: "%.1f ms", v)
	}

	private func legend(_ color: Color, _ label: String) -> some View {
		HStack(spacing: 4) {
			RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 10, height: 3)
			Text(label)
		}
	}
}

/// The last few seconds of frames, oldest on the left. Spikes above the target line are
/// frames that arrived late; even spacing at the target is smooth pacing.
private struct FramePacingGraph: View {
	let history: [StreamStats.FrameSample]
	let targetMs: Double

	var body: some View {
		Canvas { ctx, size in
			// Scale to 3× the target so a dropped frame (2×) is clearly visible.
			let top = max(targetMs * 3, 1)
			func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(v, top) / top) * size.height }
			let step = size.width / CGFloat(max(StreamStats.historyLength - 1, 1))
			let x0 = size.width - CGFloat(history.count - 1) * step

			var target = Path()
			target.move(to: CGPoint(x: 0, y: y(targetMs)))
			target.addLine(to: CGPoint(x: size.width, y: y(targetMs)))
			ctx.stroke(target, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

			for (i, s) in history.enumerated() where s.intervalMs > targetMs * 1.5 {
				let x = x0 + CGFloat(i) * step
				ctx.fill(Path(CGRect(x: x - 1, y: y(s.intervalMs), width: 2, height: size.height - y(s.intervalMs))),
						 with: .color(.orange.opacity(0.5)))
			}

			var interval = Path(), decode = Path()
			for (i, s) in history.enumerated() {
				let x = x0 + CGFloat(i) * step
				let pi = CGPoint(x: x, y: y(s.intervalMs)), pd = CGPoint(x: x, y: y(s.decodeMs))
				if i == 0 { interval.move(to: pi); decode.move(to: pd) } else { interval.addLine(to: pi); decode.addLine(to: pd) }
			}
			ctx.stroke(interval, with: .color(.white.opacity(0.75)), lineWidth: 1)
			ctx.stroke(decode, with: .color(.cyan), lineWidth: 1)
		}
		.background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
	}
}
