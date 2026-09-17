# 横排单节点纯文本的 Page Scene

**Status:** accepted

E4 是「从**能渲染且可交互的最小消费者**倒推」的第一条纵切：

```
PrimaryTextSegment
  + 由 ingest 外部注入的单一 NodeID
  + TextPaginationConstraints
  + CoreTextLineBreakBackend（font / languageTag 由这一侧注入）
        ↓
NagiEngineCoreText：一个每次调用独占的 module-internal recording backend 包住它
        ↓
NagiEngineCore：**现有** TextPaginator 决定页边界（Core 不改一行）
        ↓
该 session 的 exact CTLine → transient 的 CoreTextPaginatedPlainText
        ↓
CoreTextPlainTextPageScene：draw(in:foregroundColor:) 与同步 nativePosition(at:)
```

**它不是 `PageMap`**；不做 `ContentFragment` / `DocumentStore` / `PositionResolver` / `LayoutSignature` 持久身份；不做 EPUB/HTML/CSS、ruby、图片、链接、竖排、禁则修正、UIKit/SwiftUI。

**它与 E3 的关系**：E3 交付的是页**范围**（`UnitPageRanges`），页上什么都没有；E4 交付的是**一页看得见、点得中**。契约（ADR-0004）里「Core 验证候选、决定页边界」的那一半**原样沿用**，一行不改。

## 证据基线

本 ADR 引用的旧仓结论，一律固定到：`54zhien/nagi-engine` @ `47c071ad0cc99685cd6b51cfca5160b193706546`

| 路径 | 本 ADR 只借它支撑 |
|---|---|
| `docs/adr/0006-coretext-backend-boundary.md:5` | CoreText 是 shaping/typography backend；block flow、line policy、fragmentation、column/page geometry、pagination decisions 属 Nagi |
| `docs/adr/0006-coretext-backend-boundary.md:19` | 明文：**不禁止**使用 `CTTypesetterSuggestLineBreak` / `CTLine` / `CTRun`；禁的是让它们成为**页面几何的最终决定者** |
| `docs/adr/0006-coretext-backend-boundary.md:44` / `:56` | 最终 line-break policy、禁则校验、候选断点修正权仍属 Nagi；反例出现时由 Nagi `LineBreakPolicy` 层补规则，**不改 backend 边界** |
| `docs/adr/0008-incremental-pagination-and-pagemap.md:30` | v1 的 `DocumentUnit` 是 hard pagination boundary —— 页不跨 unit |
| `docs/adr/0008-incremental-pagination-and-pagemap.md:32` | Layout 层从第一天以策略抽象，不得假定 hard 限制永久存在 |
| `docs/adr/0008-incremental-pagination-and-pagemap.md:42` | 当前可见 `PageScene` 的交互**必须完全同步**；必须携带完成命中所需的全部局部映射 |
| `docs/adr/0008-incremental-pagination-and-pagemap.md:44` | **页内同步，跨页允许 async** |

正文提到旧仓编号时，一律指上表那一份。

**两条术语纪律**：

- 旧仓**没有 `PrimaryTextSegment` 这个类型**（该 commit 全树零命中）。旧仓的说法是 unit-local primary text；`PrimaryTextSegment` 是**本仓 ADR-0003** 的类型。不得写成旧仓已有。
- 旧仓的主语是「Nagi」/「Nagi Layout Engine」，**不出现「Core」一词**。本 ADR 说的 Core 就是本仓的 `NagiEngineCore`。

**主工程现状基线**（`Seidoku Local Reader` @ `9f5cd1a6b2cfa638044a90b5713ad682c8f4b9dc`）：

