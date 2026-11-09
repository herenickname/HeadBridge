import Foundation
import XCTest
@testable import HeadBridge

final class HostEqualizerDSPTests: XCTestCase {
    func testFlatIsBitIdentical() {
        let input = mixedInput(frames: 4096, channels: 2)
        let processor = HostEqualizerProcessor()
        processor.apply(.flat, sampleRate: 44100)
        let output = processed(input, with: processor, channels: 2)
        XCTAssertEqual(output.map(\.bitPattern), input.map(\.bitPattern))
        XCTAssertFalse(processor.isTransitioning)

        var inPlace = input
        inPlace.withUnsafeMutableBufferPointer { buffer in
            processor.process(
                UnsafePointer(buffer.baseAddress!), buffer.baseAddress!, frames: 4096, channels: 2
            )
        }
        XCTAssertEqual(inPlace.map(\.bitPattern), input.map(\.bitPattern))
    }

    func testFlatAfterTransitionIsBitIdentical() {
        let processor = HostEqualizerProcessor()
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        processor.apply(settings, sampleRate: 44100)
        _ = processed(mixedInput(frames: 8192, channels: 2), with: processor, channels: 2)
        XCTAssertFalse(processor.isTransitioning)
        processor.apply(.flat, sampleRate: 44100)
        _ = processed(mixedInput(frames: 8192, channels: 2), with: processor, channels: 2)
        XCTAssertFalse(processor.isTransitioning)

        let input = mixedInput(frames: 4096, channels: 2)
        let output = processed(input, with: processor, channels: 2)
        XCTAssertEqual(output.map(\.bitPattern), input.map(\.bitPattern))
    }

    func testPeakingGainAtCentre() {
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        for sampleRate in [44100.0, 48000.0] {
            let preGain = EQDesign.preGain(for: EQDesign.cascade(settings, sampleRate: sampleRate))
            for frequency in [1000.0, 100.0] {
                let input = (0..<Int(2 * sampleRate)).map {
                    Float(0.1 * sin(2 * Double.pi * frequency * Double($0) / sampleRate))
                }
                let processor = HostEqualizerProcessor()
                processor.apply(settings, sampleRate: sampleRate)
                let output = processed(input, with: processor, channels: 1)
                let start = input.count - Int(0.5 * sampleRate)
                let inputPower = input[start...].reduce(0.0) { $0 + Double($1) * Double($1) }
                let outputPower = output[start...].reduce(0.0) { $0 + Double($1) * Double($1) }
                let measuredDB = 10 * log10(outputPower / inputPower)
                let expectedDB = (frequency == 1000 ? 6.0 : 0.0) + 20 * log10(Double(preGain))
                XCTAssertEqual(
                    measuredDB, expectedDB, accuracy: 0.15,
                    "Sample rate \(sampleRate), frequency \(frequency)"
                )
            }
        }
    }

    func testPreGainBoundsAdversarialInput() {
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        settings.gainsDB[6] = 6
        let cascade = EQDesign.cascade(settings, sampleRate: 44100)
        var impulse = Array(repeating: 0.0, count: 8192)
        impulse[0] = 1
        let response = reference(impulse, cascade: cascade)
        let input: [Float] = response.reversed().map { $0 > 0 ? 1 : ($0 < 0 ? -1 : 0) }
        let bound = response.reduce(0) { $0 + abs($1) }
        let exact = min(1.0, 1.0 / (bound * 1.01))
        let rounded = Float(exact)
        XCTAssertEqual(EQDesign.preGain(for: cascade), Double(rounded) > exact ? rounded.nextDown : rounded)

        let processor = HostEqualizerProcessor()
        processor.apply(settings, sampleRate: 44100)
        _ = processed(Array(repeating: 0, count: 8192), with: processor, channels: 1)
        XCTAssertFalse(processor.isTransitioning)
        let output = processed(input, with: processor, channels: 1)
        for (index, sample) in output.enumerated() {
            XCTAssertLessThanOrEqual(abs(sample), 1.0 + 1e-5, "Sample \(index)")
        }
        XCTAssertEqual(abs(output.last!), 1 / 1.01, accuracy: 1e-5)
    }

    func testIdentityPreGainIsExactlyOne() {
        let cascade = EQDesign.cascade(.flat, sampleRate: 44100)
        XCTAssertEqual(cascade, Array(repeating: .identity, count: 10))
        XCTAssertEqual(EQDesign.preGain(for: cascade), 1.0)
    }

    func testChannelIsolation() {
        var input = mixedInput(frames: 8192, channels: 2)
        for frame in 0..<8192 { input[frame * 2 + 1] = 0 }
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        settings.gainsDB[6] = -3
        let processor = HostEqualizerProcessor()
        processor.apply(settings, sampleRate: 44100)
        let output = processed(input, with: processor, channels: 2)
        for frame in 0..<8192 {
            let bits = output[frame * 2 + 1].bitPattern
            XCTAssertTrue(bits == Float(0).bitPattern || bits == Float(-0.0).bitPattern)
        }
        XCTAssertTrue(stride(from: 0, to: input.count, by: 2).contains { output[$0] != input[$0] })
    }

