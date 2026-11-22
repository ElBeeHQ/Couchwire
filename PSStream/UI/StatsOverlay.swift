import SwiftUI

/// Compact performance HUD shown over the stream (toggle with ⌥⌘I).
struct StatsOverlay: View {
	let stats: StreamStats.Snapshot

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 6) {
				Circle().fill(latencyColor).frame(width: 8, height: 8)
				Text(ms(stats.observedMs, digits: 1))
					.font(.system(size: 22, weight: .semibold, design: .rounded))
				Text("latency")
					.foregroundStyle(.secondary)
			}
			Text("Network \(ms(stats.rttMs / 2)) + Decode \(ms(stats.decodeAvgMs)) + Display \(ms(stats.displayWaitAvgMs))")
				.foregroundStyle(.secondary)

			Divider().opacity(0.4)

			Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
				row("Stream", "\(stats.resolution) \(stats.codec)")
				row("Frame rate", String(format: "%.1f fps", stats.fps) + (stats.refreshHz > 0 ? String(format: " · %.0f Hz display", stats.refreshHz) : ""))
				row("Bitrate", String(format: "%.1f Mbps", stats.bitrateMbps))
				row("Round trip", ms(stats.rttMs))
				row("Packet loss", String(format: "%.1f%%", stats.packetLoss * 100), warn: stats.packetLoss > 0.01)
				row("Frame jitter", ms(stats.frameJitterMs), warn: stats.frameJitterMs > 8)
				row("Decode max", ms(stats.decodeMaxMs), warn: stats.decodeMaxMs > 16)
				row("Lost frames", "\(stats.framesLost)" + (stats.decodeErrors > 0 ? " · \(stats.decodeErrors) decode errors" : ""),
					warn: stats.framesLost > 0 || stats.decodeErrors > 0)
			}

			Text("Excludes the PS5’s capture and encode time")
				.font(.system(size: 10))
				.foregroundStyle(.tertiary)
		}
		.font(.system(size: 11).monospacedDigit())
		.padding(12)
		.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
		.environment(\.colorScheme, .dark)
		.fixedSize()
		.allowsHitTesting(false)
	}

	private var latencyColor: Color {
		switch stats.observedMs {
		case ..<20: .green
		case ..<35: .yellow
		default: .red
		}
	}

	private func ms(_ v: Double, digits: Int = 1) -> String {
		String(format: "%.\(digits)f ms", v)
	}

	@ViewBuilder
	private func row(_ label: String, _ value: String, warn: Bool = false) -> some View {
		GridRow {
			Text(label).foregroundStyle(.secondary)
			Text(value).foregroundStyle(warn ? .orange : .primary)
		}
	}
}
