import XCTest
@testable import MeetMemo

final class VoiceInputTextNormalizerTests: XCTestCase {
    func testDemonstrativesArePreservedInNormalText() {
        // 「这个/那个」是有意义的指示代词，不应被当作口头语删除。
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("我要这个。"), "我要这个。")
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("把那个拿过来"), "把那个拿过来")
    }

    func testRepeatedDemonstrativesAreCollapsed() {
        // 仅叠词重复时收敛成一个。
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("这个这个就是这样"), "这个就是这样")
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("然后然后我们走"), "然后我们走")
    }

    func testPureFillerWordsAreRemoved() {
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("嗯 我觉得可以"), "我觉得可以")
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("我说 呃 算了"), "我说 算了")
    }

    func testConnectiveWordsAreNotDeletedWhenStandalone() {
        // 「就是/然后」单次出现是正常正文，不删除。
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("答案就是这样"), "答案就是这样")
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("先吃饭然后睡觉"), "先吃饭然后睡觉")
    }

    func testVoiceCommandsAreConvertedToPunctuation() {
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("你好 句号"), "你好。")
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("第一行 换行 第二行"), "第一行\n第二行")
    }

    func testWhitespaceIsTidied() {
        XCTAssertEqual(VoiceInputTextNormalizer.normalize("  hello    world  "), "hello world")
    }
}
