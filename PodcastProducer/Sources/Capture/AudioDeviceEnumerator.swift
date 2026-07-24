import Foundation
import CoreAudio
import AudioToolbox

/// Lists CoreAudio input devices via the HAL.
///
/// Deliberately does *not* rely on an Aggregate Device: each RODE PodMic USB is
/// captured from its own HAL device so we keep one clock domain per microphone
/// and can measure (and later correct) drift instead of letting the HAL
/// resample behind our back.
struct AudioInputDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var manufacturer: String
    var inputChannelCount: Int
    var nominalSampleRate: Double

    var isLikelyMicrophone: Bool {
        inputChannelCount > 0 && inputChannelCount <= 2
    }

    var displayName: String {
        inputChannelCount > 0 ? "\(name) — \(inputChannelCount)ch @ \(Int(nominalSampleRate)) Hz" : name
    }
}

enum AudioDeviceEnumerator {

    static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { device(for: $0) }.filter { $0.inputChannelCount > 0 }
    }

    static func device(for deviceID: AudioDeviceID) -> AudioInputDevice? {
        let channels = inputChannelCount(deviceID)
        guard channels > 0 else { return nil }
        return AudioInputDevice(
            id: deviceID,
            uid: stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID) ?? "unknown-\(deviceID)",
            name: stringProperty(deviceID, selector: kAudioObjectPropertyName) ?? "Unknown device",
            manufacturer: stringProperty(deviceID, selector: kAudioObjectPropertyManufacturer) ?? "",
            inputChannelCount: channels,
            nominalSampleRate: nominalSampleRate(deviceID)
        )
    }

    static func device(matchingUID uid: String) -> AudioInputDevice? {
        inputDevices().first { $0.uid == uid }
    }

    // MARK: - Change notifications

    /// Fires whenever devices are added or removed — a USB mic being yanked
    /// mid-take is the single most common studio failure.
    static func addDeviceListListener(queue: DispatchQueue, handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        return block
    }

    static func removeDeviceListListener(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
    }

    // MARK: - HAL plumbing

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func inputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return 0
        }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return 0
        }

        let list = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
