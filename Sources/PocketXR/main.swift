import AppKit
import Metal
import PocketXRCore

// Pocket XR for Mac.
//
//   Pocket XR.app            the menu bar app
//   PocketXR --imu-test      head tracking alone, in Terminal: the glasses found, the link used, yaw and pitch 10 times
//                            a second (step 3 of docs/PLAN.md's test plan)
//   PocketXR --usb           the USB devices and the glasses found, then quits

let args = CommandLine.arguments

if args.contains("--usb") {
    let list = UsbDevices.list()
    for d in list { print(String(format: "%04X:%04X  %@  classes %@", d.vendor, d.product, d.name,
                                 d.interfaceClasses.map { String(format: "%02X", $0) }.joined(separator: ","))) }
    print("glasses: \(Glasses.detect(list)?.name ?? "none")")
    print("glasses links: \(GlassesNet.routes().map(\.description))")
    print("interfaces: \(GlassesNet.describeInterfaces())")
    exit(0)
}

// PocketXR --hid-list [all]   the glasses' HID devices (XREAL and VITURE; "all": every one) with their USB interface
//                             numbers, and Input Monitoring; nothing is written to any device
if args.contains("--hid-list") {
    let vendors = args.contains("all") ? [0] : [Glasses.xreal, Glasses.viture]
    for v in vendors { for line in HidImuReader.list(vendor: v) { print(line) } }
    print("Input Monitoring: \(HidImuReader.inputMonitoring())")
    exit(0)
}

if args.contains("--imu-test") {
    Log.shared.echo = true
    let g = Glasses.detect(UsbDevices.list())
    print("glasses: \(g?.name ?? "none found on USB; trying the stream anyway, as an Aura")")
    let fusion = HeadFusion(axes: g?.axes ?? .aura)
    let reader = ImuReader { fusion.report($0) }
    reader.start()
    var lastCount = 0
    while true {
        Thread.sleep(forTimeInterval: 0.1)
        let v = fusion.view()
        let f = v.rotate(SIMD3(0, 0, -1))
        let yaw = atan2(-f.x, -f.z) * 180 / .pi
        let pitch = asin(max(-1, min(1, f.y))) * 180 / .pi
        let rate = (fusion.count - lastCount) * 10
        lastCount = fusion.count
        print(String(format: "yaw %7.1f  pitch %6.1f  %4d Hz  bias %@  via %@", yaw, pitch, rate,
                     fusion.biasReady ? "learnt" : "learning", reader.connectedVia ?? "not connected"))
    }
}

// PocketXR --render-ui <folder>   every tour step and settings pane as PNG files, without showing a window (to
//                                 review the design; no glasses and no permission needed)
if let i = args.firstIndex(of: "--render-ui"), i + 1 < args.count {
    // The glasses' picture is drawn by Metal shaders compiled when the app runs, so a mistake in them shows only
    // then: compile them here too.
    if let d = MTLCreateSystemDefaultDevice() {
        do {
            _ = try d.makeLibrary(source: Renderer.shaderSource, options: nil)
            print("shaders: compiled")
        } catch {
            print("shaders: FAILED\n\(error)")
            exit(1)
        }
    }
    let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    _ = NSApplication.shared
    let files = MainActor.assumeIsolated { ControlPanelRender.renderAll(to: folder) + LauncherRender.renderAll(to: folder) + ControllerRender.renderAll(to: folder) + HandsRender.renderAll(to: folder) + TourRender.renderAll(to: folder) + SettingsRender.renderAll(to: folder) }
    for f in files { print(f.path) }
    print("rendered \(files.count) pictures")
    exit(0)
}

// PocketXR --host [--seconds N]   this Mac as the PC end of the phone's PC screens alone, in the foreground (tests),
//                                 logging to the usual log and Terminal
// PocketXR --host-pin NNNN        gives a running host the PIN a pairing phone shows
if let i = args.firstIndex(of: "--host-pin") {
    let pin = i + 1 < args.count ? args[i + 1] : ""
    guard pin.count == 4, pin.allSatisfy(\.isNumber) else { print("The PIN is four digits."); exit(2) }
    try? FileManager.default.createDirectory(at: HostIdentity.folder, withIntermediateDirectories: true)
    try? Data(pin.utf8).write(to: HostPins.file)
    exit(0)
}
if args.contains("--host") {
    Log.shared.echo = true
    _ = NSApplication.shared
    let service = HostService()
    service.start()
    if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let s = Double(args[i + 1]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { service.stop(); exit(0) }
    }
    signal(SIGTERM) { _ in exit(0) }
    RunLoop.main.run()
}

guard let device = MTLCreateSystemDefaultDevice() else {
    plog("no Metal device")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // the menu bar only, no Dock icon
let controller = MainActor.assumeIsolated { AppController(device: device) }
MainActor.assumeIsolated { controller.start() }
app.run()
