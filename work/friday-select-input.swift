import CoreAudio
import Foundation
let system = AudioObjectID(kAudioObjectSystemObject)
let input = CommandLine.arguments.dropFirst().first ?? "MacBook Pro Microphone"
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var size: UInt32 = 0
guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr else { exit(1) }
var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &devices) == noErr else { exit(1) }
for device in devices {
    var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var nameSize = UInt32(MemoryLayout.size(ofValue: name))
    guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
          let value = name?.takeRetainedValue() as String?, value == input else { continue }
    var target = device
    let result = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: target)), &target)
    guard result == noErr else { print("Core Audio error \(result)"); exit(1) }
    print("Default input set to \(value)")
    exit(0)
}
exit(1)
