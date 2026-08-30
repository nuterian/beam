import XCTest
@testable import BeamCore

final class StatsTests: XCTestCase {
    func testPercentileBasics() {
        let s = (1...100).map(Double.init)
        XCTAssertEqual(percentile(s, 50), 51)
        XCTAssertEqual(percentile(s, 99), 100)
        XCTAssertEqual(percentile(s, 100), 100)
    }

    func testSummarizeMax() {
        let s: [Double] = [1, 2, 3, 300]
        let p = summarize(s)
        XCTAssertEqual(p.max, 300)
        XCTAssertEqual(p.p50, 3)
    }

    func testSingleSample() {
        let p = summarize([7])
        XCTAssertEqual(p.p50, 7)
        XCTAssertEqual(p.p999, 7)
    }
}
