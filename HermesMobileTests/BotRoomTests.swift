import XCTest
@testable import HermesMobile

@MainActor final class BotRoomTests: XCTestCase {
    private let connection = BotConnection(id: UUID(), name: "Mac", address: URL(string: "https://mac.example")!, username: "u", password: "p")

    func testCapturedCommsResponsesDecodeTolerantly() throws {
        let value = try JSONDecoder().decode(BotJSON.self, from: Data(Self.liveFixture.utf8))
        XCTAssertTrue(BotRoomCapabilities(value["capabilities"]).enabled)
        let listed = try XCTUnwrap(value["list"]["rooms"].list?.first.flatMap(BotGroupRoom.init))
        let state = try XCTUnwrap(BotGroupRoom(value["state"]["room"]))
        XCTAssertEqual(listed, state)
        XCTAssertEqual(state.name, "Comms")
        XCTAssertEqual(state.members.map(\.profile), ["chief-of-staff", "inbox-triage"])
        XCTAssertFalse(BotRoomStatus(value["state"]["driver_status"]).working)
    }

    func testCapabilityGateRequiresDriverAndEveryReadMethod() {
        XCTAssertTrue(BotRoomCapabilities(RoomFixture.capabilities).enabled)
        XCTAssertFalse(BotRoomCapabilities(.object(["driver": .bool(false), "methods": .array(BotRoomRPC.methods.map(BotJSON.string))])).enabled)
        for missing in ["groups.list", "groups.state", "groups.log"] {
            XCTAssertFalse(BotRoomCapabilities(.object(["driver": .bool(true), "methods": .array(BotRoomRPC.methods.filter { $0 != missing }.map(BotJSON.string))])).enabled)
        }
        XCTAssertFalse(BotRoomCapabilities(.null).enabled)
    }

    func testReplayIgnoresDuplicateSequencesAndUnknownKindsAdvanceCursor() {
        var log = BotRoomLog(); log.begin(latest: 403)
        XCTAssertEqual(log.cursor, 203)
        XCTAssertEqual(log.earlierBoundary, 203)
        log.apply(RoomFixture.page([RoomFixture.event(204), RoomFixture.event(205, kind: "future.event")], cursor: 205))
        log.apply(RoomFixture.page([RoomFixture.event(204), RoomFixture.event(206, kind: "turn.settled")], cursor: 206))
        XCTAssertEqual(log.events.map(\.seq), [204])
        XCTAssertEqual(log.cursor, 206)
        XCTAssertEqual(BotRoomLog.windowStart(before: 203), 3)
        XCTAssertEqual(BotRoomLog.windowStart(before: 3), 0)
        XCTAssertEqual(BotRoomLog.windowStart(before: 0), 0)
        log.apply(RoomFixture.page([RoomFixture.event(3)], cursor: 3))
        XCTAssertEqual(log.cursor, 206, "Earlier pages cannot rewind live replay")
        XCTAssertEqual(log.events.map(\.seq), [3, 204])
    }

    func testMemberFallbackAndForeignAuthorityAndScopedIdentity() throws {
        let room = try XCTUnwrap(BotGroupRoom(RoomFixture.room(latest: 0)))
        let event = try XCTUnwrap(BotRoomEvent(RoomFixture.event(1, kind: "message.member")))
        XCTAssertEqual(event.sender(in: room), "chief-of-staff")
        XCTAssertTrue(room.isForeign(to: "other-install"))
        XCTAssertFalse(room.isForeign(to: "fixture-install"))
        let first = BotRoomKey(server: URL(string: "https://one.example")!, connectionID: connection.id, roomID: room.id)
        XCTAssertNotEqual(first, BotRoomKey(server: first.server, connectionID: UUID(), roomID: room.id))
        XCTAssertNotEqual(first, BotRoomKey(server: URL(string: "https://two.example")!, connectionID: connection.id, roomID: room.id))
    }

    func testOpenDrainsPagesAndEarlierWindowDoesNotSkipOrRewind() async {
        let wire = RoomWire(); wire.latest = 450
        let reader = makeReader(wire)
        await reader.open()
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(wire.logStarts, [250, 350])
        XCTAssertEqual(reader.events.first?.seq, 251)
        XCTAssertEqual(reader.events.last?.seq, 450)
        await reader.loadEarlier()
        XCTAssertEqual(Array(wire.logStarts.suffix(2)), [50, 150])
        XCTAssertEqual(reader.events.first?.seq, 51)
        XCTAssertEqual(reader.events.count, 400)
        await reader.loadEarlier()
        XCTAssertEqual(wire.logStarts.last, 0)
        XCTAssertFalse(reader.hasEarlier)
        XCTAssertEqual(reader.events.count, 450)
        wire.latest = 451
        await reader.poll()
        XCTAssertEqual(wire.logStarts.last, 450)
        XCTAssertEqual(reader.events.count, 451)
        reader.close()
        XCTAssertTrue(reader.events.isEmpty)
    }

