import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import VideoToolbox
import os

/// Decodes libchiaki's Annex-B access units with a hardware `VTDecompressionSession` and
/// hands each decoded frame straight to an `AVSampleBufferDisplayLayer` flagged
/// DisplayImmediately, so it is composited on the very next refresh.
///
/// Decoding ourselves (rather than giving the layer compressed samples) lets us time every
/// frame precisely and run the decoder in real-time mode.
final class VideoDecoder: @unchecked Sendable {
	enum Codec { case h264, hevc }

	private let codec: Codec
	/// Ask the decoder for 10-bit frames so HDR keeps its full range.
	private let hdr: Bool
	private let renderer: AVSampleBufferVideoRenderer
	private let stats: StreamStats
	private var formatDescription: CMVideoFormatDescription?
	private var session: VTDecompressionSession?
	private var parameterSets: [UInt8: Data] = [:] // keyed by NAL type
	private var waitingForKeyframe = true
	private let log = Logger(subsystem: "Couchwire", category: "Video")
	/// Whether the first frame after a format change has been checked for HDR, for the log.
	private var checkedFrame = false
	/// Called when the decoder needs a fresh keyframe (e.g. after a decode failure).
	var requestKeyframe: (() -> Void)?
	/// When set, frames are timed to play out evenly instead of shown the moment they decode.
	/// Needs the display layer's control timebase to run on the host clock.
	private let pacer: FramePacer?

	init(codec: Codec, hdr: Bool = false, renderer: AVSampleBufferVideoRenderer, stats: StreamStats, pacer: FramePacer? = nil) {
		self.codec = codec
		self.hdr = hdr
		self.renderer = renderer
		self.stats = stats
		self.pacer = pacer
	}

	deinit {
		if let session { VTDecompressionSessionInvalidate(session) }
	}

	/// Called on libchiaki's receive thread. Returns false to signal a corrupt frame.
	func decode(_ data: UnsafeBufferPointer<UInt8>) -> Bool {
		if renderer.status == .failed {
			log.error("Renderer failed: \(String(describing: self.renderer.error)); flushing")
			renderer.flush()
			return recover()
		}

		var payload = Data()
		var sawParameterSet = false
		var isKeyframe = false

		for nalu in Self.splitAnnexB(data) where !nalu.isEmpty {
			let type = nalType(nalu.first!)
			switch (codec, type) {
			case (.h264, 7), (.h264, 8), (.hevc, 32), (.hevc, 33), (.hevc, 34):
				if parameterSets[type] != nalu {
					parameterSets[type] = nalu
					sawParameterSet = true
				}
			default:
				if (codec == .h264 && type == 5) || (codec == .hevc && (16...21).contains(type)) {
					isKeyframe = true
				}
				// AVCC/HVCC framing: 4-byte big-endian length prefix.
				var len = UInt32(nalu.count).bigEndian
				payload.append(Data(bytes: &len, count: 4))
				payload.append(nalu)
			}
		}

		if sawParameterSet || formatDescription == nil {
			if let desc = makeFormatDescription() {
				let changed = formatDescription.map { !CMFormatDescriptionEqual($0, otherFormatDescription: desc) } ?? true
				formatDescription = desc
				if changed || session == nil { makeSession(desc) }
			}
		}
		guard let formatDescription, let session, !payload.isEmpty else { return true }
		if waitingForKeyframe {
			guard isKeyframe else { return true }
			waitingForKeyframe = false
		}

		guard let sample = makeSampleBuffer(payload, format: formatDescription) else { return false }

		let submitted = CACurrentMediaTime()
		let status = VTDecompressionSessionDecodeFrame(
			session, sampleBuffer: sample,
			flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
			infoFlagsOut: nil
		) { [weak self] status, _, imageBuffer, pts, _ in
			self?.didDecode(status: status, imageBuffer: imageBuffer, pts: pts, submitted: submitted)
		}
		if status != noErr {
			log.error("DecodeFrame failed: \(status)")
			stats.decodeFailed()
			if status == kVTInvalidSessionErr { self.session = nil }
			return recover()
		}
		return true
	}

	func reset() {
		renderer.flush()
		if let session { VTDecompressionSessionInvalidate(session) }
		session = nil
		formatDescription = nil
		parameterSets.removeAll()
		waitingForKeyframe = true
	}

	// MARK: - Decode output (VideoToolbox thread)

