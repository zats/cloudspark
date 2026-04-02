import XCTest
@testable import CloudflareKit

final class CloudflareKitTests: XCTestCase {
    func testWorkerIdentityUsesScriptNameOnly() {
        let script = WorkerScript(id: "lorica-cia-diligence-owner", tag: "ignored")

        XCTAssertEqual(script.identity?.scriptName, "lorica-cia-diligence-owner")
    }
}