| 事实 | 证据 |
|---|---|
| 今天 TXT **先转派生 EPUB、再进 Readium**，且这是**唯一**一条 TXT 阅读路径 | `Nagi/Services/TXTReaderAssetService.swift:391`（「统一解析入口：EPUB 直接使用原文件，TXT 按需生成并缓存派生 EPUB」）、`:43-45`（产物扩展名 `.epub`）、`Nagi/Features/Reader/ViewModel/EPUBReaderModel.swift:240-247`（无条件按 EPUB 打开）、`Nagi/Services/ReadiumService.swift:57`（`guard publication.conforms(to: .epub)` 硬闸门） |
| **没有**绕过 EPUB 直排的路径；主工程**零** `import CoreText` | 全仓 `import CoreText` 命中 0；原生绘制只在卷页动画层，绘的是 Readium 已栅格化的位图 |
| 主工程**尚未依赖** Core | 全仓 `enginecore`（大小写不敏感）命中 **0**；无 `Package.swift`；xcodeproj 只有 SwiftSoup + swift-toolkit 两个远程包 |
| 主工程**没有分页器**；「页」在它那里是一张位图 + Readium 的不透明身份句柄 | `Nagi/Features/Reader/Engine/PageTurnDomain.swift:187-218`（`PageSurface`，`public let image: UIImage`）；`PageTurnMetrics` 只处理手势几何 |

**因此 E4 的范围被这条基线钉死**：本纵切**只在 Core 仓内建立真实的 scene 消费者**，**不动主工程**。带门控的 Nagi TXT 实机接入（并保留 Readium 回退）是**下一阶段 E5**，本 ADR 只登记它为后续宿主 pilot。

## A. 输入、输出与它不冒充什么

- **输入**：一个**完整的** `PrimaryTextSegment`、一个**由 ingest 在外部注入的单一 `NodeID`**、一组 `TextPaginationConstraints`、一个 `CoreTextLineBreakBackend`（`CTFont` 与 `languageTag` 由这一侧注入）。
- **builder 绝不生成、也绝不猜 `NodeID`。** 注入进来的那一个 `NodeID` **覆盖本切片的全部文本**。
- **因此它只适用于 TXT 式单节点纯文本，不冒充多节点 `ContentFragment`。** 一个 unit 里有多元素、每元素各有身份的那种输入，不在本切片的支持域 —— 那时需要的是 `ContentFragment` 与真正的元素↔范围映射，两者都还没有定案（ADR-0003 已把 `ContentFragment` 后置）。
- **CoreText 侧多出来的名字只有一个入口**：`CoreTextLineBreakBackend.makePaginatedPlainText(segment:nodeID:constraints:)`。

## B. Core 一行不改

**E4 不改 `Sources/NagiEngineCore/TextPagination.swift`，不改 `NagiEngineCore` 的任何公开 API。Core 侧零改动。**

CoreText 侧要拿到「同一次调用的页范围」与「这次调用的行」，靠的是一个**每次调用独占的 module-internal recording backend**，它包住 `CoreTextLineBreakBackend`，仍然**只调用现有那个** `TextPaginator.paginate(segment:constraints:backend:)`：

- 它的 `makeSession` **由 Core 在正确的时点调用**（三项 constraints 全部合法、且 segment 非空之后），并把**那一个** `CoreTextLineBreakSession` 记下来；
- 非空且分页**成功**之后，paginated value 由**该 session 的 exact line artifacts** 构造；
- **空 segment 时 Core 根本不调用 `makeSession`** ⇒ 记录下来的 session **仍为 `nil`**，于是 `pageCount == 0`；
- 它是 **module-internal 的实现细节，不是 public API**：不作为公开类型、不被复用、不进 Core。写成 `internal`（而非字面 `private`）是为了让 `@testable` 能证明「`makeSession` 恰好被调用一次 / 空文本零次」。
- **行保留是 opt-in 的**：公开的 `makeSession(for:)` 默认**不记录任何行** —— 只做 ranges 的那条路径不该因为被分页过，就把整个 unit 的 `CTLine` 一直留在内存里；页面场景要的那些行由 recording 那一侧**显式打开**。两条路径**测量完全相同**，差别只在**留什么**。

**这条机制的价值是让不变量成为结构事实**：「页范围」与「行 artifact」必然出自**同一次调用、同一个 session、同一套 font 与 constraints**。§C 里「不得任意拼接」因此是被构造保证的，而不是靠纪律维持。

**Core 仍唯一决定页界**：证据是 `0006:5` 与 `0006:13`（「这一页在哪里结束」归 Nagi）。CoreText 侧只**保存**已经发生过的测量结果。

### Rejected alternative: `public` session overload

曾考虑给 `TextPaginator` 增加一个 `public paginate(segment:constraints:session:)` overload，让具体 session 直接由同一个调用方持有。**否决**，两条理由：