	private func didDecode(status: OSStatus, imageBuffer: CVImageBuffer?, pts: CMTime, submitted: CFTimeInterval) {
		let decodedAt = CACurrentMediaTime()
		guard status == noErr, let imageBuffer else {
			if status != noErr {
				log.error("Decode error: \(status)")
				stats.decodeFailed()
				requestKeyframe?()
			}
			return
		}
		stats.frameDecoded(submittedAt: submitted, decodedAt: decodedAt)
		if !checkedFrame {
			checkedFrame = true
			logFrame(imageBuffer)
		}

		var format: CMVideoFormatDescription?
		guard CMVideoFormatDescriptionCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &format) == noErr,
			let format else { return }
		var showAt = pts
		if let pacer {
			let at = pacer.schedule(decodedAt: decodedAt)
			stats.frameScheduled(leadMs: (at - decodedAt) * 1000)
			stats.frameShown(at: at)
			showAt = CMTime(seconds: at, preferredTimescale: 1_000_000_000)
		} else {
			stats.frameShown(at: decodedAt)
		}
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: showAt, decodeTimeStamp: .invalid)
		var sample: CMSampleBuffer?
		guard CMSampleBufferCreateReadyWithImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: format,
			sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
		if pacer == nil { Self.markDisplayImmediately(sample) }
		renderer.enqueue(sample)
	}

	// MARK: - Private

	private func recover() -> Bool {
		waitingForKeyframe = true
		requestKeyframe?()
		return false
	}

	private func makeSession(_ desc: CMVideoFormatDescription) {
		if let session {
			VTDecompressionSessionWaitForAsynchronousFrames(session)
			VTDecompressionSessionInvalidate(session)
		}
		session = nil

		let dims = CMVideoFormatDescriptionGetDimensions(desc)
		stats.setResolution(width: dims.width, height: dims.height)
		let transfer = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? "unspecified"
		let primaries = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String ?? "unspecified"
		let isHDR = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
			|| transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
		stats.setDynamicRange(isHDR ? (transfer.contains("2084") ? "HDR10" : "HLG") : "SDR")
		log.notice("Video format: \(dims.width)x\(dims.height), \(isHDR ? "HDR" : "SDR", privacy: .public) (transfer \(transfer, privacy: .public), primaries \(primaries, privacy: .public)), asked for HDR: \(self.hdr)")
		checkedFrame = false

		let spec: [CFString: Any] = [
			kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
		]
		let attrs: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
			kCVPixelBufferMetalCompatibilityKey: true,
		]
		var newSession: VTDecompressionSession?
		let status = VTDecompressionSessionCreate(
			allocator: kCFAllocatorDefault, formatDescription: desc,
			decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary,
			outputCallback: nil, decompressionSessionOut: &newSession)
		guard status == noErr, let newSession else {
			log.error("VTDecompressionSessionCreate failed: \(status)")
			return
		}
		VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_MaximizePowerEfficiency, value: kCFBooleanFalse)
		session = newSession
		waitingForKeyframe = true
	}

	/// What reaches the screen: the decoded frame's bit depth and colour tags, and how much HDR headroom the
	/// stream window's display has (1 means none: HDR shows as SDR).
	private func logFrame(_ buffer: CVImageBuffer) {
		let format = CVPixelBufferGetPixelFormatType(buffer)
		let bits = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? "10-bit" : format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "8-bit" : "format \(format)"
		let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String ?? "untagged"
		let log = log
		DispatchQueue.main.async {
			let screen = NSApp.windows.first { $0.title == "Remote Play" && $0.isVisible }?.screen ?? NSScreen.main
			let potential = screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
			let now = screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1
			log.notice("First frame: \(bits, privacy: .public), transfer \(transfer, privacy: .public); display \(screen?.localizedName ?? "unknown", privacy: .public) HDR headroom \(potential, format: .fixed(precision: 1))x, now \(now, format: .fixed(precision: 1))x")
		}
	}

	private func nalType(_ header: UInt8) -> UInt8 {
		codec == .h264 ? header & 0x1F : (header >> 1) & 0x3F
	}

	private func makeFormatDescription() -> CMVideoFormatDescription? {
		let required: [UInt8] = codec == .h264 ? [7, 8] : [32, 33, 34]
		let sets = required.compactMap { parameterSets[$0] }
		guard sets.count == required.count else { return nil }

		var desc: CMVideoFormatDescription?
		let status: OSStatus = withPointers(sets) { pointers, sizes in
			if codec == .h264 {
				return CMVideoFormatDescriptionCreateFromH264ParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
			} else {
				return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
					allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
					parameterSetPointers: pointers, parameterSetSizes: sizes,
					nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
			}
		}
		if status != noErr {
			log.error("Failed to create format description: \(status)")
			return nil
		}
		return desc
	}

	private func makeSampleBuffer(_ payload: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
		var block: CMBlockBuffer?
		let length = payload.count
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
			blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
			dataLength: length, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
		let copied = payload.withUnsafeBytes { raw in
			CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
		}
		guard copied == noErr else { return nil }

		var sample: CMSampleBuffer?
		var sampleSize = length
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
		guard CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
			sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
			let sample else { return nil }
		return sample
	}

	/// Present as soon as possible: we are a live stream and never buffer.
	private static func markDisplayImmediately(_ sample: CMSampleBuffer) {
		guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
			  CFArrayGetCount(attachments) > 0 else { return }
		let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
		CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
							 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
	}

	/// Splits an Annex-B byte stream on 3- or 4-byte start codes.
	static func splitAnnexB(_ buf: UnsafeBufferPointer<UInt8>) -> [Data] {
		var result: [Data] = []
		let n = buf.count
		var i = 0
		var start = -1
		while i + 2 < n {
			if buf[i] == 0, buf[i + 1] == 0, buf[i + 2] == 1 {
				if start >= 0 {
					var end = i
					if end > start, buf[end - 1] == 0 { end -= 1 } // 4-byte start code
					result.append(Data(buf[start..<end]))
				}
				i += 3
				start = i
			} else {
				i += 1
			}
		}
		if start >= 0, start < n {
			result.append(Data(buf[start..<n]))
		}
		return result
	}
}

