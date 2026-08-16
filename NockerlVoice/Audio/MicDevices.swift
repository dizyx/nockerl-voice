import AVFoundation
import CoreAudio
import Foundation

/// A selectable audio input device. `uid` is the stable identifier
/// (`AVCaptureDevice.uniqueID`, which for audio equals the CoreAudio device UID).
struct MicDevice: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Lists the Mac's microphones and lets us route capture through a chosen one.
///
/// Important: `AVAudioEngine` reliably records from the *default* input device, but
/// forcing a specific device onto its input node is unreliable: it fails for
/// input-only mics (e.g. a Shure MV7+) because the engine wants one device for both
/// I/O. So selection works by temporarily setting the system default input to the
/// chosen device for the duration of a recording, then restoring it (see AudioRecorder).
enum MicDevices {
    /// Microphones currently available on this Mac.
    static func available() -> [MicDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        var result: [MicDevice] = []
        for device in session.devices where !device.uniqueID.isEmpty && seen.insert(device.uniqueID).inserted {
            result.append(MicDevice(uid: device.uniqueID, name: device.localizedName))
        }
        return result
    }

    /// Resolve a device UID to a CoreAudio `AudioDeviceID`. Nil if empty/absent.
    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var address = systemAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var deviceID = AudioDeviceID(0)
        var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &outSize, &deviceID
            )
        }
        return (status == noErr && deviceID != AudioDeviceID(0)) ? deviceID : nil
    }

    /// The current system default input device.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return (status == noErr && deviceID != AudioDeviceID(0)) ? deviceID : nil
    }

    /// Set the system default input device. Returns true on success.
    @discardableResult
    static func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var address = systemAddress(kAudioHardwarePropertyDefaultInputDevice)
        var dev = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &dev
        )
        return status == noErr
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

/// Keeps a live list of microphones: reacts to devices being plugged/unplugged via
/// a CoreAudio listener, so the picker never needs a manual refresh.
@MainActor
final class MicMonitor: ObservableObject {
    @Published private(set) var devices: [MicDevice] = []

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listener: AudioObjectPropertyListenerBlock?

    init() {
        devices = MicDevices.available()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.devices = MicDevices.available() }
        }
        listener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    deinit {
        if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listener)
        }
    }
}
