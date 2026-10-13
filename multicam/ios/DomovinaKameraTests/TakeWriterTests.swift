import AVFoundation
import XCTest

/// Exercises the real AVAssetWriter path with synthetic buffers stamped on the
/// host clock the way capture stamps them (no camera in the simulator).
final class TakeWriterTests: XCTestCase {
    let fps: Int64 = 30
    var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("take-\(UUID().uuidString).mov")
    }

    override func tearDown() {
        // KEEP_TAKE=<dir> (TEST_RUNNER_KEEP_TAKE for xcodebuild) keeps the file for ffprobe.
        if let dir = ProcessInfo.processInfo.environment["KEEP_TAKE"], FileManager.default.fileExists(atPath: url.path) {
            let dest = URL(fileURLWithPath: dir).appendingPathComponent("take-writer-test.mov")
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.moveItem(at: url, to: dest)
        }
        try? FileManager.default.removeItem(at: url)
    }

    func testFileZeroIsFirstFrameAtScheduledStart() async throws {
        let codec: AVVideoCodecType = .hevc
        let base = HostClock.nowNs()
        let frameNs: Int64 = 1_000_000_000 / fps
        // Frame i captured at base + i/30 s ± up to 0.4 ms jitter, like a real sensor.
        let jitter: [Int64] = [0, 300_000, -200_000, 400_000, -100_000]
        func videoPTS(_ i: Int) -> Int64 { base + Int64(i) * frameNs + (i == 0 ? 0 : jitter[i % jitter.count]) }

        // Scheduled for 5 frames in (minus a hair): frame 5 must be the first written.
        let startAt = HostClock.hostTime(ns: base + 5 * frameNs - 1_000_000)
        let writer = try TakeWriter(url: url, videoSettings: TakeWriter.videoSettings(codec: codec),
                                    audioSettings: TakeWriter.audioSettings, startAt: startAt)

        // Audio starts 100 ms before the first video frame, 1024-sample buffers.
        var audioNs = base - 100_000_000
        let audioStepNs: Int64 = 1024 * 1_000_000_000 / 48_000
        var startedAt: Int?
        let frames = 95
        for i in 0..<frames {
            let pts = videoPTS(i)
            while audioNs < pts {
                try await waitUntil { writer.isReadyForAudio }
                writer.appendAudio(try Self.audioBuffer(ptsNs: audioNs))
                audioNs += audioStepNs
            }
            try await waitUntil { writer.isReadyForVideo }
            if writer.appendVideo(try Self.videoBuffer(ptsNs: pts, value: UInt8(i % 255))) { startedAt = i }
            XCTAssertNil(writer.failure)
        }
        XCTAssertEqual(startedAt, 5)
        let zero = try XCTUnwrap(writer.fileZeroSourceTime)
        XCTAssertEqual(HostClock.ns(fromHostTime: zero), videoPTS(5), "fileZero must be exactly the first written frame's PTS")
        XCTAssertGreaterThan(writer.stats.audioDroppedBeforeStart, 0)

        let error: Error? = await withCheckedContinuation { cont in writer.finish { cont.resume(returning: $0) } }
        XCTAssertNil(error)
        XCTAssertEqual(writer.stats.videoFrames, frames - 5)

        // Read the file back: frame 0 at 0, 1080p, 30 fps, chosen codec, AAC 48 kHz mono.
        let asset = AVURLAsset(url: url)
        let video = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .video).first)
        let (size, nominal, range, formats) = try await video.load(.naturalSize, .nominalFrameRate, .timeRange, .formatDescriptions)
        XCTAssertEqual(size, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(Double(nominal), 30, accuracy: 0.05)
        XCTAssertEqual(range.start, .zero)
        XCTAssertEqual(range.duration.seconds, Double(frames - 5) / 30, accuracy: 0.001)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(formats[0]), kCMVideoCodecType_HEVC)

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var times: [CMTime] = []
        while let sb = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) > 0 { times.append(CMSampleBufferGetPresentationTimeStamp(sb)) }
        }
        XCTAssertEqual(times.count, frames - 5)
        XCTAssertEqual(times.first, .zero, "PTS 0 of the video track is the first frame")
        // Every frame lands within 1 ms of where its capture time says it should.
        for (k, t) in times.enumerated() {
            let expected = Double(videoPTS(5 + k) - videoPTS(5)) / 1e9
            XCTAssertEqual(t.seconds, expected, accuracy: 0.001, "frame \(k)")
        }

        let audio = try await XCTUnwrapAsync(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormats = try await audio.load(.formatDescriptions)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(audioFormats[0])?.pointee)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(asbd.mSampleRate, 48_000)
        XCTAssertEqual(asbd.mChannelsPerFrame, 1)
        let audioRange = try await audio.load(.timeRange)
        XCTAssertGreaterThanOrEqual(audioRange.start.seconds, 0)
        XCTAssertLessThan(audioRange.start.seconds, 0.03, "audio begins within one buffer of frame 0")
    }

    func testStopBeforeFirstFrameDiscardsFile() async throws {
        let writer = try TakeWriter(url: url, videoSettings: TakeWriter.videoSettings(codec: .hevc),
                                    audioSettings: TakeWriter.audioSettings,
                                    startAt: HostClock.hostTime(ns: HostClock.nowNs() + 60_000_000_000))
        XCTAssertFalse(writer.appendVideo(try Self.videoBuffer(ptsNs: HostClock.nowNs(), value: 0)))
        let error: Error? = await withCheckedContinuation { cont in writer.finish { cont.resume(returning: $0) } }
        guard case TakeWriter.WriterError.notStarted? = error else { return XCTFail("expected notStarted, got \(String(describing: error))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Synthetic buffers

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 where !condition() { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(condition(), "writer input never became ready")
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }

    static func videoBuffer(ptsNs: Int64, value: UInt8) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { throw NSError(domain: "test", code: 1) }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane), Int32(plane == 0 ? value : 128),
                   CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: HostClock.hostTime(ns: ptsNs), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &sb)
        return try XCTUnwrap(sb)
    }

    static func audioBuffer(ptsNs: Int64, frames: Int = 1024) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = frames * 2
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
        var samples = (0..<frames).map { Int16(sin(Double($0) * 2 * .pi * 440 / 48_000) * 8000) }
        CMBlockBufferReplaceDataBytes(with: &samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!,
                                                             sampleCount: frames, presentationTimeStamp: HostClock.hostTime(ns: ptsNs),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        return try XCTUnwrap(sb)
    }
}