private func withPointers<R>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
	let sizes = sets.map(\.count)
	let buffers = sets.map { data -> UnsafeMutablePointer<UInt8> in
		let p = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
		data.copyBytes(to: p, count: data.count)
		return p
	}
	defer { buffers.forEach { $0.deallocate() } }
	let pointers = buffers.map { UnsafePointer($0) }
	return pointers.withUnsafeBufferPointer { pp in
		sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
	}
}

/// Smoothing: evens out frames that arrive bunched up or late by holding each one back a little,
/// just long enough to cover the network's recent unevenness (at most 50 ms). Unevenness under 6 ms
/// is ignored, so on a steady network the hold is zero and it costs no delay there.
/// How hard smoothing works: a trade between steady motion and a quick response.
enum SmoothingMode: String, CaseIterable, Identifiable, Sendable {
	/// Balanced, stepping up to Steadiest on a mobile hotspot only while it shows the long gaps that need it.
	case automatic
	/// Show each frame the moment it's decoded.
	case off
	/// Cover all but the rarest late frames, for little added delay.
	case balanced
	/// Cover even the rare long gaps of mobile networks, at the cost of more delay.
	case steadiest

	var id: String { rawValue }
	var name: String {
		switch self {
		case .automatic: "Automatic"
		case .off: "Off"
		case .balanced: "Balanced"
		case .steadiest: "Steadiest"
		}
	}

	/// The mode to use on `link`. On a mobile hotspot Automatic stays Automatic: the pacer decides as it goes.
	func resolved(for link: ConnectionQuality.Link) -> SmoothingMode {
		guard self == .automatic else { return self }
		return link == .internetMobile ? .automatic : .balanced
	}
}

final class FramePacer: @unchecked Sendable {
	/// The longest a frame is held, for each kind of link. Mobile networks deliver in bigger bursts.
	static func maxHold(for link: ConnectionQuality.Link) -> Double {
		switch link {
		case .internetMobile: 0.1
		case .internet: 0.07
		case .homeWired, .homeWireless: 0.05
		}
	}
	/// Lateness remembered, in frames: about 5 s over the internet, so bursts a few seconds apart are
	/// still covered, and 2 s at home, so a brief Wi-Fi blip is soon forgotten.
	private let memory: Int
	/// How much of the hold is kept each frame once lateness has passed. At home it lets go within a
	/// few seconds; over the internet much more slowly.
	private let decay: Double
	/// Unevenness too small to see, which smoothing leaves alone.
	static let tolerance: Double = 0.006

