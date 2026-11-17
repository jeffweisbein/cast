import XCTest
@testable import Cast
final class SideChatBaselineRegressionTests: XCTestCase {
    func testSavedSideChatIsNotClassifiedAsExpiringMachineWork() throws {
        let key = "agent:main:cast-side-11111111-1111-4111-8111-111111111111"
        let row = try JSONDecoder().decode(SessionRow.self, from: Data("{\"key\":\"\(key)\",\"updatedAt\":1}".utf8))
        let sections = SidebarGrouper.sections([row], mainSessionKey: "agent:main:main", now: Date())
        XCTAssertTrue(sections.flatMap(\.sessions).contains { $0.key == key },
                      "A saved side conversation must not disappear through the 24-hour work filter", file: #fileID)
    }
}
