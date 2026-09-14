# Nagi Engine Core

> Nagi 自研阅读引擎的**生产核心**。**当前不可用** —— 这里只有第一批纯值模型，没有任何能读一本书的代码。

## 这个仓是什么，不是什么

| | |
|---|---|
| **是** | Nagi 引擎的生产实现。领域名、契约、模块边界按生产标准定，改动要过 ADR |
| **不是** | 架构验证仓。它**不能**是 —— 实证与生产对代码的要求不同，混在一起两边都做不好 |

**架构证据固定在 `54zhien/nagi-engine` 的 commit [`47c071ad0cc99685cd6b51cfca5160b193706546`](https://github.com/54zhien/nagi-engine/commit/47c071ad0cc99685cd6b51cfca5160b193706546)** —— 那是 spike / ADR 证据库，Nagi 的架构结论在哪里被**测量**过（位置身份能不能往返、CoreText 能不能当可控排版后端、重锚的语义与确定性）。本仓的设计决定以上面的读数为据，**证据本身不在本仓复现**。

**两个仓之间没有源码依赖，也不会有。** 本仓不把旧仓当包依赖，旧仓不把本仓当依赖；共享的只有术语与结论，形式是文档，不是 link。

## 现在有什么

```swift
public struct DocumentManifest: Sendable {
    public let readingOrder: [DocumentUnit]
    public func readingOrderIndex(of unitID: DocumentUnitID) -> Int?   // 零基、O(1)
    public func compareInDocumentOrder(_ lhs: NativePosition, _ rhs: NativePosition) -> DocumentOrderComparison?
}

public struct NativePosition: Codable, Hashable, Sendable {
    public let unitID: DocumentUnitID
    public let nodeID: NodeID
    public let utf16Offset: Int
}
```

一个 manifest、它的单元 ID 与单元描述，外加一条构造期不变量：**同一 manifest 内 ID 必须唯一，重复立即抛 `DocumentManifestError.duplicateUnitID`**。

以及「两个位置谁在前」这个问题的答案：`compareInDocumentOrder` 给出 `before / sameCoordinate / after` **三值**。**同单元、同偏移就是同一个文本坐标** —— `NodeID` 不参与破平局；**任一位置的单元不在 manifest 里就返回 `nil`** —— 没有键就没有次序，不是「排到最后」，也不是错误。次序是**文档的函数**：manifest 重排，同两个位置的先后随之改变。见 **ADR-0002**。

**还没有**：`PageMap`、`PositionResolver`、`DocumentStore`、`PageScene`、`LayoutSignature`、任何解析器、任何排版后端、任何 UI。`PageMap` 是**后置**的 —— 它要等 Native Position、页范围与单元长度、Layout Signature / generation、完整性状态，以及部分分页下的 Page identity 都定案。`DocumentManifest` 本身也**还不是** `Codable` —— 序列化形状要等真正需要持久化的那个消费者来定，不是现在猜。

## 构建与测试

```bash
swift build
swift test
```

无平台绑定：第一批是纯值模型，不依赖任何 deployment target。

## 设计决定在哪

- `CONTEXT.md` —— 词汇表。只定义术语的含义与边界，每个词都写了 `_Avoid_`，说明它**不是**什么。**它不放计划。**
- `docs/adr/` —— 设计决定，一份一个。生产仓的边界见 `0001`。
- `tasks/` —— 进行中的计划。计划写在这里，不写进 `CONTEXT.md`。

## 环境要求

- Swift 5.9+
- 无第三方依赖

## License

MIT —— 见 [LICENSE](LICENSE)。
