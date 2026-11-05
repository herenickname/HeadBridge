import Darwin
import os

struct EQSettings: Equatable, Codable {
    static let centreFrequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let gainRange: ClosedRange<Double> = -6...6
    static let gainStep = 0.5
    static let q = 2.0.squareRoot()
    static let flat = EQSettings(gainsDB: Array(repeating: 0, count: 10))

    var gainsDB: [Double]

    var isFlat: Bool { gainsDB.allSatisfy { $0 == 0 } }

    static func validated(_ gains: [Double]) -> EQSettings? {
        guard gains.count == 10,
            gains.allSatisfy({ gain in
                gain.isFinite && gainRange.contains(gain)
                    && abs(gain - (gain / gainStep).rounded() * gainStep) <= 1e-9
            })
        else { return nil }
        return EQSettings(gainsDB: gains)
    }
}

struct BiquadCoefficients: Equatable {
    var b0, b1, b2, a1, a2: Float

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
}

enum EQDesign {
    static func peaking(
        frequency: Double, gainDB: Double, q: Double, sampleRate: Double
    ) -> BiquadCoefficients {
        guard frequency < sampleRate / 2 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosine = cos(w0)
        let a0 = 1 + alpha / a
        return BiquadCoefficients(
            b0: Float((1 + alpha * a) / a0),
            b1: Float(-2 * cosine / a0),
            b2: Float((1 - alpha * a) / a0),
            a1: Float(-2 * cosine / a0),
            a2: Float((1 - alpha / a) / a0)
        )
    }

    static func cascade(_ settings: EQSettings, sampleRate: Double) -> [BiquadCoefficients] {
        EQSettings.centreFrequencies.enumerated().map { index, frequency in
            let gain = settings.gainsDB[index]
            return gain == 0
                ? .identity
                : peaking(
                    frequency: frequency, gainDB: gain, q: EQSettings.q, sampleRate: sampleRate
                )
        }
    }

    static func preGain(for cascade: [BiquadCoefficients]) -> Float {
        guard !cascade.allSatisfy({ $0 == .identity }) else { return 1 }
        var z1 = Array(repeating: 0.0, count: cascade.count)
        var z2 = Array(repeating: 0.0, count: cascade.count)
        var sum = 0.0
        for frame in 0..<8192 {
            var sample = frame == 0 ? 1.0 : 0.0
            for section in cascade.indices {
                let coefficients = cascade[section]
                let output = Double(coefficients.b0) * sample + z1[section]
                z1[section] =
                    Double(coefficients.b1) * sample
                    - Double(coefficients.a1) * output + z2[section]
                z2[section] = Double(coefficients.b2) * sample - Double(coefficients.a2) * output
                sample = output
            }
            sum += abs(sample)
        }
        let exact = min(1.0, 1.0 / (sum * 1.01))
        let result = Float(exact)
        return Double(result) > exact ? result.nextDown : result
    }
}

/// A single audio consumer processes samples; configuration writers may run on other threads.
final class HostEqualizerProcessor {
    private struct Configuration {
        let coefficients: UnsafeMutablePointer<BiquadCoefficients>
        var preGain: Float = 1
        var isFlat = true
        var crossfadeFrames = 882
        var sequence: UInt64 = 0

        init() {
            coefficients = .allocate(capacity: 10)
            coefficients.initialize(repeating: .identity, count: 10)
        }
    }

    private let maximumChannels: Int
    private let banks: UnsafeMutablePointer<Configuration>
    private let states: UnsafeMutablePointer<Float>
    private let lock: OSAllocatedUnfairLock<Configuration>
    private var appliedSequence: UInt64 = 0
    private var activeBank = 0
    private var fadeRemaining = 0

    var isTransitioning: Bool { fadeRemaining > 0 }
    var preGain: Float { lock.withLock { $0.preGain } }
    internal var _configurationSequence: UInt64 { lock.withLock { $0.sequence } }
    internal var _activeConfigurationSequence: UInt64 { banks[activeBank].sequence }

    init(maximumChannels: Int = 2) {
        precondition(maximumChannels > 0)
        self.maximumChannels = maximumChannels
        banks = .allocate(capacity: 2)
        banks.initialize(to: Configuration())
        banks.advanced(by: 1).initialize(to: Configuration())
        states = .allocate(capacity: maximumChannels * 40)
        states.initialize(repeating: 0, count: maximumChannels * 40)
        lock = OSAllocatedUnfairLock(uncheckedState: Configuration())
    }

