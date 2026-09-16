import Foundation
import Observation

/// One visible room owns one read-only socket. Closing invalidates replies before
/// cancelling transport; backgrounding keeps the loaded window but stops all reads.
@MainActor @Observable final class BotRoomReader {
    enum Link: Equatable { case idle, connecting, live, stopped }
    let key: BotRoomKey
    let connection: BotConnection
    private(set) var room: BotGroupRoom
    private(set) var events: [BotRoomEvent] = []
    private(set) var status = BotRoomStatus(.null)
    private(set) var link = Link.idle
    private(set) var errorMessage: String?
    private(set) var hasEarlier = false
    private(set) var loadingEarlier = false
    private(set) var foreignAuthority = false
    @ObservationIgnored private var log = BotRoomLog()
    @ObservationIgnored private var wire: (any BotTransport)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var capabilities = BotRoomCapabilities(.null)
    @ObservationIgnored private var lastAuthority: BotJSON?
    @ObservationIgnored private let makeWire: @MainActor (BotConnection) -> any BotTransport
    @ObservationIgnored private let onExpired: () -> Void

    init(key: BotRoomKey, connection: BotConnection, room: BotGroupRoom,
         makeWire: (@MainActor (BotConnection) -> any BotTransport)? = nil,
         onExpired: @escaping () -> Void = {}) {
        self.key = key; self.connection = connection; self.room = room
        self.makeWire = makeWire ?? { BotClient(connection: $0) }; self.onExpired = onExpired
    }

    func open() async {
        suspend()
        let client = makeWire(connection)
        wire = client; link = .connecting; errorMessage = nil
        client.onDisconnect = { [weak self] error in
            guard let self, self.wire === client else { return }
            self.fail(error, client)
        }
        do {
            try await client.connect()
            try check(client)
            let value = try await client.call("groups.capabilities", [:])
            try check(client)
            capabilities = BotRoomCapabilities(value)
            guard capabilities.enabled else { throw BotFailure.unsupported }
            let latest = try await readState(client)
            // Re-open from current server state, never from cached member sessions.
            var initial = BotRoomLog(); initial.begin(latest: latest)
            let pages = try await readPages(client, since: initial.cursor)
            try check(client)
            for page in pages { initial.apply(page) }
            log = initial; publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
            try check(client)
            link = .live
            pollTask = Task { [weak self] in
                while let self, self.wire === client, !Task.isCancelled {
                    do { try await Task.sleep(for: self.status.interval) } catch { return }
                    guard self.wire === client, !Task.isCancelled else { return }
                    await self.poll()
                }
            }
        } catch { fail(error, client) }
    }

    /// Independently callable for scripted tests; the timer only schedules reads.
    func poll() async {
        guard let client = wire, link == .live else { return }
        do {
            let latest = try await readState(client)
            guard latest > log.cursor else { return }
            let pages = try await readPages(client, since: log.cursor)
            try check(client)
            for page in pages { log.apply(page) }
            publishLog()
            if try observeAuthority(pages.last, client) { _ = try await readState(client) }
        } catch { fail(error, client) }
    }

    func loadEarlier() async {
        guard let client = wire, link == .live, hasEarlier, !loadingEarlier else { return }
        loadingEarlier = true
        let boundary = log.earlierBoundary
        let start = BotRoomLog.windowStart(before: boundary)
        do {
            let pages = try await readPages(client, since: start, through: boundary)
            try check(client)
            for page in pages { log.apply(page) }
            log.loadedEarlier(from: start); publishLog(); loadingEarlier = false
        } catch { fail(error, client) }
    }

    func suspend() {
        let old = wire; wire = nil
        pollTask?.cancel(); pollTask = nil
        old?.onDisconnect = nil; old?.onEvent = nil
        old?.close(); loadingEarlier = false; link = .idle
    }

    func close() {
        suspend(); log = BotRoomLog(); events = []; hasEarlier = false
        status = BotRoomStatus(.null); lastAuthority = nil
    }

    private func check(_ client: any BotTransport) throws {
        guard wire === client, !Task.isCancelled else { throw BotFailure.stale }
    }

    private func readState(_ client: any BotTransport) async throws -> Int {
        let value = try await client.call("groups.state", ["room_id": .string(key.roomID)])
        try check(client)
        guard let updated = BotGroupRoom(value["room"]), updated.id == key.roomID else { throw BotFailure.unsupported }
        if updated.disbanded { throw BotRoomFailure(code: 4114, reason: nil) }
        if room != updated { room = updated }
        let nextStatus = BotRoomStatus(value["driver_status"])
        if status != nextStatus { status = nextStatus }
        let foreign = updated.isForeign(to: capabilities.authority)
        if foreignAuthority != foreign { foreignAuthority = foreign }
        return updated.latestSeq
    }

    /// History windows stop at their old boundary. Live/open replay drains all
    /// pages, including pages containing only unknown kinds. Reject stalled cursors.
    private func readPages(_ client: any BotTransport, since: Int, through: Int? = nil) async throws -> [BotJSON] {
        var cursor = since
        var pages: [BotJSON] = []
        while true {
            let limit = min(capabilities.pageLimit, through.map { max(1, $0 - cursor) } ?? capabilities.pageLimit)
            let page = try await client.call("groups.log", ["room_id": .string(key.roomID),
                "since_seq": .number(Double(cursor)), "limit": .number(Double(limit))])
            try check(client)
            guard page["events"].list != nil, let next = page["cursor"].integer, next >= cursor,
                  let more = page["has_more"].flag else { throw BotFailure.unsupported }
            pages.append(page)
            if !more || through.map({ next >= $0 }) == true { break }
            guard next > cursor else { throw BotFailure.unsupported }
            cursor = next
        }
        return pages
    }

    private func observeAuthority(_ page: BotJSON?, _ client: any BotTransport) throws -> Bool {
        try check(client)
        guard let authority = page?["authority"], authority != .null else { return false }
        let moved = lastAuthority != nil && lastAuthority != authority
        lastAuthority = authority
        if let owner = authority["gateway_id"].text, let local = capabilities.authority, owner != local {
            foreignAuthority = true
        }
        return moved
    }

    private func publishLog() {
        if events != log.events { events = log.events }
        hasEarlier = log.earlierBoundary > 0
    }

    private func fail(_ error: Error, _ client: any BotTransport) {
        guard wire === client else { return }
        suspend(); link = .stopped
        errorMessage = error.localizedDescription
        if let failure = error as? BotRoomFailure, failure.expired { close(); onExpired() }
    }
}
