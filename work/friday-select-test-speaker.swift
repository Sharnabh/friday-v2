import CoreAudio
import Foundation
let system = AudioObjectID(kAudioObjectSystemObject)
let output = CommandLine.arguments.dropFirst().first ?? "MacBook Pro Speakers"
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
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
          let value = name?.takeRetainedValue() as String?, value == output else { continue }
    var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { continue }
    var target = device
    let result = AudioObjectSetPropertyData(system, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: target)), &target)
    guard result == noErr else { print("Core Audio error \(result)"); exit(1) }
    print("Default output set to \(value)")
    exit(0)
}
exit(1)