    func testBlockSizeIndependence() {
        var settings = EQSettings.flat
        settings.gainsDB[0] = -6
        settings.gainsDB[5] = 6
        settings.gainsDB[9] = 3
        let whole = HostEqualizerProcessor()
        let chunked = HostEqualizerProcessor()
        let inPlaceProcessor = HostEqualizerProcessor()
        let silence = Array(repeating: Float(0), count: 8192 * 2)
        for processor in [whole, chunked, inPlaceProcessor] {
            processor.apply(settings, sampleRate: 44100)
            _ = processed(silence, with: processor, channels: 2)
            XCTAssertFalse(processor.isTransitioning)
        }
        let input = mixedInput(frames: 8192, channels: 2)
        let wholeOutput = processed(input, with: whole, channels: 2, blockSize: 8192)
        let chunkedOutput = processed(input, with: chunked, channels: 2, blockSize: 64)
        XCTAssertEqual(wholeOutput.map(\.bitPattern), chunkedOutput.map(\.bitPattern))

        var inPlace = input
        inPlace.withUnsafeMutableBufferPointer { buffer in
            inPlaceProcessor.process(
                UnsafePointer(buffer.baseAddress!), buffer.baseAddress!, frames: 8192, channels: 2
            )
        }
        XCTAssertEqual(inPlace.map(\.bitPattern), wholeOutput.map(\.bitPattern))
    }

    func testApplyWhileLockHeldDoesNotBlock() {
        let processor = HostEqualizerProcessor()
        let input = mixedInput(frames: 64, channels: 2)
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        processor.apply(settings, sampleRate: 44100)
        let completed = DispatchSemaphore(value: 0)
        processor._withLockHeld {
            DispatchQueue.global(qos: .userInteractive).async {
                let output = self.processed(input, with: processor, channels: 2)
                XCTAssertEqual(output.map(\.bitPattern), input.map(\.bitPattern))
                completed.signal()
            }
            XCTAssertEqual(completed.wait(timeout: .now() + .milliseconds(100)), .success)
            XCTAssertFalse(processor.isTransitioning)
        }
        _ = processed([0, 0], with: processor, channels: 2)
        XCTAssertTrue(processor.isTransitioning)
    }

