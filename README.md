# Nagi Engine Core

> Nagi 自研阅读引擎的**生产核心**。**它现在还替换不了 Nagi 阅读器** —— 这里有清单、位置、一段主文本数轴，以及一条横排纯文本的分页纵切；这条纵切现在能**画出一页，并把页内的点同步映射成位置**，但**尚未接进任何宿主**，也没有 ingest、`ContentFragment` 或 EPUB 样式。

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

**在分页之上，现在还能画出一页，并同步命中它**（同一个 target）：

```swift
// 由 ingest 注入的、覆盖整段纯文本的单一身份。本层不生成、也不猜 NodeID。
let nodeID = NodeID(rawValue: "chapter-3")

let paginated: CoreTextPaginatedPlainText = try backend.makePaginatedPlainText(
    segment: segment,
    nodeID: nodeID,
    constraints: constraints
)

let pageRanges: UnitPageRanges = paginated.pageRanges   // 仍由 TextPaginator 决定
let scene = paginated.scene(at: 0)                      // 越界下标得 nil

// context 与前景色都由宿主提供 —— 这里只是占位名。
// 本仓不认识 UIKit / SwiftUI 的视图类型，也不假定宿主用哪一种。
scene?.draw(in: hostProvidedContext, foregroundColor: hostProvidedForegroundColor)

// 点是页局部的：左上原点、x 向右、y 向下。
if let point = hostProvidedPointInPageCoordinates {
    let position: NativePosition? = scene?.nativePosition(at: point)
}
```

scene 的坐标是 **page-local、左上原点、x 向右、y 向下**；`draw` 只在这块 `(0, 0, size.width, size.height)` 里画字、**不填背景**，并在退出前**显式恢复 `textMatrix` 与 `textPosition`** —— run `34963033441` 直接证明的是**普通 `restoreGState` 没有恢复 `textMatrix`**；而 `draw` 本身还会改 `textPosition`，所以**两项都由实现捕获并恢复**。`nativePosition(at:)` **不做 IO、不 async、不物化文档**：页外、行距空白、短行右侧空白一律 `nil`。

**三条结构保证**（是构造，不是纪律）：

1. **页界仍由现有的 `TextPaginator` 决定。** `makePaginatedPlainText` 只是把现有的 `paginate(segment:constraints:backend:)` 调用一次并留住它产出的行 —— **Core 侧一行未改**：`NagiEngineCore` 的公开面与 `Sources/NagiEngineCore/TextPagination.swift` 逐字不变。
2. **scene 复用同一次 session 的 exact `CTLine`，不二次 shaping。** 页范围与行 artifact 必然出自**同一次调用、同一个 session、同一套 font 与 constraints**；取一页不会再向后端要一行。
3. **`NodeID` 由外部注入，且覆盖整段纯文本。** 换一个 `NodeID` 只改变命中身份，**不改变任何范围或几何**。

**生命周期**：`font`、`languageTag`、`inlineExtent`、`blockExtent`、`lineSpacing` **任一变化**，宿主必须**丢弃整个 `CoreTextPaginatedPlainText` 及其全部 scene 并重建**。它是 transient 的：**非 `Codable` / `Hashable` / `Sendable`**，**不是 `PageMap`**，也**不是 layout identity**。见 **ADR-0005**。

**还没有**：`ContentFragment`、`DocumentStore`、`PositionResolver`、`PageMap`、`LayoutSignature`；**完整的多节点 `PageScene`**（这一页只认单节点纯文本）、**选区 / 链接 / 图片命中 / 无障碍**；**任何宿主适配**、**任何 EPUB ingest 与样式**、任何 UI。`DocumentManifest` 本身也**还不是** `Codable`。

**距离实机替换，缺的是好几层，不是两根线：**

- **正式的内容输入路径** —— `ContentFragment` / ingest / store。这条纵切吃的是**已经 canonical 化好的字符串**：谁产出它、何时物化、怎么缓存，都还没有着落。
- **更宽的 `PageScene`** —— 现在这一页只覆盖**横排、单节点纯文本**：没有多节点元素↔范围映射，没有选区起点，没有链接与图片命中，也不涉及无障碍。**对本切片已经支持的那一件事 —— 点 → `NativePosition` 命中 —— 同步性已经兑现**（`nativePosition(at:)` 不做 IO、不 async、不物化文档）；**其余的页内交互仍未交付**。
- **宿主适配** —— 把上面这些接进一个真正的阅读器。
- 再往后，**EPUB 的整体替换**还需要 CSS / style 级联、ruby 与竖排等一批后续能力。

换句话说：现在能在 Core 仓内**把一个 unit 分页、画出一页、并把页内的点同步映射成 `NativePosition`** —— 但**它还没接进 app**。

**下一阶段 E5** 才做宿主：一个 **TXT 宿主 pilot**，用一个**内部构建 / 能力门**（**不是用户设置**）决定是否走原生 TXT 直排，并**保留 Readium 回退**。E4 不碰主工程。

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
