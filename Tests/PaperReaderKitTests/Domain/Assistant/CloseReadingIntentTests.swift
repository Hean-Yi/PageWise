import PaperReaderKit
import Testing

@Test func closeReadingIntentAllowsCriticalReadingAndOfflineConstraints() {
    for request in [
        "请精读这篇论文，不要默认作者的结论正确。", "精读全文，不用联网。", "精读全文，重点是这些数据能说明什么？",
        "能否帮我精读这篇论文？", "可以帮我精读吗？", "Please close-read this paper, do not assume the claim is true.",
    ] {
        #expect(CloseReadingIntent.isRequested(request), "应进入精读：\(request)")
    }
}

@Test func closeReadingIntentRespectsReadOnlyInstructionsAndFeatureQuestions() {
    for instruction in [
        "不要精读", "不要给我做精读这篇论文。", "精读全文，但先不写笔记。", "精读这篇论文，不保存。",
        "请精读这篇论文，不要给我做精读笔记。", "请精读论文，只讨论。", "close-read this paper without saving notes.",
        "AI 精读，可以做什么？", "请问精读是什么意思？", "精读这篇论文需要多久？", "AI 精读全文会自动写笔记吗？",
    ] {
        #expect(!CloseReadingIntent.isRequested(instruction), "不应写入精读笔记：\(instruction)")
    }
}
