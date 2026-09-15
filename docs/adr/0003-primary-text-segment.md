# 单元级 Primary Text 数轴

**Status:** accepted

`CONTEXT.md` 说 Primary Text Stream 是「**一条逻辑上的**规范文本，由各单元自己的规范文本按 reading order 直接拼接而成，不插入任何合成分隔符」，而 `NativePosition` 的 `utf16Offset` 是「它**所在单元那一段内**的绝对偏移」。本 ADR 定下**那一段本身**在 Core 里的形状 —— 它是偏移真正赖以成立的那个数轴。

## 证据基线

本 ADR 引用的旧仓结论，一律固定到这一份：

- 仓：**`54zhien/nagi-engine`**
- commit：**`47c071ad0cc99685cd6b51cfca5160b193706546`**
- `docs/adr/0004-position-and-anchor-model.md` —— `TextBoundaryPolicy.storage`
- `docs/adr/0005-primary-text-stream.md` —— 一条主数轴、不插合成分隔符
- `Sources/SpikeAKit/CanonicalText.swift` —— 本 ADR 判定「不整体搬迁」的那个**实现切片**

下文提到旧仓的编号时，一律指**上述旧验证仓**的那一份；它们与 Core 将来可能出现的同编号 ADR 无关。

## 形状

```swift
public struct PrimaryTextSegment: Sendable {
    public let unitID: DocumentUnitID
    public let string: String

    public init(unitID: DocumentUnitID, string: String)

    public var utf16Count: Int { get }

    public func isStorageBoundary(at utf16Offset: Int) -> Bool
    public func text(inUTF16 range: Range<Int>) -> String?
}
```

## 契约

- **它是一个完整 `DocumentUnit` 的 unit-local primary text**：不是 publication-global 文本，也**不是 `ContentShard`**。分片是处理域的决定，永远不得进入位置系统（见 `CONTEXT.md` 的 `Content Shard`）。
- **构造器不解析、不折叠、不归一化。** 它接收**已经 canonicalized** 的字符串 —— 去注音、空白折叠、XHTML 解析全部属于 **ingest**，不属于这里。一个会顺手规范化输入的构造器，会让「谁折叠了空白」变成一个查不出来的问题。
- **不带 `Codable`、不带 `Hashable`**，也不带 `NodeID`、元素树、样式、ruby annotation 或任何几何。没有消费者的一致性就是零用途 API。**`NodeID` 由 ingest / identity scheme 生成，元素树由解析产生；二者都不属于本层的文本数轴。**
- **合法 storage boundary**：`0...utf16Count` 中**不切开 surrogate pair** 的位置。负数、越界、`Int.max` 一律 `false`。名字里的 storage 沿用**上述旧验证仓的 ADR-0004** 里的 `TextBoundaryPolicy.storage`（不切 surrogate）—— **这一层只提供那条基础事实**，`.caret` / `.shapingCluster` / `.lineBreak` 是它之上的策略。
- **`text(inUTF16:)` 的完整语义**：
  - 参数是**半开区间** `[lowerBound, upperBound)`；它的**有序性由 `Range<Int>` 的有效值本身保证**（见下）；
  - **两端都必须是合法 storage boundary**；
  - **非负与上界由本方法检查**，且必须在**任何索引或切片运算之前**；
  - 成功时返回**该 UTF-16 区间对应的精确文本**；
  - **合法的空区间返回 `""`**；
  - **任一条件不成立返回 `nil`**。
  - **本方法不重复检查 `lowerBound <= upperBound`。** 违反 `Range` 初始化器前置条件的值**不在本 API 的支持域**：调用方在把参数交进来之前就会先触发 `Range` 自己的前置条件，轮不到本方法作答。本层为它设 guard 只会重复一道已经存在、且本层无从判断得更好的检查。
    - **这一次是实测出来的**：Swift 6.1.2 的 Debug CI（run `34921959000`）里，一条试图用 `Range(uncheckedBounds:)` 构造逆序 `Range` 的测试，**在进入本方法之前**就被 `Swift/Range.swift:179` 的 `Fatal error: Range requires lowerBound <= upperBound` 终止 —— 进程级 SIGTRAP，不是断言失败。
    - **口径限定**：这是**本次构建配置**（Swift 6.1.2 · Debug · macOS CI）的实测行为，**不是**「任何优化模式下该值都不可能有物理表示」这类断言。结论只到「本方法不承担这项检查」为止 —— 此前那段「调用方可以造出逆序 `Range`、所以方法必须自己拒绝」的判断由此作废，但不往前多走一步。
  - 它**不得**把半个 surrogate 静默解码成 U+FFFD —— 「取一段取不到」必须是 `nil`，而不是一段看起来正常、内容已经坏掉的文本。
