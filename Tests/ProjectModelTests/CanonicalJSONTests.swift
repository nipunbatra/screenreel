import XCTest

@testable import ProjectModel

final class CanonicalJSONTests: XCTestCase {
    func testSortedKeysAndCompactness() throws {
        let value = JSONValue.object([
            "zeta": .integer(1),
            "alpha": .string("x"),
            "mid": .array([.bool(true), .null]),
        ])
        XCTAssertEqual(
            try value.canonicalString(),
            #"{"alpha":"x","mid":[true,null],"zeta":1}"#)
    }

    func testStringEscapes() throws {
        let control = String(UnicodeScalar(1))
        let value = JSONValue.object(["k": .string("a\"b\\c\nd\te" + control)])
        XCTAssertEqual(
            try value.canonicalString(),
            #"{"k":"a\"b\\c\nd\te\u0001"}"#)
    }

    func testIntegerAndDoubleFormatting() throws {
        XCTAssertEqual(try JSONValue.integer(-42).canonicalString(), "-42")
        XCTAssertEqual(try JSONValue.double(0.5).canonicalString(), "0.5")
        // Whole-number doubles serialize as integers for stability.
        XCTAssertEqual(try JSONValue.double(3).canonicalString(), "3")
        XCTAssertThrowsError(try JSONValue.double(.infinity).canonicalString())
    }

    func testRoundTripThroughParserIsByteStable() throws {
        let original = JSONValue.object([
            "b": .double(1.25),
            "a": .integer(9_007_199_254_740_993),  // beyond Double precision
            "c": .object(["nested": .array([.integer(1), .double(2.5)])]),
        ])
        let first = try original.canonicalData()
        let reparsed = try JSONValue(data: first)
        let second = try reparsed.canonicalData()
        XCTAssertEqual(first, second)
    }

    func testEncodableBridge() throws {
        struct Sample: Codable {
            var name: String
            var count: Int
        }
        let value = try JSONValue(encoding: Sample(name: "s", count: 2))
        XCTAssertEqual(value["name"]?.stringValue, "s")
        XCTAssertEqual(value["count"]?.integerValue, 2)
        let decoded = try value.decoded(as: Sample.self)
        XCTAssertEqual(decoded.name, "s")
    }
}
