import Foundation

func pcScreenChecks() {
    // Wake-on-LAN: the MAC as the phone reads it (all zeros is none), and "Wake for network access" from pmset.
    check(WakeInfo.macText([0xA4, 0x83, 0xE7, 0x12, 0x34, 0x56]) == "a4:83:e7:12:34:56", "a MAC address as text")
    check(WakeInfo.macText([0, 0, 0, 0, 0, 0]) == nil && WakeInfo.macText([1, 2, 3]) == nil, "all zeros or short: none")
    // As the Air's own `pmset -g custom` prints it (20 Nov 2026): womp 0 on battery, 1 on the adapter.
    let laptop = "Battery Power:\n Sleep On Power Button 1\n womp                 0\n sleep                1\nAC Power:\n womp                 1\n sleep                1\n"
    check(WakeInfo.networkWake(pmsetCustom: laptop) == .onAdapter, "a laptop: womp under AC Power, not on battery")
    let both = laptop.replacingOccurrences(of: " womp                 0", with: " womp                 1")
    check(WakeInfo.networkWake(pmsetCustom: both) == .on, "a laptop with womp on battery too: on")
    check(WakeInfo.hint(.onAdapter).contains("power adapter"), "the laptop hint says on the adapter")
    let off = laptop.replacingOccurrences(of: "AC Power:\n womp                 1", with: "AC Power:\n womp                 0")
    check(WakeInfo.networkWake(pmsetCustom: off) == .off, "womp 0 on AC: off")
    check(WakeInfo.networkWake(pmsetCustom: "AC Power:\n womp 1\n") == .on, "a desktop: one section")
    check(WakeInfo.networkWake(pmsetCustom: "nothing here") == .unknown, "no womp line: unknown")
    check(WakeInfo.hint(.off).contains("Wake for network access"), "the hint names the setting")
    // Addresses.
    check(PcHostAddress.parse(" 192.168.1.20 ")! == ("192.168.1.20", 47989), "a bare address takes the usual port")
    check(PcHostAddress.parse("192.168.1.20:48989")! == ("192.168.1.20", 48989), "address and port")
    check(PcHostAddress.parse("pc.local:49989")! == ("pc.local", 49989), "a name and port")
    check(PcHostAddress.parse("") == nil && PcHostAddress.parse(":48989") == nil, "no host")
    check(PcHostAddress.parse("pc:0") == nil && PcHostAddress.parse("pc:x") == nil && PcHostAddress.parse("a:1:2") == nil, "bad ports")
    check(PcHost(name: "M", address: "10.0.0.2", port: 47989).moonlightAddress == "10.0.0.2", "the usual port is left out")
    check(PcHost(name: "M", address: "10.0.0.2", port: 48989).moonlightAddress == "10.0.0.2:48989", "another port is given")

    // PCs and their Apollos.
    check(PcScreenPick.pcName("Mike(2)") == "Mike", "mDNS numbering taken off")
    check(PcScreenPick.pcName("MIKE screen 3") == "MIKE", "an instance's own name")
    check(PcScreenPick.pcName("Den") == "Den", "a plain name")
    let mike = [PcHost(name: "Mike(3)", address: "10.0.0.5", port: 49989), PcHost(name: "Mike(2)", address: "10.0.0.5", port: 48989),
                PcHost(name: "Mike", address: "10.0.0.5", port: 47989), PcHost(name: "Den", address: "10.0.0.9", port: 47989),
                PcHost(name: "Mike", address: "10.0.0.5", port: 47989)]
    let pcs = PcScreenPick.byPc(mike)
    check(pcs.count == 2 && pcs[0].name == "Mike" && pcs[1].name == "Den", "grouped by address, named by the main one: \(pcs.map(\.name))")
    check(pcs[0].instances.map(\.port) == [47989, 48989, 49989], "each Apollo once, by port")
    let inst = pcs[0].instances
    check(PcScreenPick.next(of: inst, used: [])?.port == 47989, "the first PC screen takes the main Apollo")
    check(PcScreenPick.next(of: inst, used: ["10.0.0.5"])?.port == 48989, "the second the next one")
    check(PcScreenPick.next(of: inst, used: ["10.0.0.5", "10.0.0.5:48989"])?.port == 49989, "the third the last")
    check(PcScreenPick.next(of: inst, used: ["10.0.0.5", "10.0.0.5:48989", "10.0.0.5:49989"]) == nil, "never two on one Apollo")
    check(PcScreenPick.next(of: inst, used: ["10.0.0.5:48989"])?.port == 47989, "a gap is filled")

    // The PC helper.
    check(PcHelperWire.parseHere("POCKETXR-HERE 1 47610 MIKE-PC\n")! == (47610, "MIKE-PC"), "the helper's answer")
    check(PcHelperWire.parseHere("POCKETXR-HERE 1 47610 Mike's PC")?.name == "Mike's PC", "a name with spaces")
    check(PcHelperWire.parseHere("POCKETXR-HERE 1 x PC") == nil && PcHelperWire.parseHere("HELLO 1 2 3") == nil, "anything else")
    let line = PcHelperWire.request([("op", "apollo-pin"), ("token", "t\"1"), ("pin", "0042"), ("port", 48989)])
    check(line == #"{"op":"apollo-pin","token":"t\"1","pin":"0042","port":48989}"#, "a request line: \(line)")
    let withVirtual = PcHelperWire.request([("port", 48989), ("virtual", true)])
    check(withVirtual == #"{"port":48989,"virtual":true}"#, "a Bool is true, not 1: \(withVirtual)")
    let parsed = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    check(parsed?["token"] as? String == "t\"1" && parsed?["port"] as? Int == 48989, "it is JSON")

    // Moonlight.
    var g = SystemRandomNumberGenerator()
    let pins = (0..<200).map { _ in MoonlightCommand.pin(using: &g) }
    check(pins.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isNumber) }, "PINs are four digits")
    let h = PcHost(name: "Mike", address: "10.0.0.5", port: 48989)
    check(MoonlightCommand.pair(h, pin: "0042") == ["pair", "10.0.0.5:48989", "--pin", "0042"], "pair")
    let s = MoonlightCommand.stream(h, app: "Virtual Display", width: 1920, height: 1080, fps: 60)
    check(Array(s.prefix(3)) == ["stream", "10.0.0.5:48989", "Virtual Display"], "stream: host, then the app")
    check(s.contains("1920x1080") && s.contains("borderless") && s.contains("--absolute-mouse"), "stream options: \(s)")
    let csv = "Name, ID, HDR Support\n\"Virtual Display\", 123, false\nDesktop, 1, false\nSteam Big Picture, 2, false\n"
    check(MoonlightCommand.appNames(fromList: csv) == ["Virtual Display", "Desktop", "Steam Big Picture"], "apps from a list")
    check(MoonlightCommand.app(fromList: csv) == "Virtual Display", "Apollo's virtual display first")
    check(MoonlightCommand.app(fromList: "Desktop,1\nSteam Big Picture,2") == "Desktop", "then Desktop")
    check(MoonlightCommand.app(fromList: "Steam Big Picture,2") == "Steam Big Picture", "then the first")
    check(MoonlightCommand.app(fromList: "Computer 10.0.0.5 has not been paired. Please open Moonlight to pair before streaming.") == nil, "a message is no app")
}
