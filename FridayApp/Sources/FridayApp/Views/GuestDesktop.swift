import SwiftUI
import Virtualization

@MainActor
final class GuestController:NSObject,ObservableObject,VZVirtualMachineDelegate {
    @Published var guest:VZVirtualMachine?
    @Published var message=""
    @Published var exchange:URL?
    let storageRoot: URL
    let settings: UserDefaults

    init(storageRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
         settings: UserDefaults = .standard) {
        self.storageRoot = storageRoot
        self.settings = settings
    }

    func start(owner:String,installer:URL?) async {
        guard guest==nil else {return}
        do {
            guard VZVirtualMachine.isSupported else {throw CocoaError(.featureUnsupported)}
            let config=VZVirtualMachineConfiguration()
            config.cpuCount=max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,min(2,VZVirtualMachineConfiguration.maximumAllowedCPUCount))
            config.memorySize=max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,2*1024*1024*1024)
            let idKey="guest.disk."+owner
            let id=settings.string(forKey:idKey).flatMap(UUID.init(uuidString:)) ?? UUID()
            settings.set(id.uuidString,forKey:idKey)
            let folder=storageRoot.appendingPathComponent("Friday/Guests/"+id.uuidString)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let loader=VZEFIBootLoader(),vars=folder.appendingPathComponent("EFI.vars")
            loader.variableStore = FileManager.default.fileExists(atPath:vars.path) ? VZEFIVariableStore(url:vars) : try VZEFIVariableStore(creatingVariableStoreAt:vars)
            config.bootLoader=loader
            let exchangeDir=folder.appendingPathComponent("Exchange")
            try FileManager.default.createDirectory(at:exchangeDir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let share=VZVirtioFileSystemDeviceConfiguration(tag:"friday")
            share.share=VZSingleDirectoryShare(directory:VZSharedDirectory(url:exchangeDir,readOnly:false))
            config.directorySharingDevices=[share]
            exchange=exchangeDir
            let disk=folder.appendingPathComponent("guest.img")
            if !FileManager.default.fileExists(atPath:disk.path) {
                guard installer != nil else {message="Choose a Linux installer ISO for the first boot.";return}
                guard FileManager.default.createFile(atPath:disk.path,contents:nil) else {throw CocoaError(.fileWriteUnknown)}
                let h=try FileHandle(forWritingTo:disk);defer {try? h.close()}
                try h.truncate(atOffset:16*1024*1024*1024)
            }
            var drives=[VZStorageDeviceConfiguration]()
            if let installer {drives.append(VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:installer,readOnly:true)))}
            drives.append(VZVirtioBlockDeviceConfiguration(attachment:try VZDiskImageStorageDeviceAttachment(url:disk,readOnly:false)))
            config.storageDevices=drives
            let graphics=VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts=[VZVirtioGraphicsScanoutConfiguration(widthInPixels:1280,heightInPixels:800)]
            config.graphicsDevices=[graphics];config.keyboards=[VZUSBKeyboardConfiguration()];config.pointingDevices=[VZUSBScreenCoordinatePointingDeviceConfiguration()]
            let net=VZVirtioNetworkDeviceConfiguration();net.attachment=VZNATNetworkDeviceAttachment();config.networkDevices=[net]
            config.entropyDevices=[VZVirtioEntropyDeviceConfiguration()]
            try config.validate()
            let vm=VZVirtualMachine(configuration:config);vm.delegate=self
            guest=vm;try await vm.start();message="Guest running"
        }catch {guest=nil;message=error.localizedDescription}
    }
    func shutdown(){do {try guest?.requestStop();message="Shutdown requested"}catch {message=error.localizedDescription}}
    nonisolated func guestDidStop(_ virtualMachine:VZVirtualMachine) {Task {@MainActor in guest=nil;message="Guest stopped"}}
    nonisolated func virtualMachine(_ virtualMachine:VZVirtualMachine,didStopWithError error:Error){Task {@MainActor in guest=nil;message=error.localizedDescription}}
}
struct GuestDisplay:NSViewRepresentable {
    let vm:VZVirtualMachine
    func makeNSView(context:Context)->VZVirtualMachineView {let view=VZVirtualMachineView();view.virtualMachine=vm;view.capturesSystemKeys=false;return view}
    func updateNSView(_ view:VZVirtualMachineView,context:Context){view.virtualMachine=vm}
}
struct GuestDesktop:View {
    let owner:String
    @ObservedObject var controller:GuestController
    var body:some View {
        GroupBox("Virtual desktop"){
            VStack(alignment:.leading){
                HStack {
                    Button("Boot installed guest"){Task {await controller.start(owner:owner,installer:nil)}}.disabled(controller.guest != nil)
                    Button("Boot installer…"){let p=NSOpenPanel();if p.runModal() == .OK,let url=p.url {Task {await controller.start(owner:owner,installer:url)}}}.disabled(controller.guest != nil)
                    Button("Shut down"){controller.shutdown()}.disabled(controller.guest==nil)
                }
                if let vm=controller.guest {GuestDisplay(vm:vm).frame(minHeight:300)}
                if let exchange=controller.exchange {
                    Button("Open guest handoff folder"){NSWorkspace.shared.open(exchange)}
                }
                Text(controller.message)
            }
        }
    }
}
