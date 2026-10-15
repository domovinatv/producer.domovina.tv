// mic_gain.swift — čita i postavlja ulazno pojačanje USB mikrofona kroz CoreAudio.
//
// RØDE Connect nema AppleScript rječnik ni URL shemu, pa se njegove postavke ne mogu
// skriptirati. Ali gain PodMica USB nije postavka RØDE Connecta — on je na samom
// mikrofonu, a macOS ga izlaže kao kAudioDevicePropertyVolumeDecibels na ulaznom
// scopeu. Provjereno na PodMic USB: raspon 22-63 dB, upis prolazi i dok RØDE Connect
// radi.
//
// Upotreba:
//   swift scripts/mic_gain.swift list
//   swift scripts/mic_gain.swift set "PodMic" 58
//   swift scripts/mic_gain.swift set-id 177 58
//
// Kod `set` se mijenjaju SVI uređaji čije ime sadrži zadani niz. Kad su spojena dva
// istoimena mikrofona (a jesu), koristi `set-id` s točnim ID-em iz `list`.

import Foundation
import CoreAudio

func allDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func deviceName(_ id: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
          let value = name?.takeRetainedValue() else { return "?" }
    return value as String
}

/// Gain je uvijek na elementu 0 ulaznog scopea. Uređaj koji ga nema (npr. virtualni
/// RØDE Connect izlaz) vraća nil i preskače se.
func gainAddress() -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                               mScope: kAudioObjectPropertyScopeInput,
                               mElement: 0)
}

func readGain(_ id: AudioObjectID) -> Float32? {
    var address = gainAddress()
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func gainRange(_ id: AudioObjectID) -> (Float64, Float64)? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels,
                                             mScope: kAudioObjectPropertyScopeInput,
                                             mElement: 0)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var range = AudioValueRange()
    var size = UInt32(MemoryLayout<AudioValueRange>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &range) == noErr else { return nil }
    return (range.mMinimum, range.mMaximum)
}

/// Vraća vrijednost koju je uređaj STVARNO prihvatio, ne onu koju smo tražili:
/// hardver kvantizira gain u svoje korake i tiho zaokružuje.
func writeGain(_ id: AudioObjectID, _ decibels: Float32) -> (ok: Bool, applied: Float32?) {
    var address = gainAddress()
    guard AudioObjectHasProperty(id, &address) else { return (false, nil) }
    var settable: DarwinBoolean = false
    AudioObjectIsPropertySettable(id, &address, &settable)
    guard settable.boolValue else { return (false, nil) }
    var value = decibels
    let status = AudioObjectSetPropertyData(id, &address, 0, nil,
                                            UInt32(MemoryLayout<Float32>.size), &value)
    return (status == noErr, readGain(id))
}

func inputDevices() -> [(id: AudioObjectID, name: String)] {
    allDevices().compactMap { id in
        readGain(id) != nil ? (id, deviceName(id)) : nil
    }
}

let arguments = CommandLine.arguments

func printUsage() {
    print("""
    Upotreba:
      swift scripts/mic_gain.swift list
      swift scripts/mic_gain.swift set <dio-imena> <dB>
      swift scripts/mic_gain.swift set-id <id> <dB>
    """)
}

guard arguments.count >= 2 else { printUsage(); exit(1) }

switch arguments[1] {
case "list":
    let devices = inputDevices()
    guard !devices.isEmpty else { print("Nema ulaznih uređaja s podesivim gainom."); exit(0) }
    for device in devices {
        let gain = readGain(device.id).map { String(format: "%.1f dB", $0) } ?? "?"
        let range = gainRange(device.id).map { String(format: "%.0f–%.0f dB", $0.0, $0.1) } ?? "?"
        print(String(format: "  id %-5d  %-28@  gain %-10@ raspon %@",
                     device.id, device.name as NSString, gain as NSString, range as NSString))
    }

case "set", "set-id":
    guard arguments.count == 4, let target = Float32(arguments[3]) else { printUsage(); exit(1) }
    let devices = inputDevices().filter { device in
        arguments[1] == "set-id" ? String(device.id) == arguments[2]
                                 : device.name.localizedCaseInsensitiveContains(arguments[2])
    }
    guard !devices.isEmpty else { print("❌ Nijedan uređaj ne odgovara: \(arguments[2])"); exit(1) }

    var failed = false
    for device in devices {
        let before = readGain(device.id) ?? -1
        if let range = gainRange(device.id), target < Float32(range.0) || target > Float32(range.1) {
            print(String(format: "❌ %@ [id %d]: %.1f dB je izvan raspona %.0f–%.0f dB",
                         device.name, device.id, target, range.0, range.1))
            failed = true
            continue
        }
        let result = writeGain(device.id, target)
        let applied = result.applied ?? -1
        // Hardver zaokružuje na svoj korak; sve unutar 0.6 dB je uspjeh, ne greška.
        let landed = abs(applied - target) < 0.6
        print(String(format: "%@ %@ [id %d]: %.1f → %.1f dB%@",
                     result.ok && landed ? "✅" : "⚠️ ",
                     device.name, device.id, before, applied,
                     landed ? "" : String(format: "  (traženo %.1f)", target)))
        if !result.ok { failed = true }
    }
    exit(failed ? 1 : 0)

default:
    printUsage()
    exit(1)
}
