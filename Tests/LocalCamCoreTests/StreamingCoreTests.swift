import XCTest
@testable import LocalCamCore

final class StreamingCoreTests: XCTestCase {
    func testProtocolEndpointURLString() {
        let url = StreamingProtocolSpec.endpointURLString(lanAddress: "192.168.1.42")
        XCTAssertEqual(url, "ws://192.168.1.42:8765/")
    }

    func testLatestFrameBufferKeepsNewestFrameOnly() {
        let buffer = LatestFrameBuffer()
        buffer.replace(with: Data([0x01]), maximumBytes: 10)
        buffer.replace(with: Data([0x02, 0x03]), maximumBytes: 10)

        let firstRead = buffer.takeLatest()
        let secondRead = buffer.takeLatest()

        XCTAssertEqual(firstRead, Data([0x02, 0x03]))
        XCTAssertNil(secondRead)
    }

    func testLatestFrameBufferDropsOversizeFrames() {
        let buffer = LatestFrameBuffer()
        buffer.replace(with: Data(repeating: 0xFF, count: 16), maximumBytes: 8)

        XCTAssertNil(buffer.takeLatest())
    }
}