1. **session 实参会在进入 paginator 之前由调用方创建**，于是**绕开 ADR-0004 已经定死的执行顺序**（先验证三项 constraints → 空 segment 立即返回且**不 makeSession** → 非空才 makeSession）。顺序是那份契约的承重部分，不能因为多一个入口就出现第二条时间线。
2. **让 factory 复制 constraints 校验，违反单一所有权** —— 校验的归属者只能是 paginator，多一处副本就是两处可能不同步的真相。

## C. CoreText 侧的公开形状

```swift
// NagiEngineCoreText

public struct CoreTextLineBreakBackend: LineBreakBackend {
    // 既有，E4 不改
    public init(font: CTFont, languageTag: String? = nil)
    public func makeSession(for segment: PrimaryTextSegment) throws -> CoreTextLineBreakSession

    // E4 新增；本切片唯一的入口
    public func makePaginatedPlainText(
        segment: PrimaryTextSegment,
        nodeID: NodeID,
        constraints: TextPaginationConstraints
    ) throws -> CoreTextPaginatedPlainText
}

/// Transient。非 `Codable`、非 `Hashable`、非 `Sendable`。
public struct CoreTextPaginatedPlainText {
    public let nodeID: NodeID
    public let pageRanges: UnitPageRanges
    public var pageCount: Int { get }

    /// 越界下标 → `nil`。
    public func scene(at pageIndex: Int) -> CoreTextPlainTextPageScene?
}

/// Transient。非 `Codable`、非 `Hashable`、非 `Sendable`。
public struct CoreTextPlainTextPageScene {
    public let unitID: DocumentUnitID
    public let nodeID: NodeID
    public let pageIndex: Int
    public let utf16Range: Range<Int>
    public let size: CGSize
    public let lineCount: Int

    public func draw(in context: CGContext, foregroundColor: CGColor)
    public func nativePosition(at point: CGPoint) -> NativePosition?
}
```

- **页范围就是既有的领域类型 `UnitPageRanges`，不是 `[Range<Int>]`。** 降格成裸数组会丢掉那个类型，也会丢掉它与 unit 的绑定。**unit 身份由 `pageRanges.unitID` 唯一承载**，`CoreTextPaginatedPlainText` 不再另存一份 `unitID`。
- **两者都没有 `public init`。** 尤其**不提供「从任意 `UnitPageRanges` 构造 `CoreTextPaginatedPlainText`」的入口** —— 一旦提供，§B 那条「同一次调用」的结构保证就被绕开了，调用方可以把 A 次分页的范围配上 B 次分页的行。唯一生产者是 `makePaginatedPlainText`。
- **两者都在 `NagiEngineCoreText` 里，不在 Core 里。** 它们持有 `CTLine` 与 `CGContext`/`CGColor`，平台中立层不认识它们（ADR-0001 的边界不变：`NagiEngineCore` 不 `import CoreText`）。
- **`pageCount == 0` 当且仅当 segment 为空**（§B 的机制保证）。
- **`scene(at:)` 的越界行为是 `nil`，签名保持 optional，不另造 public error**。

### C1. 生命周期不变量

**`font`、`languageTag`、`inlineExtent`、`blockExtent`、`lineSpacing` 任一变化 ⇒ 宿主必须丢弃整个 `CoreTextPaginatedPlainText` 及其全部 scene，然后重建。**

- 该对象**不可跨 layout run 比较或复用**：两次碰巧相等的 `pageRanges` **不是**同一次 layout identity。
- **这不等于本仓已有 `LayoutSignature`** —— 那个仍然没有，也不由本 ADR 引入。

### C2. 产出 paginated value 之前的校验

**scene 的几何不得建立在未检查的数字上。** 校验分两层；**任一条不成立都抛模块内部错误**，**公开 factory 仍是普通的 `throws`，不扩 public error API**。

**逐条（每一个 line artifact）**：

1. `CTLineGetStringRange(line)` 与**已被接受的** `LineMeasurement.consumedUTF16Range` **完全一致**；
2. `ascent` / `descent` / `leading` 与 typographic width **都能产出且有限**，且 **width ≥ 0**。

**整体（retained artifacts 与已接受 measurements 之间）**：

