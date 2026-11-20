import Foundation
import PocketXRCore

/// Finds Apollo and Sunshine hosts on the local network by their `_nvstream._tcp` mDNS service, as Moonlight does,
/// so nobody types an address. Every Apollo instance on a PC is its own entry, by its own port. Runs on the main
/// thread (NetServiceBrowser needs its run loop); the answer comes once, after [seconds].
@MainActor
final class PcFinder: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving = [NetService]()
    private var found = [PcHost]()
    private var done: (([PcHost]) -> Void)?

    func look(seconds: Double, then: @escaping ([PcHost]) -> Void) {
        done = then
        browser.delegate = self
        browser.searchForServices(ofType: "_nvstream._tcp.", inDomain: "local.")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self else { return }
            self.browser.stop()
            self.resolving.forEach { $0.stop() }
            let hosts = self.found
            self.done?(hosts)
            self.done = nil
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 3)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard let address = Self.ipv4(sender.addresses ?? []), sender.port > 0 else { return }
            let host = PcHost(name: sender.name, address: address, port: sender.port)
            if !found.contains(where: { $0.address == host.address && $0.port == host.port }) {
                found.append(host)
                plog("PC screens: found \(host.name) at \(host.moonlightAddress)")
            }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        plog("PC screens: could not resolve \(sender.name)")
    }

    /// The first IPv4 address among [addresses] (sockaddr data).
    private static func ipv4(_ addresses: [Data]) -> String? {
        for data in addresses {
            let text: String? = data.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var a = raw.loadUnaligned(as: sockaddr_in.self)
                guard Int32(a.sin_family) == AF_INET else { return nil }
                var out = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &a.sin_addr, &out, socklen_t(INET_ADDRSTRLEN))
                return String(cString: out)
            }
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    /// The host's own name from its serverinfo over plain HTTP ("MIKE screen 2" for an extra Apollo), or nil.
    /// Also says whether anything answers there. Blocking.
    nonisolated static func serverName(_ host: PcHost) -> String? {
        guard let url = URL(string: "http://\(host.address):\(host.port)/serverinfo") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let gate = DispatchSemaphore(value: 0)
        var name: String?
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { gate.signal() }
            guard let data, let xml = String(data: data, encoding: .utf8),
                  let r = xml.range(of: #"<hostname>[^<]+</hostname>"#, options: .regularExpression) else { return }
            name = String(xml[r]).replacingOccurrences(of: "<hostname>", with: "").replacingOccurrences(of: "</hostname>", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        task.resume()
        if gate.wait(timeout: .now() + 3) == .timedOut { task.cancel() }
        return name
    }
}
