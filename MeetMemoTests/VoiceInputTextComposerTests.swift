import XCTest
@testable import MeetMemo

final class VoiceInputTextComposerTests: XCTestCase {
    func testLatinWordsGetSeparatingSpace() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["hello", "world"]), "hello world")
    }

    func testCJKSegmentsAreJoinedWithoutSpace() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["你好", "世界"]), "你好世界")
    }

    func testCJKAndLatinBoundaryHasNoSpace() {
        // 中英之间不主观补空格，只解决英文粘字问题。
        XCTAssertEqual(VoiceInputTextComposer.compose(["中文", "word"]), "中文word")
        XCTAssertEqual(VoiceInputTextComposer.compose(["word", "中文"]), "word中文")
    }

    func testNoSpaceBeforePunctuation() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["hello", "."]), "hello.")
        XCTAssertEqual(VoiceInputTextComposer.compose(["你好", "。"]), "你好。")
    }

    func testDigitsTreatedAsLatinWord() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["room", "101"]), "room 101")
    }

    func testEmptyAndWhitespacePartsAreSkipped() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["hello", "   ", "", "world"]), "hello world")
    }

    func testEachPartIsTrimmedBeforeJoining() {
        XCTAssertEqual(VoiceInputTextComposer.compose([" 你好 ", " 世界 "]), "你好世界")
    }

    func testSinglePartAndEmptyInput() {
        XCTAssertEqual(VoiceInputTextComposer.compose(["solo"]), "solo")
        XCTAssertEqual(VoiceInputTextComposer.compose([]), "")
    }
}