3. **一一对应，且顺序就是 `suggestLine` 的调用顺序** —— 不得有**缺失**、**重复**或**重排**；
4. 全部 measurement 的 range **连续无缝覆盖 `0..<segment.utf16Count`**；
5. **每一个 `UnitPageRanges` 的页范围都能由连续的、完整的 artifacts 精确分组** —— **任何一行都不得跨过页范围的 `upperBound`**，即行必须整行落在页内，**页边界不得切在行内**。

第 3–5 条是 §B 那条结构保证的**下游检查**：机制保证了页范围与行必然同源同调用，这里检查它们**是否真的对得上** —— 只逐条查 `CTLineGetStringRange` 与数字，查不出「少了一行 / 多了一行 / 顺序错了 / 页界切在行内」这四类错。

## D. 几何、绘制与命中

### D1. scene 坐标

- **page-local、左上原点、x 向右、y 向下。**
- `size` 的宽高**恰等于**该次分页的 `constraints.inlineExtent` / `constraints.blockExtent`。
- **页内的行排布**：第 `k` 行（0 基）占据的 band 顶端为
  `top(k) = Σ_{j<k} extent(j) + k · lineSpacing`，
  其中 `extent(j) = ascent(j) + descent(j) + leading(j)`，即 `CTLine` 的自然 block extent —— 与 Core 分页时用的**同一个数**。该行的基线为 `top(k) + ascent(k)`。
  这正好复现 Core 的 greedy 记账（`n` 行带 `n−1` 个 gap），所以**scene 的行高之和不会与 Core 的判据打架**。
- **单行高于 page 仍然合法**（ADR-0004 的不变量原样沿用）：该行照常占一页，绘制被裁到 page bounds。**这不是异常路径。**

**调用方的坐标前提（入口条件）**：

- 调用方传入 `context` 时，**它的 current user space 必须已经把 `(0, 0)` 对应到目标 page 的左上角**，**正 x 向右、正 y 向下**。
- **`draw` 不负责把 page 放进外部大画布** —— 那是调用方的事。scene 只在这块 `(0, 0, size.width, size.height)` 的**局部空间**里裁剪与画字。
- scene **内部只承担 CoreText 文本空间所需的翻转与 text matrix 设置**，并在退出前把 **`textMatrix` 与 `textPosition` 显式恢复为进入值** —— **不能只靠 `restoreGState`**，理由见 §D2。
- **否则「内部翻转、调用方看到左上原点坐标」这件事无法从签名推导** —— 所以它是契约的一部分，必须写下来，也必须被测。

### D2. 绘制

- **不填背景。** scene 只画字形；底色是调用方的事。
- **裁到 page bounds**：绘制区域就是 `(0, 0, size.width, size.height)`。
- **save / restore graphics state** 成对，**并且另外显式捕获并恢复 `textMatrix` 与 `textPosition`**，不得把任何状态泄漏给调用方。
  - **CI 已经证明的是哪一条**：run `34963033441` 直接证明**普通 graphics-state restore 不恢复 text matrix** —— `draw` 返回后，调用方读回的 matrix 含 `d = −1`，以及 `draw` 之后的平移。那次运行**没有**单独读回 `textPosition`，所以它**不能**被当作「restore 同样不恢复 textPosition」的证据。
  - **本方法还显式改变 `textPosition`**（逐行设置 text position 才画得出字）。因此为兑现「零泄漏」，**两项都由实现捕获并恢复**，并由测试**分别**验证 —— 不是把一条实测推广成两条。
  - 恢复的代码写法是**内部策略，不是契约**：契约只要求一件事 —— **入口读到的两项，出口读回时逐项原样**。