    func testUnchangedPollDoesNotReadLogAndUnknownEventIsInvisible() async {
        let wire = RoomWire(); wire.latest = 1
        let reader = makeReader(wire)
        await reader.open()
        let before = reader.events
        await reader.poll()
        XCTAssertEqual(wire.logStarts.count, 1)
        XCTAssertEqual(reader.events, before)
        wire.kind = "room.activity"; wire.latest = 2
        await reader.poll()
        XCTAssertEqual(reader.events, before)
        await reader.poll()
        XCTAssertEqual(wire.logStarts, [0, 1], "Invisible activity still advances the read cursor")
        reader.close()
    }

    func testPollCompletingAfterCloseMutatesNothing() async {
        let wire = RoomWire(); let reader = makeReader(wire)
        await reader.open()
        let parked = expectation(description: "state parked")
        wire.holdState = true; wire.onHeld = { parked.fulfill() }
        let poll = Task { await reader.poll() }
        await fulfillment(of: [parked], timeout: 2)
        reader.close()
        wire.releaseState(latest: 50)
        await poll.value
        XCTAssertEqual(reader.link, .idle)
        XCTAssertTrue(reader.events.isEmpty)
        XCTAssertEqual(reader.room.latestSeq, 0)
        XCTAssertEqual(wire.logStarts, [0])
    }

    func testSocketLossStopsReadsAndReconnectUsesFreshSocket() async {
        let wire = RoomWire(); let next = RoomWire(); next.latest = 1
        var wires = [wire, next]
        let reader = BotRoomReader(key: key(), connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, makeWire: { _ in wires.removeFirst() })
        await reader.open()
        wire.onDisconnect?(BotFailure.transport)
        XCTAssertEqual(reader.link, .stopped)
        let reads = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, reads)
        await reader.open()
        XCTAssertEqual(reader.link, .live)
        XCTAssertEqual(reader.events.count, 1)
        XCTAssertGreaterThan(wire.closed, 0)
        reader.close()
    }

    func testExpiredAndWorkerErrorsHaveRequiredRecovery() async {
        for error in [BotRoomFailure(code: 4114, reason: nil), BotRoomFailure(code: 4112, reason: "room_history_expired")] {
            let wire = RoomWire(); var expired = false
            let reader = makeReader(wire, expired: { expired = true })
            await reader.open()
            wire.failure = error
            await reader.poll()
            XCTAssertTrue(expired)
            XCTAssertTrue(reader.events.isEmpty)
        }
        let wire = RoomWire(); let reader = makeReader(wire)
        wire.failure = BotRoomFailure(code: 4123, reason: nil)
        await reader.open()
        XCTAssertTrue(reader.errorMessage?.contains("Restart the Hermes gateway") == true)
        reader.close()
    }

    func testInboxGateSearchDisbandAndExpiredIdentityStayScoped() async throws {
        let wire = RoomWire()
        let store = BotConnectionStore(keychain: InMemoryKeychainStore())
        try store.save(connection, server: key().server)
        let inbox = BotInbox(server: key().server, store: store, makeWire: { _ in wire })
        await inbox.open()
        XCTAssertEqual(inbox.rooms(matching: "com").map(\.name), ["Comms"])
        XCTAssertTrue(inbox.rooms(matching: "unrelated").isEmpty)
        XCTAssertEqual(wire.stateCalls, 0, "Inbox never follows rooms")
        let roomKey = try XCTUnwrap(inbox.roomKey(inbox.rooms[0]))
        inbox.expireRoom(BotRoomKey(server: roomKey.server, connectionID: UUID(), roomID: roomKey.roomID))
        XCTAssertEqual(inbox.rooms.count, 1)
        inbox.expireRoom(roomKey)
        XCTAssertTrue(inbox.rooms.isEmpty)
        wire.capabilities = .object(["driver": .bool(false)])
        await inbox.open()
        XCTAssertTrue(inbox.rooms(matching: "Comms").isEmpty)
        XCTAssertFalse(inbox.roomCapabilities.enabled)
        XCTAssertEqual(wire.listCalls, 1, "A disabled driver must not list rooms")
        wire.capabilities = RoomFixture.capabilities; wire.disbanded = true
        await inbox.open()
        XCTAssertTrue(inbox.rooms.isEmpty)
        inbox.close()
    }

    func testForeignAuthorityShowsNoteAndAuthorityMoveRereadsState() async {
        let wire = RoomWire(); wire.authority = "another-install"
        let reader = makeReader(wire)
        await reader.open()
        XCTAssertTrue(reader.foreignAuthority)
        wire.latest = 1; wire.epoch = 2
        let reads = wire.stateCalls
        await reader.poll()
        XCTAssertEqual(wire.stateCalls, reads + 2)
        XCTAssertTrue(reader.foreignAuthority)
        reader.close()
    }

    func testStatusPollIntervalsAndMissingFields() {
        XCTAssertEqual(BotRoomStatus(.null).interval, .seconds(10))
        for flag in ["working", "blocked"] {
            XCTAssertEqual(BotRoomStatus(.object([flag: .bool(true)])).interval, .seconds(2))
        }
    }

    private func key() -> BotRoomKey { BotRoomKey(server: URL(string: "https://webui.example")!, connectionID: connection.id, roomID: "fixture-room") }
    private func makeReader(_ wire: RoomWire, expired: @escaping () -> Void = {}) -> BotRoomReader {
        BotRoomReader(key: key(), connection: connection, room: BotGroupRoom(RoomFixture.room(latest: 0))!, makeWire: { _ in wire }, onExpired: expired)
    }
}