	/// The shortest gap between frames the stream allows (1 / its frame rate).
	private let minInterval: Double
	/// The rhythm frames actually arrive at: a 30 fps game in a 60 fps stream sends every 33 ms.
	private var interval: Double
	private var gaps: [Double] = []
	private var gapHead = 0
	private let lock = NSLock()
	private var lastShow: Double = 0
	private var lastDecoded: Double = 0
	private var hold: Double = 0
	private let maxHold: Double
	private var _mode: SmoothingMode
	/// Can change mid-stream; takes effect from the next frame.
	var mode: SmoothingMode {
		get { lock.lock(); defer { lock.unlock() }; return _mode }
		set { lock.lock(); _mode = newValue; lock.unlock() }
	}
	/// How far behind the beat each recent frame arrived, in seconds.
	private var lateness: [Double] = []
	private var head = 0
	/// Automatic: when recent frames arrived more than `longGap` late. Three within 30 s step up to
	/// Steadiest; a minute without one steps back down to Balanced.
	private var longGaps: [Double] = []
	private var _steppedUp = false
	/// Automatic on a mobile hotspot: whether it has stepped up to Steadiest.
	var steppedUp: Bool { lock.lock(); defer { lock.unlock() }; return _steppedUp }
	static let longGap = 0.04

	init(fps: Int, maxHold: Double, mode: SmoothingMode, home: Bool) {
		self.maxHold = maxHold
		memory = home ? 120 : 300
		decay = home ? 0.993 : 0.999
		_mode = mode
		minInterval = 1 / Double(max(fps, 1))
		interval = minInterval
	}

	/// The host time to show a frame decoded at `decodedAt`.
	func schedule(decodedAt: Double) -> Double {
		lock.lock(); defer { lock.unlock() }
		var late = 0.0
		if lastDecoded > 0 {
			// Follow the real rhythm: the median of the last second of gaps, from the stream's
			// frame rate down to 20 fps.
			let gap = decodedAt - lastDecoded
			if gaps.count < 60 { gaps.append(gap) } else { gaps[gapHead] = gap; gapHead = (gapHead + 1) % 60 }
			if gaps.count >= 10 {
				let sorted = gaps.sorted()
				interval = min(max(sorted[sorted.count / 2], minInterval), 0.05)
			}
			// A few ms early or late never shows: the frame still lands on the same display refresh.
			// Only cover lateness beyond that, so a steady network gets no added delay.
			late = max(0, gap - interval - Self.tolerance)
			if lateness.count < memory { lateness.append(late) } else { lateness[head] = late; head = (head + 1) % memory }
		}
		lastDecoded = decodedAt
		if _mode == .off {
			hold = 0
			lastShow = decodedAt
			return decodedAt
		}
		var mode = _mode
		if mode == .automatic {
			if late > Self.longGap { longGaps.append(decodedAt) }
			longGaps.removeAll { decodedAt - $0 > 60 }
			let recent = longGaps.filter { decodedAt - $0 <= 30 }.count
			if recent >= 3 { _steppedUp = true } else if longGaps.isEmpty { _steppedUp = false }
			mode = _steppedUp ? .steadiest : .balanced
		}
		if mode == .steadiest {
			// Hold for as long as the latest bad gap, so the next one like it is covered too. Shrinks
			// slowly once the network calms down.
			hold = late > hold ? min(late, maxHold) : hold * (decay + (1 - decay) / 2)
		} else {
			hold = balancedHold()
		}
		// Under a millisecond is nothing you'd see; drop it so the stats show none.
		if hold < 0.001 { hold = 0 }
		var show = max(decodedAt, min(lastShow + interval, decodedAt + hold))
		// Never ask for two frames at once: keep at least half a frame between them.
		if lastShow > 0 { show = max(show, lastShow + interval / 2) }
		lastShow = show
		return show
	}

	private func balancedHold() -> Double {
		// Cover all but the worst 3% of recent lateness. Grow at once, shrink gently, so a network
		// that bursts every few seconds isn't caught out each time.
		let sorted = lateness.sorted()
		let target = sorted.isEmpty ? 0 : min(sorted[Int(Double(sorted.count - 1) * 0.97)], maxHold)
		return target > hold ? target : max(target, hold * decay)
	}
}
