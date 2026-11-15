import Darwin
import Foundation

/// Reads the glasses' motion stream (TCP 52998) on its own thread and hands each sample to [onSample]. Reconnects
/// after a loss, waiting 1 s, then up to 8 s between tries. Nothing is ever sent on this link.
public final class ImuReader: @unchecked Sendable {
    private let onSample: @Sendable (ImuSample) -> Void
    private let framer = ImuFramer()
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false
    private var _connectedVia: String?
    public private(set) var samples = 0

    /// How the stream is reached now ("en7 (169.254.2.10 -> 169.254.2.1)"), nil while not connected.
    public var connectedVia: String? { lock.lock(); defer { lock.unlock() }; return _connectedVia }

    public init(onSample: @escaping @Sendable (ImuSample) -> Void) {
        self.onSample = onSample
    }

    public func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "Pocket XR head tracking"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func run() {
        var delay = 1.0
        var buf = [UInt8](repeating: 0, count: 65536)
        var quietLogged = false
        while !isStopped {
            let fd: Int32, via: String
            do {
                let opened = try GlassesNet.open(port: ImuFramer.port) { line in
                    if !quietLogged { plog(line); quietLogged = true }
                }
                fd = opened.0
                via = opened.1
            } catch {
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 8)
                continue
            }
            quietLogged = false
            delay = 1
            lock.lock(); _connectedVia = via; lock.unlock()
            plog("head tracking: reading 52998 via \(via)")
            var lastData = Date()
            while !isStopped {
                guard let chunk = GlassesNet.receive(fd, &buf) else {
                    plog("head tracking: the glasses closed the stream")
                    break
                }
                if chunk.isEmpty {
                    if Date().timeIntervalSince(lastData) > 3 {
                        plog("head tracking: no data for 3 s; reconnecting")
                        break
                    }
                    continue
                }
                lastData = Date()
                for s in framer.feed(chunk) {
                    samples += 1
                    onSample(s)
                }
            }
            close(fd)
            lock.lock(); _connectedVia = nil; lock.unlock()
        }
    }
}

/// One open control link (TCP 52999): a heartbeat every 50 ms, as Pocket XR does, and request() waits for its answer.
/// Ported from the Deck's control.Link.
public final class ControlLink: @unchecked Sendable {
    private let fd: Int32
    public let via: String
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    private var counter = 0
    private var answers = [UInt32: ControlWire.Answer]()
    private var _closed = false
    private let framer = ControlWire.Framer()

    public var closed: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _closed }

    public init() throws {
        let opened = try GlassesNet.open(port: ControlWire.port) { plog($0) }
        fd = opened.0
        via = opened.1
        let reader = Thread { [weak self] in self?.readLoop() }
        reader.name = "Pocket XR control link"
        reader.start()
        let beat = Thread { [weak self] in self?.beatLoop() }
        beat.name = "Pocket XR heartbeat"
        beat.start()
    }

    private func send(_ bytes: [UInt8]) throws {
        sendLock.lock(); defer { sendLock.unlock() }
        try GlassesNet.send(fd, bytes)
    }

    private func beatLoop() {
        while !closed {
            do { try send(ControlWire.heartbeatFrame(DispatchTime.now().uptimeNanoseconds)) } catch { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while !closed {
            guard let chunk = GlassesNet.receive(fd, &buf) else { break }
            if chunk.isEmpty { continue }
            let got = framer.feed(chunk)
            stateLock.lock()
            for a in got { answers[a.id & 0x7FFF_FFFF] = a }
            stateLock.unlock()
        }
        stateLock.lock(); _closed = true; stateLock.unlock()
    }

    /// Sends the frame built for a new request id and waits up to [wait] seconds for its answer.
    @discardableResult
    public func request(_ what: String, wait: Double = 3, _ build: (UInt32) throws -> [UInt8]) throws -> ControlWire.Answer? {
        stateLock.lock()
        let id = ControlWire.rpcId(counter)
        counter += 1
        stateLock.unlock()
        let frame = try build(id)
        let type = Int(frame[0]) << 8 | Int(frame[1])
        try send(frame)
        let end = Date().addingTimeInterval(wait)
        while Date() < end && !closed {
            stateLock.lock()
            let a = answers.removeValue(forKey: id & 0x7FFF_FFFF)
            stateLock.unlock()
            if let a {
                // Sets and refusals are logged; plain reads only when they fail, to keep the log readable.
                if ControlWire.sets.contains(type) || a.result != 0 {
                    plog("  \(what) (\(type)) -> result \(a.result) value \(a.value.map { "\($0)" } ?? "none")")
                }
                return a
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        plog("  \(what) (\(type)) -> no answer")
        return nil
    }

    /// An empty read.
    public func get(_ type: Int, wait: Double = 3) -> ControlWire.Answer? {
        (try? request("read", wait: wait) { try ControlWire.rpc(type, $0) }) ?? nil
    }

    public func close() {
        stateLock.lock(); _closed = true; stateLock.unlock()
        Darwin.close(fd)
    }
}
