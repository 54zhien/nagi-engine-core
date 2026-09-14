# 建仓计划（E0 基线）

**方案由 Codex 给出，Claude 执行。** 本文件记录本仓从零起步的顺序：先立边界，再立值模型，再让真实消费者决定形状。

## E0 —— 建仓骨架与 `DocumentManifest` 最小生产基础（已完成）

**产出**：本仓的十一个文件 —— `Package.swift`、`LICENSE`、`README.md`、`CONTEXT.md`、`.gitattributes`、`.gitignore`、`.github/workflows/ci.yml`、`docs/adr/0001-production-repository-boundary.md`、`Sources/NagiEngineCore/DocumentManifest.swift`、`Tests/NagiEngineCoreTests/DocumentManifestTests.swift`、本文件。

**这一版的形状是**：`DocumentUnitID`（`RawRepresentable` / `Codable` / `Hashable` / `Sendable`，`rawValue` 是 `String`）、`DocumentUnit`（`id` + `href` + `mediaType`，**不含正文**）、`DocumentManifestError.duplicateUnitID`、`DocumentManifest`（公开只读 `readingOrder`，构造时一次建表，重复 ID 立即抛错，`readingOrderIndex(of:)` 零基 O(1)）。

**边界**：本仓不依赖 Readium、SwiftSoup、CoreText 或 UI；旧仓 `54zhien/nagi-engine` 是**证据源不是包依赖**。见 `docs/adr/0001`。

**没做的**：不实现 `NodeID`、`NativePosition`、`DocumentOrderKey`、`PageMap`、`PositionResolver`、`DocumentStore`；`DocumentManifest` 暂不 `Codable`；不公开索引 map；不做 href 查找；不加字段校验。

## E1 —— Native Position 与文档序比较（R0 / R1 / R2）

**E1 分三段，每段各自停在一个确认点。**

| 段 | 内容 | 状态 |
|---|---|---|
| **R0** | **契约**：`docs/adr/0002-native-position-and-document-order.md` 与 `CONTEXT.md` 的 `NodeID` 词条。**纯文档，不写代码。** | **已完成（Codex 复审通过）** |
| **R1** | 按 R0 的契约实现 `NodeID` / `NativePosition` / `DocumentOrderComparison` / `compareInDocumentOrder(_:_:)` 与测试。 | **已完成（Codex 复审通过；13 条测试）** |
| **R2** | **本 PR 的远端门禁**：推送分支、开 Draft PR，让 macOS CI 做**首次真实编译与测试**（基线 9 + 新增 13 = **预期 22 tests / 0 failures**），通过后停在**合并前终审**。不增加新功能。 | 进行中 |

**R0 的定案**（全文见 ADR-0002）：`NodeID` 在 Core 是**不透明字符串身份**，**直接采用 Swift `String` `==`、不附加 href 式归一化**，怎么生成归 ingest / identity scheme；`NativePosition` 是 `unitID + nodeID + utf16Offset` 的不可变值，**不带 `documentOrder`、不给 `Comparable`、initializer 不校验 offset**；次序由一个 `internal` 的 `DocumentOrderKey(unitIndex, utf16Offset)` 承担（非 `Codable`、不持久化），公开面只暴露 `DocumentOrderComparison` 与 `compareInDocumentOrder(_:_:)`。

### 三个确认点

1. **R0 文档 diff** —— 就是本段，交 Codex。
2. **R1 未提交的代码 + 测试 diff** —— 写好、**未提交前**交 Codex。
3. **PR 的 CI 之后、合并之前** —— 合并前交 Codex。

**后续合并审批交 Codex 复审**，不再逐次向用户索要。

### PageMap 后置（PR #2 被否决）

上一版把 `PageMap` 与 `DocumentOrderKey` 一起做。PR #2 的 CI 是**绿的**（23 tests / 0 failures），但**契约不通过**，已**关闭、不合并**。四条原因：

1. **缺单元长度** —— manifest 不带长度，于是任意超界的 offset 都被塞进最后页：那是一个不存在的位置，却被给出一个确定的答案。
2. **公开的 `pageBreaks` 不验证结构不变量** —— 文档写着升序且大于零，代码不检查；非升序输入会从二分里**静默答错**。
3. **两层数组让 `DocumentOrderKey` 的跨单元 `Comparable` 没有真实消费** —— 单元内每个键的 `unitIndex` 都相同，比较退化成偏移；真正让它成为**文档**序的那一半无人使用。
4. **只实现了词表里一个完成态术语的一半** —— `CONTEXT.md` 的 Page Map 是「Native Position ↔ 页序号、可部分完成、可由 Layout Signature 重建」，而那一版没有 position、没有页范围、没有 signature、没有完整性。

**PageMap 要等这些定案**：Native Position、页范围与单元长度、Layout Signature / generation、完整性状态，以及部分分页下的 Page identity。

旧分支的 `docs/adr/0002-pagemap-boundary.md` 从未进入 `main`，**不是 canonical ADR**；未来若重启 PageMap，必须基于当时的 `main` 重新定案，**不得恢复该 accepted 文件**。

## E2 —— 再扩展

E1 的 R1 之后才谈。**顺序不是日程，是依赖**：每个值模型的形状应由它的消费者倒推，而不是先摆好再去找人用。

## 一条约束

**计划写在这里，不写进 `CONTEXT.md`。** 词汇表只定义术语的含义与边界；把阶段、待办、实现顺序写进去，它就不再是词汇表，而两个用途会互相污染。