- **前景色由调用方给出**（`foregroundColor` 参数），**绝不进入分页约束** —— `TextPaginationConstraints` 只有三个几何量，主题颜色与分页无关。
- **让 context 的填色接管前景，靠的是 shaping 输入里的一个非度量 flag，不是 draw 时的 setFillColor 单独作用。** `NSAttributedString` 在**没有颜色属性时默认黑**，于是 CoreText 会自行在 context 上设色 —— 单靠 `CGContextSetFillColorWithColor` **不能保证接管**。因此：
  - **在创建 typesetter 的那一次 shaping 输入里**，属性字符串必须带上 **`kCTForegroundColorFromContextAttributeName: kCFBooleanTrue`**：这是 CoreText 官方的**非度量**属性（`CFBoolean`，默认 `false`），为 `true` 时前景取自 context 的填色，且它同时决定 `kCTUnderlineStyleAttributeName` 所用的颜色；
  - 该 flag **从 session 创建起固定**。`draw` 只做 `CGContextSetFillColorWithColor` + `CTLineDraw`；
  - **换色时不重建属性字符串、不二次 shaping**；
  - **判据（测试钉死）**：用**两种不同的前景色**分别绘制，**`pageRanges` 与各行 metrics 必须完全相同**。
- 加这个 flag 是 R1 对 `CoreTextLineBreakSession` shaping 输入的**唯一增量改动**，它**不得改变**任何断行或度量（判据同上一条）。
- scene 的 y 向下而 CoreText 的文本空间 y 向上，**翻转由 scene 在内部完成，并在退出前连同 `textPosition` 一起显式还原**；调用方看到的永远是 §D1 那套坐标。

### D3. `nativePosition(at:)`

**同步**：不做 IO、不 async、不物化文档。这是 `0008:42` 的「必须完全同步」与 `0008:44` 的「页内同步」的直接落实。

**返回**：`unitID` + **注入的那个 `nodeID`** + 一个 **CoreText hit-test string index**。

**命中的前置条件**（全部满足才进入取值）：

1. 点的两个分量都**有限**；
2. 点在 **page bounds** 内 —— 这一条**由 scene 手工判定**，且是**闭**边界：`0 ≤ x ≤ size.width` 且 `0 ≤ y ≤ size.height`；
3. 点落在某一行的 **band 内** —— 即 `top(k) ≤ y < top(k) + extent(k)`（**半开**，上边界不属于该行）。**相邻两行之间的 `lineSpacing` 空白不属于任何一行**；
4. 点在该行的**水平 advance** 内 —— **闭**区间 `0 ≤ x ≤ 该行 typographic width`。**只有 `x > width` 才算短行右侧的空白**；`x == width` **不算**。

**为什么水平方向是闭、垂直方向是半开**（两者必须不同，否则与下面第 10 条测试直接冲突）：

- **垂直必须半开**：相邻两条 band 共享端点（`lineSpacing == 0` 时，band `k` 的末端恰是 band `k+1` 的起端）。若垂直也取闭，一个点会同时属于两行，命中结果就不再唯一。
- **水平必须闭**：`CTLineGetOffsetForStringIndex` 对**行尾插入点**（该行 `upperBound`）通常给出 `x == width`。半开判据 `x < width` 会**先把它拒掉**，于是「行尾后一位可命中」永远不可能成立；同理，**零宽的行会永远不可命中**。

**零宽行**：某行 typographic width 为 `0` 时，**不得被水平前置条件无条件排除** —— `x == 0 == width` 落在闭区间内，可以通过。它最终是否命中，仍由 **CoreText 的 `kCFNotFound` / string index** 与 **storage boundary** 两道决定，不由宽度决定。

**取到的 index 的口径**：

- `CTLineGetStringIndexForPosition` 给的是**一个用于插入位置的 string index**，官方允许它落在**该行首索引到末索引加一**之间。**本 ADR 一律称它为 CoreText hit-test string index / insertion index，不称 cluster boundary** —— 本层不做 cluster 级校正，也不宣称有。
- **接受区间是该行 consumed range 的闭区间 `lowerBound...upperBound`。** 末索引加一是合法插入位置，**不得用 `Range.contains` 把 `upperBound` 拒掉**。
- 通过闭区间之后，仍须 **`PrimaryTextSegment.isStorageBoundary(at:)` 为真**。

**两条 CoreText 调用不互为逆运算**（本次 run 实测）：

