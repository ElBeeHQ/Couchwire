import SwiftUI

/// Performance HUD shown over the stream (toggle with ⌥⌘I): a measured button-to-photon
/// number, its parts, and a frame-pacing graph.
struct StatsOverlay: View {
	let stats: StreamStats.Snapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Circle().fill(latencyColor).frame(width: 8, height: 8)
				Text(ms(stats.observedMs, digits: 1))
					.font(.system(size: 22, weight: .semibold, design: .rounded))
				Text("button to screen")
					.foregroundStyle(.secondary)
			}
			Text("Input \(ms(stats.inputAvgMs)) + Network \(ms(stats.networkRttMs)) + Decode \(ms(stats.decodeAvgMs)) + Display \(ms(stats.displayWaitAvgMs))")
				.foregroundStyle(.secondary)

			Divider().opacity(0.4)

			Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
				row("Stream", "\(stats.resolution) \(stats.codec)")
				row("Frame rate", String(format: "%.1f fps", stats.fps) + (stats.refreshHz > 0 ? String(format: " · %.0f Hz display", stats.refreshHz) : ""))
				row("Bitrate", String(format: "%.1f Mbps", stats.bitrateMbps))
				row("Controller", stats.inputRateHz > 0
					? "\(ms(stats.inputAvgMs)) avg · \(ms(stats.inputMaxMs)) max · \(Int(stats.inputRateHz.rounded())) Hz"
					: "\(ms(stats.inputAvgMs)) avg · \(ms(stats.inputMaxMs)) max",
					warn: stats.inputMaxMs > 8)
				if let ping = stats.pingMs {
					row("Round trip", "\(ms(ping)) live · \(ms(stats.pingJitterMs)) jitter" + (stats.pingLost > 0 ? " · \(stats.pingLost) lost" : ""),
						warn: stats.pingJitterMs > 3)
				} else {
					row("Round trip", "\(ms(stats.rttMs)) at start")
				}
				row("Packet loss", String(format: "%.1f%%", stats.packetLoss * 100), warn: stats.packetLoss > 0.01)
				row("Frame jitter", ms(stats.frameJitterMs), warn: stats.frameJitterMs > 8)
				row("Decode max", ms(stats.decodeMaxMs), warn: stats.decodeMaxMs > 16)
				row("Lost frames", "\(stats.framesLost)" + (stats.decodeErrors > 0 ? " · \(stats.decodeErrors) decode errors" : ""),
					warn: stats.framesLost > 0 || stats.decodeErrors > 0)
			}

			if stats.history.count > 2 {
				Divider().opacity(0.4)
				FramePacingGraph(history: stats.history, targetMs: stats.fps > 1 ? 1000 / stats.fps.rounded() : 1000 / 60)
					.frame(height: 64)
				HStack(spacing: 10) {
					legend(.white.opacity(0.75), "Frame interval")
					legend(.cyan, "Decode")
					legend(.green.opacity(0.7), "Target")
				}
				.font(.system(size: 10))
				.foregroundStyle(.secondary)
			}

			Text("Excludes the PS5’s game and encode time, which no client can measure")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
		}
		.font(.system(size: 11).monospacedDigit())
		.padding(12)
		.frame(width: 340, alignment: .leading)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.environment(\.colorScheme, .dark)
		.allowsHitTesting(false)
	}

	private var latencyColor: Color {
		switch stats.observedMs {
		case ..<25: .green
		case ..<40: .yellow
		default: .red
		}
	}

	private func ms(_ v: Double, digits: Int = 1) -> String {
		String(format: "%.\(digits)f ms", v)
	}

	private func legend(_ color: Color, _ label: String) -> some View {
		HStack(spacing: 4) {
			RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 8, height: 3)
			Text(label)
		}
	}

	@ViewBuilder
	private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
		GridRow {
			Text(label).foregroundStyle(.secondary)
			Text(value).foregroundStyle(warn ? .orange : .primary)
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