    func testValidatedSettings() throws {
        XCTAssertNil(EQSettings.validated([]))
        XCTAssertNil(EQSettings.validated(Array(repeating: 0, count: 9)))
        XCTAssertNil(EQSettings.validated(Array(repeating: 0, count: 11)))
        for invalid in [Double.nan, .infinity, -.infinity, 6.5, -6.5, 0.3] {
            var gains = EQSettings.flat.gainsDB
            gains[5] = invalid
            XCTAssertNil(EQSettings.validated(gains))
        }
        let gains: [Double] = [-6, -5.5, -3, -0.5, -0.0, 0, 0.5, 3, 5.5, 6]
        let settings = try XCTUnwrap(EQSettings.validated(gains))
        XCTAssertEqual(settings.gainsDB, gains)
        XCTAssertFalse(settings.isFlat)
        XCTAssertTrue(EQSettings.flat.isFlat)
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(EQSettings.self, from: encoded), settings)
        var nearStep = gains
        nearStep[2] = 0.5 + 5e-10
        XCTAssertNotNil(EQSettings.validated(nearStep))
        nearStep[2] = 0.5 + 2e-9
        XCTAssertNil(EQSettings.validated(nearStep))
    }

    func testPeakingAtOrAboveNyquistIsIdentity() {
        for sampleRate in [22050.0, 44100.0, 48000.0] {
            for frequency in [sampleRate / 2, sampleRate] {
                XCTAssertEqual(
                    EQDesign.peaking(
                        frequency: frequency, gainDB: 6, q: EQSettings.q, sampleRate: sampleRate
                    ), .identity
                )
            }
        }
        var settings = EQSettings.flat
        settings.gainsDB[9] = 6
        XCTAssertEqual(EQDesign.cascade(settings, sampleRate: 22050)[9], .identity)
    }

    func testExcessChannelsAreBitIdentical() {
        let input = mixedInput(frames: 4096, channels: 4)
        let processor = HostEqualizerProcessor(maximumChannels: 2)
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        processor.apply(settings, sampleRate: 44100)
        let output = processed(input, with: processor, channels: 4)
        for frame in 0..<4096 {
            for channel in 2..<4 {
                let index = frame * 4 + channel
                XCTAssertEqual(output[index].bitPattern, input[index].bitPattern)
            }
        }
        XCTAssertNotEqual(output[4], input[4])
    }

    func testCrossfadeProgressesPerFrameAcrossBlocks() {
        var settings = EQSettings.flat
        settings.gainsDB[5] = 6
        let processor = HostEqualizerProcessor()
        let chunked = HostEqualizerProcessor()
        for instance in [processor, chunked] { instance.apply(settings, sampleRate: 44100) }
        let prefix = mixedInput(frames: 881, channels: 2)
        let output = processed(prefix, with: processor, channels: 2)
        let chunkedOutput = processed(prefix, with: chunked, channels: 2, blockSize: 64)
        XCTAssertEqual(output.map(\.bitPattern), chunkedOutput.map(\.bitPattern))
        XCTAssertTrue(processor.isTransitioning)
        XCTAssertTrue(chunked.isTransitioning)

        let cascade = EQDesign.cascade(settings, sampleRate: 44100)
        let preGain = EQDesign.preGain(for: cascade)
        for channel in 0..<2 {
            let input = (0..<881).map { Double(preGain * prefix[$0 * 2 + channel]) }
            let incoming = reference(input, cascade: cascade)
            for frame in 0..<881 {
                let t = Double(frame + 1) / 882
                let expected = (1 - t) * Double(prefix[frame * 2 + channel]) + t * incoming[frame]
                XCTAssertEqual(Double(output[frame * 2 + channel]), expected, accuracy: 1e-5)
            }
        }
        _ = processed([0, 0], with: processor, channels: 2)
        XCTAssertFalse(processor.isTransitioning)
        let tail = mixedInput(frames: 128, channels: 2)
        let tailOutput = processed(tail, with: processor, channels: 2)
        _ = processed([0, 0], with: chunked, channels: 2)
        let chunkedTail = processed(tail, with: chunked, channels: 2, blockSize: 64)
        XCTAssertEqual(tailOutput.map(\.bitPattern), chunkedTail.map(\.bitPattern))
    }

    func testUpdatesCoalesceUntilRunningCrossfadeCompletes() {
        var a = EQSettings.flat
        a.gainsDB[0] = 6
        var b = EQSettings.flat
        b.gainsDB[1] = -6
        let processor = HostEqualizerProcessor()
        let input = (0..<2048).map {
            Float(0.5 * sin(2 * Double.pi * 50 * Double($0) / 44100))
        }
        processor.apply(a, sampleRate: 44100)
        let aSequence = processor._configurationSequence
        var output = processed(Array(input[..<100]), with: processor, channels: 1)
        XCTAssertTrue(processor.isTransitioning)
        processor.apply(.flat, sampleRate: 44100)
        processor.apply(b, sampleRate: 44100)
        let bSequence = processor._configurationSequence
        output += processed(Array(input[100..<882]), with: processor, channels: 1, blockSize: 64)
        XCTAssertFalse(processor.isTransitioning)
        XCTAssertEqual(processor._activeConfigurationSequence, aSequence)
        output += processed(Array(input[882...]), with: processor, channels: 1, blockSize: 64)
        XCTAssertFalse(processor.isTransitioning)
        XCTAssertEqual(processor._activeConfigurationSequence, bSequence)
        let inputJump = zip(input, input.dropFirst()).map { abs($1 - $0) }.max()!
        let outputJump = zip(output, output.dropFirst()).map { abs($1 - $0) }.max()!
        XCTAssertLessThanOrEqual(outputJump, inputJump * 2)
    }

    private func mixedInput(frames: Int, channels: Int) -> [Float] {
        let special: [Float] = [
            0.0, -0.0, .leastNonzeroMagnitude, -.leastNonzeroMagnitude, 1.0, -1.0, 1.5, -1.5,
        ]
        var seed: UInt64 = 0x13579BDF2468ACE0
        return (0..<(frames * channels)).map { index in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return index % 32 < special.count
                ? special[index % 32]
                : Float(Int32(truncatingIfNeeded: seed >> 32)) / Float(Int32.max)
        }
    }

    private func processed(
        _ input: [Float], with processor: HostEqualizerProcessor,
        channels: Int, blockSize: Int = 8192
    ) -> [Float] {
        var output = Array(repeating: Float(0), count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                let frames = input.count / channels
                for start in stride(from: 0, to: frames, by: blockSize) {
                    processor.process(
                        source.baseAddress!.advanced(by: start * channels),
                        destination.baseAddress!.advanced(by: start * channels),
                        frames: min(blockSize, frames - start), channels: channels
                    )
                }
            }
        }
        return output
    }

    private func reference(_ input: [Double], cascade: [BiquadCoefficients]) -> [Double] {
        var state = Array(repeating: (0.0, 0.0), count: cascade.count)
        return input.map { inputSample in
            var sample = inputSample
            for section in cascade.indices {
                let c = cascade[section]
                let output = Double(c.b0) * sample + state[section].0
                state[section].0 = Double(c.b1) * sample - Double(c.a1) * output + state[section].1
                state[section].1 = Double(c.b2) * sample - Double(c.a2) * output
                sample = output
            }
            return sample
        }
    }
}