- `CTLineGetOffsetForStringIndex` 与 `CTLineGetStringIndexForPosition` **不承诺互为逆**。本次 newline corpus 已证实：在**由该行 `upperBound` 推出来的 end x** 上做位置命中，CoreText 返回的是**另一个**合法 index（该行的末字符），而不是 `upperBound` —— **这条 round-trip 没有闭合**。
- **仅止于此。** 本次运行**没有**单独测「那个返回的 index 是否也精确等于同一个 x」，所以本节**不主张**「多个 insertion index 共享同一个可视 x」。那是**未经测试**的命题，写进契约就会变成一条事实。
- 因此 **`nativePosition` 只返回 CoreText 在该点实际给出的那个 index**：它必须落在该行 consumed range 的闭区间内、并且是 storage boundary，否则 `nil`。
- **本层绝不在 `x == width`、或索引等于某个值时强制改写结果。** 那等于在本层发明 caret / affinity 策略，与「不定义 caret policy」直接冲突。
- 由此，闭区间接受（水平 advance 与索引各一条）的意义是**「不预先排除 CoreText 可能给出的 `upperBound`」**，**不是**承诺 offset 与 index 可逆。

**返回 `nil` 的情形**（穷举）：非有限坐标；落在 page bounds **的闭边界之外**；**行距空白**；**`x > 该行 typographic width`**（短行右侧的空白）；`kCFNotFound`；index 落在 consumed range 的闭区间之外；index **不是 storage boundary**。

**不同 `NodeID` 不参与几何，也不参与断行**：换一个注入的 `NodeID`，`pageRanges`、`size`、`lineCount`、每一次命中的 `utf16Offset` 都必须**一模一样**，只有返回身份里的 `nodeID` 变。

**它不是完整的 `PositionResolver`。** 它不定义跨页选择（`0008:44` 明文允许跨页 async）、不定义 caret 吸附方向、不做链接/图片命中、不涉及无障碍。**含 combining mark 的语料只用来证明本层不擅自升级 caret policy，不宣称任何 cluster 语义。**

## E. 已裁定的边界

1. **link/image**：纯文本支持域里 **link/image domain 不存在**，因此「没有 region」是**空支持域**，不是缺实现。**类型上根本不携带这两个东西** —— 不得写成「携带两个空集合」。
2. **`FlowBoundaryPolicy`**：那是旧验证仓**未被整体纳入 Core** 的建议；E3 已用**单 unit 结构**把 hard 固定下来；E4 **不引入没有消费者的抽象**。**首次出现多 unit flow 消费者时重新定案**，本 ADR 不预判。
3. **禁则校验与断行策略权**：`0006:44` / `:56` 把权利留给 Nagi；本切片**保留该权利但不实现**。**不冲突** —— 与 ADR-0004「对 candidate 做结构校验后原样接受」同一口径。
4. **`scene(at:)` 的越界下标**：返回 `nil`，签名保持 optional，**不另造 public error**。

## F. 明确不做的事

`PageMap`、`LayoutSignature` 的**持久身份**、`DocumentStore`、`ContentFragment`、HTML/CSS 解析、ruby、图片、链接、竖排、禁则修正、UIKit/SwiftUI、**主工程修改**、**像素逐字节 golden**。

**不得恢复已关闭 PR #2 的 `PageMap` 代码，也不得恢复那份 ADR。**

## G. 阶段

| 段 | 内容 |
|---|---|
| **R0** | 本 ADR + 计划里的 E4 段。**纯文档，不写代码。** |
| **R1** | `NagiEngineCoreText` 侧：recording backend、session 的 line artifacts、`CoreTextPaginatedPlainText`、`CoreTextPlainTextPageScene`、`draw`、`nativePosition(at:)`，与 §H 的测试；单独提交，推 **Draft PR** 跑 macOS CI 后停。 |
| **R2** | 文档收口（README / 计划 / 本 ADR 的实现与实测记录）、最终 CI、转 ready、**合并前终审**。 |

## H. 测试计划（必须含证伪）

**证伪类**：