- **这一步不宣称实现 `PositionResolver`，也不决定吸附方向。** 它给的是**事实**（这个偏移是不是边界、这一段文本是什么），吸附是策略。

## 为什么不是把旧仓的 `CanonicalText` 搬过来

旧仓的 **canonical-text 实现切片**（`Sources/SpikeAKit/CanonicalText.swift`）把四件事**捆在一起**：

- 可靠的 **UTF-16 数轴**（`CanonicalText.string` / `utf16Count` / `text(in:)`）；
- **元素身份与范围映射**（同一个结构体里嵌套的 `CanonicalText.Element`：`name` / `explicitID` / `path` / `utf16Range`）；
- **空白折叠**（同文件的 `WhitespaceFolding`）；
- **XHTML 解析**（同文件的 `XHTMLToCanonical`）。

**`NodeID` 不在其中** —— 它由 identity scheme 构造，不在这个文件里。四件里只有第一件属于 Core；另外三件都是 **ingest** 的职责（折叠与解析本就是，元素映射是解析的产物）。整体搬迁会把 ingest 与解析的职责一起搬进数轴这一层。

## 为什么不现在就做 `ContentFragment` / `PositionResolver` / `PageMap`

- **`ContentFragment`**：它究竟覆盖**整个 unit** 还是**局部 shard**、是否需要 unit-relative base offset，**尚未定案**。形状未定就落类型，等于把猜测写成契约。
- **完整 `PositionResolver`**：还缺**吸附方向**与 caret / shaping / line-break 三套策略。现在公开一个半成品，会**重犯 PR #2 的错误** —— 那个 PR 的 CI 是绿的，但契约不成立。
- **`PageMap`**：本 ADR 与它的实现**已经提供 unit-local 长度**（`utf16Count`），但 PageMap 仍缺**页范围**、**Layout Signature / generation**、**完整性状态**、**部分分页下的 Page identity**，以及**把 segment / length 交付给消费者的正式路径**。（与 README 的措辞一致。）

## 与既有决定的关系

- **上述旧验证仓的 ADR-0005** 已经定下：主数轴不占注音、不占被折叠的空白，且流由各单元文本按 reading order 直接拼接、**不插合成分隔符**。本 ADR 是那条决定在 Core 里的落点。
- **本仓 ADR-0002** 已定下 `NativePosition.utf16Offset` 是 unit-local 的绝对偏移。本 ADR 给出那个偏移**合法与否**的判据。
- **ADR-0001**（本仓）的边界不变：`NagiEngineCore` 不依赖 SwiftSoup、CoreText 或任何 UI。**字符串是调用方交给它的**，它不去解析任何东西。

## Consequences

- ingest 与 Core 的分界线在这里变得可检验：**任何解析、折叠、归一化都发生在构造之前**，构造之后只剩数轴事实。
- `PrimaryTextSegment` 是值类型，不持有 `DocumentUnit`、不反向引用 manifest —— unit 的身份由 `unitID` 携带，作用域由持有者决定。
- 下一步（R1）只实现这一个类型与它的测试；`ContentFragment`、`PositionResolver`、`PageMap` 继续后置。
