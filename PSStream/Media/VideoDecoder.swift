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
	private let renderer: AVSampleBufferVideoRenderer
	private let stats: StreamStats
	private var formatDescription: CMVideoFormatDescription?
	private var session: VTDecompressionSession?
	private var parameterSets: [UInt8: Data] = [:] // keyed by NAL type
	private var waitingForKeyframe = true
	private let log = Logger(subsystem: "PSStream", category: "Video")
	/// Called when the decoder needs a fresh keyframe (e.g. after a decode failure).
	var requestKeyframe: (() -> Void)?

	init(codec: Codec, renderer: AVSampleBufferVideoRenderer, stats: StreamStats) {
		self.codec = codec
		self.renderer = renderer
		self.stats = stats
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

		var format: CMVideoFormatDescription?
		guard CMVideoFormatDescriptionCreateForImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescriptionOut: &format) == noErr,
			let format else { return }
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
		var sample: CMSampleBuffer?
		guard CMSampleBufferCreateReadyWithImageBuffer(
			allocator: kCFAllocatorDefault, imageBuffer: imageBuffer, formatDescription: format,
			sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
		Self.markDisplayImmediately(sample)
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
		log.info("Video format: \(dims.width)x\(dims.height)")

		let spec: [CFString: Any] = [
			kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true,
		]
		let attrs: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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
