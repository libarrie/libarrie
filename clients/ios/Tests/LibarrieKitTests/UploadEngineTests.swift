import Foundation
import Testing
import UniformTypeIdentifiers
@testable import LibarrieKit

let server = URL(string: "http://localhost:8080")!

/// One test world: a capture store, the fake server and the engine.
struct World {
    let clock = Clock()
    let fake: FakeServer
    let store: CaptureStore
    let transfers = FakeTransfers()
    let engine: UploadEngine
    let batch = UUID()

    init(account: String = "account-1", tokens: AccessTokenProvider = StaticTokens(), integrity: String = "sha256") throws {
        fake = FakeServer(clock: clock)
        let clock = self.clock
        store = try CaptureStore(directory: temporaryDirectory(), now: { clock.now })
        let api = APIClient(baseURL: server, transport: fake.transport, tokens: tokens)
        engine = UploadEngine(api: api, store: store, transfers: transfers, accountId: account, serverURL: server,
                              policy: .init(integrity: integrity), now: { clock.now })
    }

    /// Capture `count` photos for notebook N1 from `firstPage`, ready to upload.
    @discardableResult
    func queue(_ count: Int, firstPage: Int = 1, account: String = "account-1") async throws -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            let image = try ImagePreparer().prepare(photo(.jpeg, width: 64, height: 48, gps: false))
            let item = try await store.capture(image, batchId: batch, sequence: index, accountId: account, serverURL: server)
            try await store.update(item.id) {
                $0.notebookId = "n1"; $0.notebookName = "Work"; $0.pageNumber = firstPage + index; $0.state = .ready
            }
            ids.append(item.id)
        }
        return ids
    }

    func item(_ id: UUID) async -> CaptureItem { await store.item(id)! }

    /// Run, deliver transfers, run again: what one foreground session does.
    func settle() async {
        await engine.run()
        await transfers.finishAll(server: fake, engine: engine)
        await engine.run()
    }

    func later(_ seconds: TimeInterval = 3600) { clock.advance(seconds) }
}

@Suite struct UploadEngineTests {
    @Test func uploadsThenRemovesThePhotoOnceBackupIsVerified() async throws {
        let world = try World()
        let ids = try await world.queue(2)
        await world.engine.run()
        #expect(await world.item(ids[0]).state == .uploading)
        let started = await world.transfers.started
        #expect(started.count == 2)
        #expect(started[0].1.value(forHTTPHeaderField: "x-amz-checksum-sha256") == "abc")
        #expect(started[0].1.httpMethod == "PUT")
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        let accepted = await world.item(ids[0])
        #expect(accepted.state == .serverAccepted)
        #expect(accepted.backup == .pending)
        #expect(!accepted.localFileRemoved)
        // Kept until the independent backup is verified.
        world.fake.backup[accepted.pageId!] = "verified"
        world.later(16 * 60)
        await world.engine.run()
        let verified = await world.item(ids[0])
        #expect(verified.backup == .verified)
        #expect(verified.localFileRemoved)
        #expect(await world.store.fileURL(for: verified).map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    @Test func aLostReservationResponseIsReplayedNotDuplicated() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        world.fake.fault("POST /v1/upload-sessions", .dropResponse)
        await world.engine.run()
        let waiting = await world.item(id)
        #expect(waiting.state == .retryableError)
        #expect(waiting.resumePoint == .reserve)
        world.later()
        await world.settle()
        #expect(await world.item(id).state == .serverAccepted)
        #expect(world.fake.ops.count == 1)
        #expect(world.fake.processingAllowance == 99)
        #expect(world.fake.ops[waiting.operationId] != nil)
    }

