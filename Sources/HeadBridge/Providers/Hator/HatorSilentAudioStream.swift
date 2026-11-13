import AudioToolbox
import CoreAudio
import Foundation

/// Opens a temporary, completely silent PCM output stream on one explicit device.
///
/// This only activates the headset's Bluetooth audio path long enough for a
/// Spatial Audio command and its readback. It neither changes the macOS default
/// audio device nor captures audio, and it never generates audible samples.
///
/// The output queue is single-owner. Call start/stop on the main actor.
@MainActor
final class HatorSilentAudioStream {
    private var queue: AudioQueueRef?

    var isRunning: Bool { queue != nil }

    /// Returns false if the target device cannot be opened. No audio is
    /// redirected to the system's default device on failure.
    func start(deviceUID: String) -> Bool {
        if queue != nil { return true }
        guard !deviceUID.isEmpty,
            let targetUID = CFStringCreateWithCString(nil, deviceUID, CFStringBuiltInEncodings.UTF8.rawValue)
        else { return false }

        var format = AudioStreamBasicDescription(
            mSampleRate: 44_100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        // Buffers contain only zeros; the queue callback continuously recycles
        // them until the authenticated RCSP readback completes.
        let callback: AudioQueueOutputCallback = { _, audioQueue, buffer in
            AudioQueueEnqueueBuffer(audioQueue, buffer, 0, nil)
        }

        var newQueue: AudioQueueRef?
        guard AudioQueueNewOutput(&format, callback, nil, nil, nil, 0, &newQueue) == noErr,
            let newQueue
        else { return false }

        // AudioQueueSetProperty expects a pointer to a CFStringRef (not bytes).
        // An explicit device UID prevents playback on an unrelated default output.
        var uidReference = Unmanaged.passUnretained(targetUID).toOpaque()
        let selected = withExtendedLifetime(targetUID) {
            AudioQueueSetProperty(
                newQueue,
                kAudioQueueProperty_CurrentDevice,
                &uidReference,
                UInt32(MemoryLayout<UnsafeMutableRawPointer>.size)
            )
        }
        guard selected == noErr else {
            AudioQueueDispose(newQueue, true)
            return false
        }

        // Four 100 ms stereo buffers. The Audio Queue callback runs on its own
        // thread and enqueues the exact same zero-filled data.
        for _ in 0..<4 {
            var newBuffer: AudioQueueBufferRef?
            guard AudioQueueAllocateBuffer(newQueue, 4_410 * 4, &newBuffer) == noErr,
                let newBuffer
            else {
                AudioQueueDispose(newQueue, true)
                return false
            }
            memset(newBuffer.pointee.mAudioData, 0, Int(newBuffer.pointee.mAudioDataBytesCapacity))
            newBuffer.pointee.mAudioDataByteSize = newBuffer.pointee.mAudioDataBytesCapacity
            guard AudioQueueEnqueueBuffer(newQueue, newBuffer, 0, nil) == noErr else {
                AudioQueueDispose(newQueue, true)
                return false
            }
        }

        guard AudioQueueStart(newQueue, nil) == noErr else {
            AudioQueueDispose(newQueue, true)
            return false
        }
        queue = newQueue
        return true
    }

    func stop() {
        guard let queue else { return }
        self.queue = nil
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
    }
}
