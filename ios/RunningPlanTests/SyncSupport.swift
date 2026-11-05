import APIClient
import Foundation
import Testing
@testable import RunningPlan

typealias Detail = Components.Schemas.PlanDetail
typealias Sess = Components.Schemas.Session

let syncSession = "00000000-0000-4000-8000-000000000017"
let otherSession = "00000000-0000-4000-8000-000000000018"
let thirdSession = "00000000-0000-4000-8000-000000000019"

func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try APIConfiguration.decoder.decode(type, from: Data(json.utf8))
}

func sessionJSON(
    _ id: String = syncSession, revision: Int = 2, title: String = "Theirs", planId: String = PlanFixture.planID,
    deleted: Bool = false, status: String = "planned", owner: String = "user"
) -> String {
    #"{"id":"\#(id)","planId":"\#(planId)","revision":\#(revision),"updatedAt":"2026-10-28T08:00:00.000Z","deletedAt":\#(deleted ? #""2026-10-28T08:00:00.000Z""# : "null"),"date":"2026-10-28","type":"intervals","title":"\#(title)","status":"\#(status)","owner":"\#(owner)","steps":[]}"#
}

func planJSON(revision: Int = 4, deleted: Bool = false) throws -> String {
    var object = try #require(try JSONSerialization.jsonObject(with: PlanFixture.json()) as? [String: Any])
    object["sessions"] = nil
    object["warnings"] = nil
    object["revision"] = revision
    object["contentRevision"] = revision
    if deleted { object["deletedAt"] = "2026-10-28T09:00:00.000Z" }
    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

func result(_ key: String, _ status: String, revision: Int? = nil, server: String? = nil) -> String {
    var fields = [#""idempotencyKey":"\#(key)""#, #""status":"\#(status)""#]
    if let revision { fields.append(#""revision":\#(revision)"#) }
    if let server { fields.append(#""server":\#(server)"#) }
    return "{" + fields.joined(separator: ",") + "}"
}

func response(
    results: [String] = [], sessions: [String] = [], plans: [String] = [], proposals: [String] = [], hasMore: Bool = false, cursor: String = "c1"
) throws -> Components.Schemas.SyncResponse {
    try decode(Components.Schemas.SyncResponse.self, #"{"results":[\#(results.joined(separator: ","))],"changes":{"plans":[\#(plans.joined(separator: ","))],"sessions":[\#(sessions.joined(separator: ","))],"checkins":[],"proposals":[\#(proposals.joined(separator: ","))]},"cursor":"\#(cursor)","hasMore":\#(hasMore)}"#)
}

func localSession(_ plan: Detail?, _ id: String = syncSession) -> Sess? {
    plan?.value2.sessions.first { $0.value1.id == id }
}

/// Scripted server: `handler` answers each request.
final class FakeSyncService: SyncServing, @unchecked Sendable {
    typealias Handler = @Sendable (String?, [SyncOp]) throws -> Components.Schemas.SyncResponse
    private let lock = NSLock()
    private var log: [(cursor: String?, ops: [SyncOp])] = []
    var handler: Handler

    init(_ handler: @escaping Handler = { _, _ in try response() }) { self.handler = handler }

    var calls: [(cursor: String?, ops: [SyncOp])] { lock.withLock { log } }

    func sync(cursor: String?, operations: [SyncOp]) async throws -> Components.Schemas.SyncResponse {
        lock.withLock { log.append((cursor, operations)) }
        return try handler(cursor, operations)
    }
}

@MainActor
final class PlanBox {
    var plan: Detail?
    var cleared = false
    init(_ plan: Detail?) { self.plan = plan }
}

@MainActor
func makeSync(
    plan: Detail? = try? PlanFixture.detail(), store: OfflineStoring = MemoryOfflineStore(), service: FakeSyncService = FakeSyncService()
) -> (sync: OfflineSync, box: PlanBox, service: FakeSyncService) {
    let box = PlanBox(plan)
    let sync = OfflineSync(store: store, service: service, scope: { "test|user" })
    sync.read = { box.plan }
    sync.write = { box.plan = $0 }
    sync.clear = {
        box.plan = nil
        box.cleared = true
    }
    return (sync, box, service)
}