    deinit {
        for bank in 0..<2 {
            banks[bank].coefficients.deinitialize(count: 10)
            banks[bank].coefficients.deallocate()
        }
        banks.deinitialize(count: 2)
        banks.deallocate()
        states.deinitialize(count: maximumChannels * 40)
        states.deallocate()
        lock.withLock { pending in
            pending.coefficients.deinitialize(count: 10)
            pending.coefficients.deallocate()
        }
    }

    func apply(_ settings: EQSettings, sampleRate: Double) {
        precondition(settings.gainsDB.count == 10)
        precondition(sampleRate.isFinite && sampleRate > 0)
        let coefficients = EQDesign.cascade(settings, sampleRate: sampleRate)
        let preGain = EQDesign.preGain(for: coefficients)
        let isFlat = settings.isFlat
        let crossfadeFrames = Int(0.02 * sampleRate)
        while lock.withLockIfAvailable({ pending in
            for section in 0..<10 {
                pending.coefficients[section] = coefficients[section]
            }
            pending.preGain = preGain
            pending.isFlat = isFlat
            pending.crossfadeFrames = crossfadeFrames
            pending.sequence &+= 1
            return true
        }) != true {
            usleep(200)
        }
    }

    func process(
        _ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>,
        frames: Int, channels: Int
    ) {
        guard frames > 0, channels > 0 else { return }
        lock.withLockIfAvailable { pending in
            guard self.fadeRemaining == 0, pending.sequence != self.appliedSequence else { return }
            let incomingBank = 1 - self.activeBank
            for section in 0..<10 {
                self.banks[incomingBank].coefficients[section] = pending.coefficients[section]
            }
            self.banks[incomingBank].preGain = pending.preGain
            self.banks[incomingBank].isFlat = pending.isFlat
            self.banks[incomingBank].crossfadeFrames = pending.crossfadeFrames
            self.banks[incomingBank].sequence = pending.sequence
            let stateOffset = incomingBank * self.maximumChannels * 20
            for index in 0..<(self.maximumChannels * 20) {
                self.states[stateOffset + index] = 0
            }
            self.appliedSequence = pending.sequence
            self.fadeRemaining = pending.crossfadeFrames
            if self.fadeRemaining == 0 || (self.banks[self.activeBank].isFlat && pending.isFlat) {
                self.activeBank = incomingBank
                self.fadeRemaining = 0
            }
        }

        let processedChannels = min(channels, maximumChannels)
        for frame in 0..<frames {
            let incomingBank = 1 - activeBank
            let fading = fadeRemaining > 0
            let t =
                fading
                ? Float(banks[incomingBank].crossfadeFrames - fadeRemaining + 1)
                    / Float(banks[incomingBank].crossfadeFrames)
                : 0
            for channel in 0..<channels {
                let index = frame * channels + channel
                let sample = input[index]
                if channel >= processedChannels || (!fading && banks[activeBank].isFlat) {
                    output[index] = sample
                } else {
                    let old = filtered(sample, bank: activeBank, channel: channel)
                    if fading {
                        let incoming = filtered(sample, bank: incomingBank, channel: channel)
                        output[index] = (1 - t) * old + t * incoming
                    } else {
                        output[index] = old
                    }
                }
            }
            if fading {
                fadeRemaining -= 1
                if fadeRemaining == 0 { activeBank = incomingBank }
            }
        }
    }

    private func filtered(_ input: Float, bank: Int, channel: Int) -> Float {
        if banks[bank].isFlat { return input }
        var sample = banks[bank].preGain * input
        let stateOffset = (bank * maximumChannels + channel) * 20
        for section in 0..<10 {
            let coefficients = banks[bank].coefficients[section]
            if coefficients == .identity { continue }
            let index = stateOffset + section * 2
            let output = coefficients.b0 * sample + states[index]
            states[index] = coefficients.b1 * sample - coefficients.a1 * output + states[index + 1]
            states[index + 1] = coefficients.b2 * sample - coefficients.a2 * output
            sample = output
        }
        return sample
    }

    internal func _withLockHeld(_ body: () -> Void) {
        lock.withLockUnchecked { _ in body() }
    }
}