    @Test func aLostCompletionResponseIsRetriedIdempotently() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        world.fake.fault("POST /v1/upload-sessions/{id}/complete", .dropResponse)
        await world.engine.run()
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        #expect(await world.item(id).resumePoint == .confirm)
        world.later()
        await world.engine.run()
        #expect(await world.item(id).state == .serverAccepted)
        #expect(world.fake.ops.count == 1)
    }

    @Test func aPageNumberConflictWaitsForANewNumber() async throws {
        let world = try World()
        world.fake.takenNumbers.insert("n1#1")
        let id = try await world.queue(1)[0]
        await world.engine.run()
        let blocked = await world.item(id)
        #expect(blocked.state == .needsUserAction)
        #expect(blocked.attention == .pageNumberConflict)
        try await world.engine.renumber(id, to: 5)
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        let done = await world.item(id)
        #expect(done.state == .serverAccepted)
        #expect(done.operationId != blocked.operationId)
        #expect(world.fake.ops[done.operationId]?.body["page_number"] == "5")
    }

    @Test func usedUpAllowanceAsksOncePerBatchThenDefers() async throws {
        let world = try World()
        world.fake.processingAllowance = 0
        let ids = try await world.queue(2)
        await world.engine.run()
        for id in ids { #expect(await world.item(id).attention == .processingLimit) }
        try await world.engine.decide(.uploadAndProcessLater, batch: world.batch)
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        for id in ids {
            let item = await world.item(id)
            #expect(item.state == .serverAccepted)
            #expect(world.fake.ops[item.operationId]?.body["processing_mode"] == "deferred")
        }
        // A later item in the same batch follows the answer without asking.
        let image = try ImagePreparer().prepare(photo(.jpeg, width: 32, height: 32, gps: false))
        let late = try await world.store.capture(image, batchId: world.batch, sequence: 9, accountId: "account-1", serverURL: server)
        try await world.store.update(late.id) { $0.notebookId = "n1"; $0.pageNumber = 9; $0.state = .ready }
        await world.engine.run()
        #expect(await world.item(late.id).state == .uploading)
        #expect(await world.item(late.id).processingMode == "deferred")
    }

    @Test func anExpiredUploadLinkIsRefreshedOnTheSameReservation() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        await world.engine.run()
        world.fake.expiredURLs = true
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        #expect(await world.item(id).resumePoint == .upload)
        await world.settle()
        #expect(await world.item(id).state == .serverAccepted)
        #expect(world.fake.log.contains("POST /v1/upload-sessions/{id}/refresh"))
        #expect(world.fake.ops.count == 1)
    }

    @Test func anExpiredReservationNeedsAnExplicitLinkedRetry() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        await world.engine.run()
        let first = await world.item(id).operationId
        world.fake.expire(operation: first)
        world.fake.expiredURLs = true
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        await world.engine.run()
        let expired = await world.item(id)
        #expect(expired.state == .needsUserAction)
        #expect(expired.attention == .expired)
        try await world.engine.retryNow(id)
        await world.transfers.finishAll(server: world.fake, engine: world.engine)
        let retried = await world.item(id)

        #expect(retried.state == .serverAccepted)
        #expect(retried.operationId != first)
        #expect(world.fake.ops[retried.operationId]?.body["retry_of_operation_id"] == first)
    }

    @Test func aRelaunchResumesUploadsWithoutDuplicates() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        await world.engine.run()
        await world.transfers.forgetAll()
        await world.settle()
        #expect(await world.item(id).state == .serverAccepted)
        #expect(world.fake.ops.count == 1)
        #expect(await world.transfers.started.count == 2)
    }

    @Test func capturesFromAnotherAccountAreNeverUploaded() async throws {
        let world = try World(account: "account-2")
        let id = try await world.queue(1, account: "account-1")[0]
        await world.engine.run()
        #expect(world.fake.log.isEmpty)
        #expect(await world.item(id).state == .ready)
    }

    @Test func aMissingPhotoIsReconciledWithTheServer() async throws {
        let world = try World()
        let ids = try await world.queue(2)
        // Never sent: the user decides.
        try FileManager.default.removeItem(at: await world.store.fileURL(for: world.item(ids[0]))!)
        await world.engine.run()
        #expect(await world.item(ids[0]).attention == .captureMissing)
        // Already stored by Libarrie (completion result lost, then the photo vanished).
        let second = await world.item(ids[1])
        world.fake.lock.withLock {
            world.fake.ops[second.operationId]!.uploaded = true
            world.fake.ops[second.operationId]!.accepted = true
        }
        await world.transfers.forgetAll()
        try FileManager.default.removeItem(at: await world.store.fileURL(for: second)!)
        await world.engine.run()
        let reconciled = await world.item(ids[1])
        #expect(reconciled.state == .serverAccepted)
        #expect(reconciled.localFileRemoved)
    }

    @Test func replacementsAreConditionalAndWaitForAllowance() async throws {
        let world = try World()
        let image = try ImagePreparer().prepare(photo(.jpeg, width: 32, height: 32, gps: false))
        let item = try await world.store.capture(image, batchId: world.batch, sequence: 0, accountId: "account-1", serverURL: server)
        try await world.store.update(item.id) { $0.replacesPageId = "p1"; $0.replacesContentVersion = 3; $0.state = .ready }
        world.fake.processingAllowance = 0
        // A connection failure leaves it queued; the retry carries If-Match
        // (the fake answers 428 without it) and is never deferred.
        world.fake.fault("POST /v1/upload-sessions", .networkBeforeServer)
        await world.engine.run()
        #expect(await world.item(item.id).state == .retryableError)
        world.later()
        await world.engine.run()
        let created = await world.item(item.id)
        #expect(created.state == .uploading)
        let op = world.fake.ops[created.operationId]!
        #expect(op.body["page_id"] == "p1")
        #expect(op.body["processing_mode"] == "immediate")
        #expect(op.body["notebook_id"] == nil)
    }

    @Test func cancellingCancelsOnTheServerAndForgetsThePhoto() async throws {
        let world = try World()
        let id = try await world.queue(1)[0]
        await world.engine.run()
        let operation = await world.item(id).operationId
        try await world.engine.cancel(id)
        #expect(await world.store.item(id) == nil)
        #expect(world.fake.ops[operation]?.status == "cancelled")
    }

    @Test func anExpiredSignInPausesWithoutLosingWork() async throws {
        struct SignedOut: AccessTokenProvider {
            func accessToken() async throws -> String { throw APIError.unauthenticated }
            func refreshAfterRejection(of token: String) async throws -> String { throw APIError.unauthenticated }
        }
        let world = try World(tokens: SignedOut())
        let ids = try await world.queue(2)
        await world.engine.run()
        #expect(await world.engine.needsSignIn)
        #expect(await world.item(ids[0]).state == .retryableError)
        // The second item was not touched after the pause.
        #expect(await world.item(ids[1]).state == .ready)
    }

    @Test func manifestSurvivesRelaunchWithRelativePaths() async throws {
        let directory = temporaryDirectory()
        let image = try ImagePreparer().prepare(photo(.jpeg, width: 32, height: 32, gps: false))
        let first = try CaptureStore(directory: directory)
        let item = try await first.capture(image, batchId: UUID(), sequence: 0, accountId: "a", serverURL: server)
        let reopened = try CaptureStore(directory: directory)
        let restored = try #require(await reopened.item(item.id))
        #expect(restored.operationId == item.operationId)
        #expect(await reopened.verifyFile(of: restored))
        // A tampered manifest cannot point outside the capture directory.
        var evil = restored
        evil.fileName = "../../etc/passwd"
        #expect(await reopened.fileURL(for: evil) == nil)
    }
}
