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

guard let device = MTLCreateSystemDefaultDevice() else {
    plog("no Metal device")
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // the menu bar only, no Dock icon
let controller = MainActor.assumeIsolated { AppController(device: device) }
MainActor.assumeIsolated { controller.start() }
app.run()
