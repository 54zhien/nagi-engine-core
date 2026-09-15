# Nagi Engine Core

> Nagi 自研阅读引擎的**生产核心**。**它现在还替换不了 Nagi 阅读器** —— 这里有清单、位置、一段主文本数轴，以及一条横排纯文本的分页纵切，但**没有任何把它画到屏幕上的东西**，也没有宿主集成。

## 这个仓是什么，不是什么

| | |
|---|---|
| **是** | Nagi 引擎的生产实现。领域名、契约、模块边界按生产标准定，改动要过 ADR |
| **不是** | 架构验证仓。它**不能**是 —— 实证与生产对代码的要求不同，混在一起两边都做不好 |

**架构证据固定在 `54zhien/nagi-engine` 的 commit [`47c071ad0cc99685cd6b51cfca5160b193706546`](https://github.com/54zhien/nagi-engine/commit/47c071ad0cc99685cd6b51cfca5160b193706546)** —— 那是 spike / ADR 证据库，Nagi 的架构结论在哪里被**测量**过（位置身份能不能往返、CoreText 能不能当可控排版后端、重锚的语义与确定性）。本仓的设计决定以上面的读数为据，**证据本身不在本仓复现**。

**两个仓之间没有源码依赖，也不会有。** 本仓不把旧仓当包依赖，旧仓不把本仓当依赖；共享的只有术语与结论，形式是文档，不是 link。

## 现在有什么

**核心值层**（`NagiEngineCore`，平台中立）：

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

public struct PrimaryTextSegment: Sendable {
    public let unitID: DocumentUnitID
    public let string: String
    public init(unitID: DocumentUnitID, string: String)
    public var utf16Count: Int { get }
    public func isStorageBoundary(at utf16Offset: Int) -> Bool
    public func text(inUTF16 range: Range<Int>) -> String?
}
```

一个 manifest、它的单元 ID 与单元描述，外加一条构造期不变量：**同一 manifest 内 ID 必须唯一，重复立即抛 `DocumentManifestError.duplicateUnitID`**。

以及「两个位置谁在前」这个问题的答案：`compareInDocumentOrder` 给出 `before / sameCoordinate / after` **三值**。**同单元、同偏移就是同一个文本坐标** —— `NodeID` 不参与破平局；**任一位置的单元不在 manifest 里就返回 `nil`** —— 没有键就没有次序，不是「排到最后」，也不是错误。次序是**文档的函数**：manifest 重排，同两个位置的先后随之改变。见 **ADR-0002**。

还有一个单元的**主文本数轴**：`PrimaryTextSegment` 是**一个完整 unit 的 unit-local primary text** —— 不是全书文本，也不是 `ContentShard`。它只给两个事实：某个偏移是不是**合法 storage boundary**（`0...utf16Count` 里不切开 surrogate pair 的位置），以及某个 UTF-16 **半开区间**对应的**精确文本**（两端都得是合法边界，否则 `nil` —— 不会把半个 surrogate 解成 U+FFFD）。构造器**不解析、不折叠、不归一化**，canonical 化是 ingest 的事；它**不是** `PositionResolver`，**不决定吸附方向**，也**不是 caret policy** —— combining mark 内部仍是合法边界，因为它只认 surrogate pair。见 **ADR-0003**。

**分页纵切**（`NagiEngineCoreText`，**Apple-only**）：

```swift
import CoreText
import NagiEngineCore
import NagiEngineCoreText

let segment = PrimaryTextSegment(
    unitID: DocumentUnitID(rawValue: "OEBPS/chapter.xhtml"),
    string: canonicalPrimaryText          // 已经 canonical 化好的一段，见 ADR-0003
)

let constraints = TextPaginationConstraints(
    inlineExtent: 320,
    blockExtent: 480,
    lineSpacing: 4
)

let backend = CoreTextLineBreakBackend(
    font: CTFontCreateWithName("PingFang SC" as CFString, 16, nil)
)

let pages: UnitPageRanges = try TextPaginator.paginate(
    segment: segment,
    constraints: constraints,
    backend: backend
)
```

**分页是 Core 拥有的。** 后端只给**候选行**（`CTTypesetterSuggestLineBreak` 候选 + `CTLine` 的自然 `ascent + descent + leading`）；**页边界由 `TextPaginator` 决定**，它逐项校验候选并自己分组。实现是横排、单一 `CTFont`、常量非负 line spacing、矩形 extent —— 见 **ADR-0004**。

`UnitPageRanges` 是**一个完整 unit 的 transient 页范围**：有序、unit-local、半开、无缝覆盖。**它不携带 Layout Signature，也不是 `PageMap`** —— 将来那份索引要自建身份。

**还没有**：`ContentFragment`、`DocumentStore`、`PositionResolver`、`PageMap`、`LayoutSignature`、`PageScene`、任何渲染、任何 UI、任何宿主适配、任何 EPUB ingest。`DocumentManifest` 本身也**还不是** `Codable`。

**距离实机替换，缺的是好几层，不是两根线：**

- **正式的内容输入路径** —— `ContentFragment` / ingest / store。今天这条分页纵切吃的是**已经 canonical 化好的字符串**：谁产出它、何时物化、怎么缓存，都还没有着落。
- **可渲染且可交互的 `PageScene`** —— 不只是把字画出来。页内命中测试、选区起点、链接点击必须**完全同步**，所以它得自带完成这些所需的局部映射。
- **宿主适配** —— 把上面这些接进一个真正的阅读器。
- 再往后，**EPUB 的整体替换**还需要 CSS / style 级联、ruby 与竖排等一批后续能力。

换句话说：现在能算出**一个单元的分页边界**，仅此而已。

## 构建与测试

```bash
swift build
swift test
```

**按 product 分**：`NagiEngineCore` **平台中立**（用 Foundation，不声明 deployment target）；`NagiEngineCoreText` 链接 CoreText，因此是 **Apple-only**。「整个 package 在所有平台默认全目标可建」这句**不成立** —— 能不能覆盖全目标，取决于选哪个 product / target 与条件编译。

**本仓不声明最低 OS**：那是一个应由真实部署需求决定的数，不是在这里猜的。

## 设计决定在哪

- `CONTEXT.md` —— 词汇表。只定义术语的含义与边界，每个词都写了 `_Avoid_`，说明它**不是**什么。**它不放计划。**
- `docs/adr/` —— 设计决定，一份一个。生产仓的边界见 `0001`。
- `tasks/` —— 进行中的计划。计划写在这里，不写进 `CONTEXT.md`。

## 环境要求

- Swift 5.9+
- 无第三方依赖

## License

MIT —— 见 [LICENSE](LICENSE)。
