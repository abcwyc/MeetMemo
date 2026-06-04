import CoreMedia
import XCTest
@testable import MeetMemo

@available(macOS 26.0, *)
final class SpeechAnalyzerSTTProviderTests: XCTestCase {
    func testMillisecondRangeConvertsSpeechResultRange() {
        let range = CMTimeRange(
            start: CMTime(seconds: 1.234, preferredTimescale: 1_000),
            duration: CMTime(seconds: 2.5, preferredTimescale: 1_000)
        )

        let milliseconds = SpeechAnalyzerSTTProvider.millisecondRange(from: range)

        XCTAssertEqual(milliseconds?.start, 1_234)
        XCTAssertEqual(milliseconds?.end, 3_734)
    }

    func testMillisecondRangeRejectsInvalidTimes() {
        let range = CMTimeRange(start: .invalid, duration: CMTime(seconds: 1, preferredTimescale: 1_000))

        XCTAssertNil(SpeechAnalyzerSTTProvider.millisecondRange(from: range))
    }
}