/// Synthesized protocol fixtures. Live host fixtures are kept separately when available.
enum RoomFixture {
    static let capabilities = BotJSON.object(["driver": .bool(true), "methods": .array(BotRoomRPC.methods.map(BotJSON.string)),
        "authority_gateway_id": .string("fixture-install"), "max_log_limit": .number(100)])
    static func room(latest: Int) -> BotJSON {
        .object(["room_id": .string("fixture-room"), "name": .string("Comms"), "latest_seq": .number(Double(latest)),
            "authority_gateway_id": .string("fixture-install"), "authority_epoch": .number(1),
            "members": .array([.object(["member_id": .string("chief"), "profile": .string("chief-of-staff")])])])
    }
    static func event(_ seq: Int, kind: String = "message.user") -> BotJSON {
        .object(["room_id": .string("fixture-room"), "seq": .number(Double(seq)), "kind": .string(kind),
            "actor": .object(["id": .string("chief")]), "payload": .object(["text": .string("Message \(seq)")])])
    }
    static func page(_ events: [BotJSON], cursor: Int, more: Bool = false) -> BotJSON {
        .object(["events": .array(events), "cursor": .number(Double(cursor)), "has_more": .bool(more),
                 "authority": .object(["gateway_id": .string("fixture-install"), "epoch": .number(1)])])
    }
}

