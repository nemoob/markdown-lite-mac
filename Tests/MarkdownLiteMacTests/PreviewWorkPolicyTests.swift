import Testing

@testable import MarkdownLiteMac

// 验证预览策略精确区分标签状态、五 MiB 边界和单次手动刷新。
@Suite("预览工作策略")
struct PreviewWorkPolicyTests {
    // 后台标签的自动请求即使正文很小也不得启动预览。
    @Test("后台标签拒绝自动预览")
    func testBackgroundTabPausesAutomaticPreview() {
        // 使用远低于上限的正文，隔离验证后台标签规则。
        let decision = PreviewWorkPolicy.decision(
            isActiveDocument: false,
            documentByteCount: 1,
            trigger: .automatic
        )

        // 策略必须返回可区分的后台暂停原因。
        #expect(decision == .paused(.backgroundTab))
        // 暂停原因必须提供可直接展示的中文短文案。
        #expect(decision.pauseReason?.displayMessage == "后台标签不自动预览")
    }

    // 活动标签中的普通小文档应保持自动预览体验。
    @Test("活动小文档允许自动预览")
    func testActiveSmallDocumentAllowsAutomaticPreview() {
        // 使用上限前一个字节代表正常小文档。
        let decision = PreviewWorkPolicy.decision(
            isActiveDocument: true,
            documentByteCount: PreviewWorkPolicy.automaticPreviewByteLimit - 1,
            trigger: .automatic
        )

        // 未达到上限的活动文档必须继续自动预览。
        #expect(decision == .allowed)
        // 允许执行时不得残留暂停原因。
        #expect(decision.pauseReason == nil)
    }

    // 五 MiB 本身属于允许范围，防止比较符误写成大于等于。
    @Test("五 MiB 边界允许自动预览")
    func testExactLimitAllowsAutomaticPreview() {
        // 精确使用正式策略公开的五 MiB 字节上限。
        let decision = PreviewWorkPolicy.decision(
            isActiveDocument: true,
            documentByteCount: PreviewWorkPolicy.automaticPreviewByteLimit,
            trigger: .automatic
        )

        // 等于上限的活动文档仍必须执行自动预览。
        #expect(decision == .allowed)
    }

    // 超过五 MiB 一个字节必须立即进入大文档暂停状态。
    @Test("超过五 MiB 一个字节暂停自动预览")
    func testOneByteOverLimitPausesAutomaticPreview() {
        // 只增加一个字节以精确验证严格上界。
        let decision = PreviewWorkPolicy.decision(
            isActiveDocument: true,
            documentByteCount: PreviewWorkPolicy.automaticPreviewByteLimit + 1,
            trigger: .automatic
        )

        // 超界请求必须携带大文档暂停原因。
        #expect(decision == .paused(.documentTooLarge))
        // 文案必须同时解释阈值和可用的手动恢复动作。
        #expect(
            decision.pauseReason?.displayMessage
                == "文档超过 5 MiB，自动预览已暂停，可手动刷新"
        )
    }

    // 手动刷新仅放行当前请求，不能永久解除大文档自动暂停。
    @Test("手动刷新单次允许任意大小")
    func testManualRefreshAllowsOneRequestOnly() {
        // 用最大可表示字节数证明手动刷新不受五 MiB 上限约束。
        let manualDecision = PreviewWorkPolicy.decision(
            isActiveDocument: true,
            documentByteCount: Int.max,
            trigger: .manualRefresh
        )
        // 紧接着用同一大小发起自动请求，验证策略没有保存豁免状态。
        let followingAutomaticDecision = PreviewWorkPolicy.decision(
            isActiveDocument: true,
            documentByteCount: Int.max,
            trigger: .automatic
        )

        // 用户本次显式请求必须被允许。
        #expect(manualDecision == .allowed)
        // 后续自动请求仍必须按大文档规则暂停。
        #expect(followingAutomaticDecision == .paused(.documentTooLarge))
    }
}