1. **recording backend 与既有 `paginate(segment:constraints:backend:)` 路径同结果**；且 `makeSession` **非空时恰好一次、空文本时零次**（用 `@testable` 证明，故它必须是 module-internal 而非字面 `private`）；
2. **scene 的页范围严格等于 Core 决定的范围** —— 逐页比对 `pageRanges`，不是「覆盖了就算」；
3. **同一次 line artifact 被复用，而非二次断行** —— 用可观测的计数证明 `suggestLine` 的调用次数不因取 scene 而增加；
4. **空 segment**：`pageCount == 0` **且 `makeSession` 从未被调用**；
5. `scene(at:)` 的**负下标与越界下标**返回 `nil`；
6. **constraints 非法时**仍然抛 Core 的错误（顺序未被绕开）；
7. **产出前的校验可证伪**，逐条构造并断言抛错：**`CTLineGetStringRange` 与已接受 measurement 不一致**；**width 非有限或为负**；**缺少**一个 artifact；**重复**一个 artifact；**乱序**（把 artifacts 的对应关系打乱）；**页边界切在行内**（某页范围的 `upperBound` 落在某一行的 consumed range 中间）。

**内容与边界类**：

8. ASCII / CJK / surrogate（非 BMP）/ combining mark 四种语料各跑一次，页范围完整、页位在 storage boundary；**combining mark 只证明不擅自升级 caret policy**；
9. **行距空白**与 **page 之外**的 `nativePosition(at:)` 返回 `nil`；页内正常位置返回非 `nil`；
10. **在由 `upperBound` 推导的 end x 上命中**：该测试的 x **必须由 `CTLineGetOffsetForStringIndex` 对该行的 `upperBound` 推导**（y 取该行 band 内），**不得手写 `width`，也不得用 epsilon 去凑**。要求两条，且只有这两条：① 该点**不得被水平条件提前拒绝**；② 返回值**等于 CoreText 在该点实际给出的合法 index** —— 测试必须用**同一个 relative point** 直接调 `CTLineGetStringIndexForPosition` 得到 `expected`，先断言 `expected` 通过 consumed 闭区间与 storage boundary 两道校验，**再**断言 scene 返回 `expected`。
    **不得写死 `expected == upperBound`**（两条调用不互为逆，见 §D3），**也不得写死任何一次 CI 观测到的具体索引值**。
    **另加**：`width == 0` 的行**不因水平前置检查被无条件排除**（其 x 落在闭区间内可以通过），最终结果仍由 CoreText 给出的 index 与 storage boundary 决定；
11. **不同注入 `NodeID` 只改变命中身份**，`pageRanges` / `size` / `lineCount` / `utf16Offset` 全部不变；
12. **两种前景色绘制不改变 `pageRanges` 与各行 metrics**；
13. **非零绘制烟测**（真的画了东西、状态被还原、背景未被填），**但不做像素逐字节 golden**。测试必须**先把 bitmap `CGContext` 配成 §D1 那套 page-local、正 y 向下的 user space**，再验证**方向**（字形落在预期的页内位置）与**状态恢复**（`restore` 后调用方的状态未被改动）。

**回归**：现有 **65 条**测试不得回退（CoreTextLineBreakBackend 10 / DocumentManifest 9 / NativePosition 13 / PrimaryTextSegment 13 / TextPagination 20）。

**E4 不测试、也不宣称禁则修正。**

## Consequences

- **`CoreTextPaginatedPlainText` 只在生成它的那次调用里有意义**：不 `Codable`、不 `Hashable`、不持久化、不携带 signature / generation；参数一变即整体作废重建（§C1）。它**不是** `PageMap` 的替代品，也不构成 `PageMap` 的输入契约。
- **Core 侧零改动**：`TextPagination.swift` 与 `NagiEngineCore` 的公开面在 E4 前后**逐字相同**。
- **主工程在本纵切里完全不受影响**：它今天仍走「TXT → 派生 EPUB → Readium」，且**尚未依赖** Core（§证据基线）。E4 只在 Core 仓内建立真实消费者；**实机接入是下一阶段 E5**。
- **两条留给 E5 的输入约束**（E4 不解决，先记下以免将来重找）：
  - 主工程的 `CLAUDE.md` 明文「**不要动用户的 UI** … 不在设置、选项、菜单里加任何东西 —— **包括调试项、状态行、开关**」，且其教训写着「**让用户选渲染引擎这个设计本身就是错的**」；仓内特性开关机制命中 **0**。**因此 E5 的 gate 必须是内部构建 / 能力门，不得是用户设置。**
  - 主工程的 `ReadingPosition` **只有 `locatorJSON: String` 一个字段**，进度持久化整体走 Locator JSON。非 Readium 的排版将来若要共用进度，必须自己产出等价的 locator JSON。