@MainActor final class RoomWire: BotTransport {
    var replayEpoch: String? = "epoch"
    var onEvent: ((BotJSON) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var latest = 0
    var capabilities = RoomFixture.capabilities
    var disbanded = false
    var listCalls = 0
    var authority = "fixture-install"
    var epoch = 1
    var logStarts: [Int] = []
    var stateCalls = 0
    var closed = 0
    var kind = "message.user"
    var failure: Error?
    var holdState = false
    var onHeld: (() -> Void)?
    private var held: CheckedContinuation<BotJSON, Never>?
    func connect() async throws {}
    func close() { closed += 1 }
    func call(_ method: String, _ params: [String: BotJSON], validateDispatch: (() throws -> Void)?) async throws -> BotJSON {
        try validateDispatch?()
        switch method {
        case "profiles.list": return .object(["profiles": .array([])])
        case "groups.capabilities": return capabilities
        case "groups.list":
            listCalls += 1
            var room = RoomFixture.room(latest: latest).fields!
            if disbanded { room["disbanded_at"] = .number(100) }
            return .object(["rooms": .array([.object(room)]), "next_offset": .null])
        case "groups.state":
            stateCalls += 1
            if let failure { throw failure }
            if holdState { return await withCheckedContinuation { held = $0; onHeld?() } }
            var room = RoomFixture.room(latest: latest).fields!
            room["authority_gateway_id"] = .string(authority); room["authority_epoch"] = .number(Double(epoch))
            return .object(["room": .object(room)])
        case "groups.log":
            let start = params["since_seq"]!.integer!; logStarts.append(start)
            let end = min(latest, start + params["limit"]!.integer!)
            let events = end > start ? ((start + 1)...end).map { RoomFixture.event($0, kind: kind) } : []
            var page = RoomFixture.page(events, cursor: end, more: end < latest).fields!
            page["authority"] = .object(["gateway_id": .string(authority), "epoch": .number(Double(epoch))])
            return .object(page)
        default: XCTFail("Unexpected room method: \(method)"); throw BotFailure.unsupported
        }
    }
    func releaseState(latest: Int) {
        held?.resume(returning: .object(["room": RoomFixture.room(latest: latest)])); held = nil
    }
}

private extension BotRoomTests {
    // Read-only tunnel capture, 2026-09-16, Hermes 0.21.2; install identity replaced.
    static let liveFixture = #"""
{
  "capabilities": {
    "protocol_version": 2,
    "driver": true,
    "persistent_process": true,
    "authority_gateway_id": "fixture-install",
    "room_link": {
      "enabled": true,
      "profile": "default",
      "catalog": {
        "installation_id": "fixture-install",
        "protocol_versions": [
          2
        ],
        "link_modes": [
          "direct"
        ],
        "persistent_process": true,
        "text": true,
        "attachments": false,
        "execution_policy": {
          "version": 1,
          "target_profile": "default",
          "enabled_toolsets": [
            "agentmail",
            "bot_room",
            "browser",
            "code_execution",
            "connections",
            "cronjob",
            "delegation",
            "file",
            "firecrawl",
            "image_gen",
            "memory",
            "session_search",
            "skills",
            "terminal",
            "todo",
            "vision",
            "web"
          ],
          "approval_mode": "manual",
          "max_iterations": 75,
          "policy_digest": "46af513ec7dbfd1a0f166c8a3c8d5a2a79543a8b55a105b447fdd21fb7c09605"
        },
        "endpoint": {
          "available": false,
          "reason": "not_configured"
        },
        "catalog_digest": "9bb855f5a5164a77d444b2ca9a4660e3a0e289978a7514139422dedc791d0b98"
      },
      "endpoint": {
        "available": false,
        "reason": "not_configured"
      }
    },
    "features": [
      "authority_epoch",
      "coordinator_fencing",
      "room_identity",
      "monotonic_log",
      "idempotent_send",
      "replayable_disband",
      "typed_events",
      "actor_identity",
      "log_replication",
      "authority_takeover"
    ],
    "methods": [
      "groups.capabilities",
      "groups.list",
      "groups.create",
      "groups.state",
      "groups.send",
      "groups.rename",
      "groups.log",
      "groups.disband",
      "groups.replicate",
      "groups.replica_state",
      "groups.promote",
      "groups.demote",
      "groups.stop",
      "groups.retry",
      "groups.approve",
      "groups.peer.invite",
      "groups.peer.revoke",
      "groups.peer.register"
    ],
    "max_log_limit": 500
  },
  "list": {
    "rooms": [
      {
        "room_id": "5ba46d7d-0364-409d-b5a8-a3f29e6d1ceb",
        "name": "Comms",
        "members": [
          {
            "display_name": "chief-of-staff",
            "handle": "chief-of-staff",
            "member_id": "chief-of-staff",
            "profile": "chief-of-staff",
            "target": {
              "kind": "local",
              "profile": "chief-of-staff"
            }
          },
          {
            "display_name": "inbox-triage",
            "handle": "inbox-triage",
            "member_id": "inbox-triage",
            "profile": "inbox-triage",
            "target": {
              "kind": "local",
              "profile": "inbox-triage"
            }
          }
        ],
        "authority_gateway_id": "fixture-install",
        "authority_epoch": 1,
        "revision": 1,
        "created_at": 1789433946.8950279,
        "updated_at": 1789433946.8950279,
        "idempotent": false,
        "latest_seq": 0
      }
    ],
    "next_offset": null
  },
  "state": {
    "room": {
      "room_id": "5ba46d7d-0364-409d-b5a8-a3f29e6d1ceb",
      "name": "Comms",
      "members": [
        {
          "display_name": "chief-of-staff",
          "handle": "chief-of-staff",
          "member_id": "chief-of-staff",
          "profile": "chief-of-staff",
          "target": {
            "kind": "local",
            "profile": "chief-of-staff"
          }
        },
        {
          "display_name": "inbox-triage",
          "handle": "inbox-triage",
          "member_id": "inbox-triage",
          "profile": "inbox-triage",
          "target": {
            "kind": "local",
            "profile": "inbox-triage"
          }
        }
      ],
      "authority_gateway_id": "fixture-install",
      "authority_epoch": 1,
      "revision": 1,
      "created_at": 1789433946.8950279,
      "updated_at": 1789433946.8950279,
      "idempotent": false,
      "latest_seq": 0
    },
    "driver_status": {
      "running": true,
      "working": false,
      "blocked": false,
      "counts": {},
      "pending_actions": [],
      "peer_routes": []
    }
  }
}
"""#
}