- 旧仓 `0006:56` 的口径在本 ADR 继续适用：本切片用的是 CoreText **默认候选断行**，**不构成**对完整 UAX #14 或日本語組版规则的兼容性保证。

## 实现与实测（2026-09-15）

三笔各自独立提交，契约在前，纠正单独一笔：

| 笔 | commit | 内容 |
|---|---|---|
| **R0** | `a5ecdad` | 本 ADR + 计划里的 E4 段（**纯文档，只两份文件**） |
| **R1** | `10f3bd9` | `NagiEngineCoreText` 侧实现：module-internal recording backend、session 的 exact line artifacts、`CoreTextPaginatedPlainText`、`CoreTextPlainTextPageScene`、`draw`、`nativePosition(at:)` 与 **16 条**测试（三文件） |
| **CI 纠正** | `5b93c3b` | 按首次 CI 的三条失败改实现、测试与本 ADR 的对应段落（三文件）。**未 amend、未 rebase、未 force push** —— 三笔历史可追溯 |

### 两次 CI 读数（均为 macOS runner，`Apple Swift version 6.1.2`）

**第一次：run `34963033441`（head `10f3bd9`）—— 这些文件的第一次真实 Swift / macOS 编译。**

- **编译通过**：81 条测试**全部被执行**，**没有任何编译错误**。
- **81 tests / 3 failures**：三条**都在新增的 16 条里**；**65 条基线全绿，一条未退**。
- 三条失败各暴露一类事实：

  1. **`textMatrix` 状态泄漏** —— `draw` 返回后，调用方读回的 matrix 含 `d = −1`，以及 `draw` 之后的平移。**普通 `restoreGState` 不恢复 text matrix。**（那次运行**没有**单独读回 `textPosition`，所以它不构成「restore 也不恢复 textPosition」的证据。）
  2. **「`upperBound` 可逆」这个假设是错的** —— 在由 `upperBound` 推来的 end x 上做位置命中，`CTLineGetStringIndexForPosition` 返回的是**另一个**合法 index：**round-trip 没有闭合**。这是**契约**的问题，不是实现的问题。
  3. **跨颜色的 coverage 等式过强** —— 同一批字形换一种前景色后，alpha 覆盖像素数不同；文字平滑使覆盖率**与颜色相关**，像素几何不是有效的不变量。

**第二次：run `34964944798`（head `5b93c3b`，attempt 1）→ 绿**

| suite | tests |
|---|---|
| `CoreTextLineBreakBackendTests` | 10 |
| `CoreTextPlainTextPageSceneTests` | 16 |
| `DocumentManifestTests` | 9 |
| `NativePositionTests` | 13 |
| `PrimaryTextSegmentTests` | 13 |
| `TextPaginationTests` | 20 |
| **合计** | **81 tests / 0 failures** |

required check `build-and-test`（`app_id` 15368）→ `completed / success`，**绑在 `5b93c3b` 上**。

### 首次红 run 之后的最终裁定

1. **图形状态**：`draw` 进入时捕获 `textMatrix` 与 `textPosition`，退出时**显式恢复**。契约要求的是**入口两项、出口原样**；恢复的代码写法是内部策略，不是契约。
2. **行尾**：`nativePosition` **返回 CoreText 在该点实际给出的合法 index**，**不对 `x == width` 或 `upperBound` 做任何特判** —— 那等于在本层发明 caret / affinity 策略。§D3 与 §H 第 10 条已按此改写。
3. **颜色**：颜色**只门禁布局**（`pageRanges` 与各行 top / baseline / ascent / descent / leading / typographicWidth / naturalBlockExtent **全量不变**），外加「**目标颜色确实画出来了**」；**不再比较两次绘制的像素几何**。

### 这一阶段没有动的东西

- **`NagiEngineCore` 与 `Sources/NagiEngineCore/TextPagination.swift`：零改动。** `TextPagination.swift` 在 E4 一字未改，Core 的公开面逐字不变。
- **主工程零改动**（只做过只读调查）。
- **E4 没有引入** `PageMap` / `ContentFragment` / `DocumentStore` / 宿主适配 / `LayoutSignature` 持久身份。
- **PR #6 在写下这段时仍是 Draft、未合并**，也**未转 ready**。
