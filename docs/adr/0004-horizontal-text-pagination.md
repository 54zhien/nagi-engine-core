# 横排纯文本分页

**Status:** accepted

E3 是「横排纯文本的第一条真实分页纵切」：

```
PrimaryTextSegment
  → NagiEngineCoreText（CoreText）：候选行 + 自然 block extent
  → NagiEngineCore：验证候选、决定页边界
  → 一个完整 unit 的 transient UnitPageRanges
```

**它不是 `PageMap`**；不做 `ContentFragment` / `DocumentStore` / `PositionResolver` / `PageScene` / UI；**也不把分页决策交给 `CTFrame` / `CTFramesetter`**。

## 证据基线

本 ADR 引用的旧仓结论，一律固定到：`54zhien/nagi-engine` @ `47c071ad0cc99685cd6b51cfca5160b193706546`

| 路径 | 本 ADR 只借它支撑 |
|---|---|
| `docs/adr/0005-primary-text-stream.md` | line box 必须携带哪些 extent（本 ADR 的简化是**范围限定**） |
| `docs/adr/0006-coretext-backend-boundary.md` | CoreText 与引擎的分工；**不禁止**用 typesetter，禁止的是让它成为页面几何的最终决定者 |
| `docs/adr/0008-incremental-pagination-and-pagemap.md` | hard pagination boundary；`PageMap` 是什么 |
| `docs/adr/0009-publication-progress-model.md` | **页码是派生输出**这一条 |
| `Sources/SpikeKit/Typography.swift` | 候选断行与行度量的既有调用形状、唯一那条行高公式 |
| `Sources/SpikeKit/Report.swift` | 页范围记录的是 **consumed span**、且 **不含像素** |

正文提到旧仓编号时，一律指上表那一份。

## A. target 与职责边界

- **`NagiEngineCore` 不 `import CoreText`。** 新增 **`NagiEngineCoreText`** 作为**独立 target / product**，它依赖 Core；Core 不反过来认识它。
- **CoreText 只负责 shaping、候选断行、`CTLine` 的自然 metrics。** **分页由 Core 决定**：候选由 Core 校验，页边界由 Core 划。
- **E3 只支持**：`horizontal-tb`、**单一 `CTFont`**、可选 language tag、**常量的非负 line spacing**、**矩形** inline / block extent。
- **`CTFont` 由 backend 的 init 注入，这是 E3 的设计决定**（不是从旧仓继承的规矩）：Core 不认识 `CTFont`，注入点是 CoreText 侧 target 的构造参数，因此字体来源与选择策略留在那一侧，Core 只看见候选与数字。
- **不声明 package deployment floor。** R1 / R2 若修改 `Package.swift` 的那段旧注释，只陈述：`NagiEngineCore` 这个 target 与 product **仍平台中立**；`NagiEngineCoreText` 的 target 与 product **是 Apple-only**。**repo 默认的全目标构建是否跨平台，取决于所选 product / target 与条件编译** —— 本 ADR 不扩大承诺，也不猜一个最低 OS。
- **这条分工不是本 ADR 新立的。** 旧仓 ADR-0006:5 已写成一句话（CoreText 是 backend，Nagi 拥有 block flow / line policy / fragmentation / column+page geometry / pagination decisions），0006:7-15 写成一张表：CoreText 只回答「glyph 怎么 shape、给定宽度的候选断点在哪、这一行的实际 ascent/descent」。
- 更关键的是 **0006:17-19 明文**：那份边界**不禁止**使用 `CTTypesetterSuggestLineBreak` / `CTLine` / `CTRun`，禁止的是**让它们成为页面几何的最终决定者**。E3 因此可以正当地使用 typesetter —— 见 D。

## B. Core 侧 API（R0 定形；R1 不得再自行改形）

```swift
public struct LineMeasurement: Equatable, Sendable {
    public let consumedUTF16Range: Range<Int>
    public let naturalBlockExtent: Double
    public init(consumedUTF16Range: Range<Int>, naturalBlockExtent: Double)
}

public protocol LineBreakSession {
    func suggestLine(fromUTF16Offset: Int, inlineExtent: Double) throws -> LineMeasurement?
}

public protocol LineBreakBackend {
    associatedtype Session: LineBreakSession
    func makeSession(for segment: PrimaryTextSegment) throws -> Session
}

public struct TextPaginationConstraints: Equatable, Sendable {
    public let inlineExtent: Double
    public let blockExtent: Double
    public let lineSpacing: Double
    public init(inlineExtent: Double, blockExtent: Double, lineSpacing: Double)
}

public struct UnitPageRanges: Equatable, Sendable {
    public let unitID: DocumentUnitID
    public let utf16Ranges: [Range<Int>]

    init(unitID: DocumentUnitID, utf16Ranges: [Range<Int>])
}

public enum TextPaginator {
    public static func paginate<Backend: LineBreakBackend>(
        segment: PrimaryTextSegment,
        constraints: TextPaginationConstraints,
        backend: Backend
    ) throws -> UnitPageRanges
}
```

### 三个构造入口，两种待遇

- **`UnitPageRanges` 的 init 是 `internal`，不提供 `public init`。** 它的不变量（有序、半开、无缝覆盖）是**承重**的 —— 将来的 `PageMap` 会信任它。
  - **`internal` 挡住的是「模块外」，不是「模块内的其它地方」** —— 模块内（含 `@testable import`）仍然能构造。说清它保证什么、不保证什么：
    - **模块外不能构造**；
    - **构造权留在受信任的 `NagiEngineCore` 模块内**；
    - **R1 里只有 `TextPaginator` 生产它**；
    - 之后 Core 内若出现**新的生产者，必须维持同一不变量**。
  - **R1 的测试既不需要 `@testable`，也不需要那个 init** —— 它只**读取** paginator 的返回值，公开面已经够用。
  - **不改成 `fileprivate` / `private`**：那条不变量的守门人本来就是整个模块，不是一个文件；收紧到文件会把测试逼去另找路子，而不变量并没有因此更牢。
- **`LineMeasurement` 与 `TextPaginationConstraints` 的 `public init` 保留。** 这两个是**不可信输入**：前者由 backend 产出、后者由调用方给出，**paginator 会逐项验证它们**。同一个不变量，一边承重（不给公众造），一边本来就要被检查（给了也不构成信任）。

### 错误：只覆盖 paginator 自己发现的事

```swift
public enum TextPaginationError: Error, Equatable, Sendable {
    case invalidInlineExtent
    case invalidBlockExtent
    case invalidLineSpacing
    case backendStalled(atUTF16Offset: Int)
    case rangeDiscontinuity(expectedUTF16Offset: Int, foundUTF16Offset: Int)
    case nonAdvancingRange(atUTF16Offset: Int)
    case rangeOutOfBounds(Range<Int>)
    case rangeNotOnStorageBoundary(Range<Int>)
    case invalidNaturalBlockExtent(atUTF16Offset: Int)
}
```

- **它只覆盖 `TextPaginator` 自己发现的输入与后端契约违规。** `makeSession` 与 `suggestLine` 抛出的 **backend-specific error 原样向上传播**，不塞进这个枚举 —— 用 `throws` 的普通形态，**不用 typed throws**。这样 `TextPaginationError` 的 `Equatable` 不受影响，也不必为「后端抛了别的」发明一个装不下 `any Error` 的 case。
- **没有任何 case 携带 `Double`。** 会触发 `invalidNaturalBlockExtent` 的值多半是 `Double.nan`，而 `nan != nan` —— 携带它的 `Equatable` 枚举**不自反**，`XCTAssertEqual` 会失败。需要时可报位置（`Int`）。
- **三种 constraints 错误各自成 case**，不合并成一个 `invalidConstraints`：读日志的人要知道**是哪一项**不合法。
- **`nonAdvancingRange` 与 `rangeDiscontinuity` 分开**：前者是「范围没前进」，后者是「没从被请求的 offset 开始」。它们指向后端不同的错。

### `naturalBlockExtent` 的口径

**它等于 `CTLineGetTypographicBounds` 的 `ascent + descent + leading`** —— 即 `CTLine` 的自然 block 轴 extent。**`lineSpacing` 不在其中**：它是约束里的独立加项，只在**同页相邻行之间**由 paginator 加上（N 行有 N−1 个间隔），跨页不计。

这不是挑的读法，而是与旧仓**唯一那条**行高公式对齐：`Typography.swift:234` 写的是 `ascent + descent + leading + input.lineSpacing`，前四项来自 `CTLineGetTypographicBounds`（:233），`lineSpacing` 是外加上去的；该公式已用于分页决策（:237）。

## C. 算法不变量

**后端给的每一个候选都要被校验，不因「这是 Apple 给的」而跳过。**

**paginator 的总体执行顺序（定死）**：

1. **先验证三项 constraints**（`inlineExtent` / `blockExtent` / `lineSpacing`）。
2. **segment 为空 → 立即返回 0 个页范围，并且不调用 `makeSession`。**
3. **非空才 `makeSession`。**
4. **`while currentOffset < utf16Count`** 时调用 `suggestLine(fromUTF16Offset: currentOffset, inlineExtent: …)`。
5. **`currentOffset == utf16Count` 即完成** —— **不为了「确认 nil」再调一次后端**。

由此两条判据没有第二种读法：

- **empty 且 constraints 非法时，先报 constraints 的错** —— 第 1 步在第 2 步之前，空 segment 不构成豁免。
- **任何一次真正的 `suggestLine` 调用返回 `nil`，都是 `backendStalled`** —— 循环条件保证被调用的每一次都满足 `currentOffset < utf16Count`，所以「末尾的 nil」这种情形在这个顺序下**根本不会发生**，不需要为它单列规则。

**每个候选的校验次序同样是定死的**（顺序本身是契约的一部分，避免同一个坏候选被归到错的那一类，也避免拿越界的值去做索引）：

1. **`rangeOutOfBounds`** —— `lower >= 0` 且 `upper <= utf16Count`。**放在最前**，后面任何一步都不会再用到越界的值。
2. **`rangeDiscontinuity`** —— `lower` 必须**恰等于**被请求的 offset。
3. **`nonAdvancingRange`** —— `upper > lower`（空范围不前进）。
4. **`rangeNotOnStorageBoundary`** —— 两端都必须是 `PrimaryTextSegment` 认可的 storage boundary。
5. **`invalidNaturalBlockExtent`** —— `naturalBlockExtent` 必须 finite 且 `> 0`。

**其余不变量**：

- **非空 segment**：所有 consumed range 最终**恰好无缝、无重叠**地覆盖 `0..<utf16Count`。
- **空 segment → 0 个页范围。** 这是 text-only 的切片，**不替图片或空 spine item 发明一张空白页**；而且按上面的顺序，**它连 session 都不建**。
- **constraints 校验**：`inlineExtent` `> 0` 且 finite；`blockExtent` `> 0` 且 finite；`lineSpacing` `>= 0` 且 finite。分别对应上面三个 case。
- **分页是顺序 greedy**：一页的占用 = 各行 natural extent **+ 同页相邻行之间的 spacing**；**exact fit 留在本页**；会超出则**在该行之前**分页；**跨页不计 line spacing**。
- **单行自身高于 `blockExtent` 时单独成页，并且这完全合法 —— 不是错误。** 一个 finite 且 `> 0` 的 `naturalBlockExtent` 即使大于 `blockExtent` 也必须被接受：约束说的是页的容量，不是行的上限；报错就等于拒绝了一个语义上完全可排的输入。这是保证前进的那条规则，不是异常路径。
- **page range 取所含行 consumed range 的首尾**，因而**完整、有序、无缝**覆盖整个 segment；**页不跨 unit**（hard boundary）。这与旧仓记录页范围的方式一致：`Report.swift:179-183` 的 `PageRecord` 记的也是 **consumed span**，并且**不含像素** —— 页在这里是文本上的一段，不是一张图。
- **页数组下标只是这次 `UnitPageRanges` 内的临时序号。** 本 ADR **不定义持久 PageID**，**不宣称** partial / completeness / signature / generation 已经解决。

### E3 对 candidate 做什么：结构校验后**原样接受**

CoreText 给的仍叫 **candidate**，而 **E3 在结构校验通过之后原样接受它** —— **不实现禁则修正，不实现追い込み / 追い出し**，也**不提前公开 `LineBreakPolicy` 类型**。

**Nagi 保留将来调整候选的全部所有权**：旧仓 ADR-0006:44 的结论正是「最终 line-break policy、禁则校验与候选断点修正权仍属于 Nagi Layout Engine」，0006:21-23 也说明禁则等规则必须在 CoreText 之外、才留得出缝来插它们。

**本轮真实新增的是 Core 拥有 page grouping。** 这与「已经实现了最终 line-break policy」是两件事，不得写成一件 —— 前者是 E3 交付的，后者还没有开始。

### `inlineExtent` 的质量边界

`LineBreakSession` 的**语义**契约是：backend 按传入的 `inlineExtent` 给出候选。**Core 只能校验结构**（C 的次序），**不能复做 shaping 或宽度测量** —— 那正是把它放在 backend 的理由。

因此：R1 用 **spy / fake 断言每次调用确实收到了原始的 `inlineExtent`**（转发正确性），R2 用**真实 CoreText** 的关系测试承担质量验证（**窄宽产生的行数与页数不少于宽宽**）。**不写「撒谎的 backend 会被接受」这类规范性测试** —— 那是把契约的边界当成行为来钉，而它约束的是 backend 的义务，不是 Core 的判据。

## D. CoreText 侧（R2）

- `CoreTextLineBreakBackend` / `Session` 使用 **`CTTypesetterSuggestLineBreak` + `CTLineGetTypographicBounds`** —— 旧仓 `Typography.swift:226` 与 `:233` 用的就是这两个，且 `:202-212` 明写**刻意不用** `CTFramesetterSuggestFrameSizeWithConstraints`（它的 `fitRange` 假设水平填充模型）。
- **不得用 `CTFrame` / `CTFramesetter` 决定页。** 旧仓里 frame 只在报告算完之后作为渲染副产品产生（`Typography.swift:286` / `:305-324`），而用 frame 决定布局的那条路径 `chainColumns`（:371-383）**明文只服务竖排探针**。
- **CoreText 返回的 range 与 metric 仍要被 Core paginator 全量校验** —— 见 C 的第一句。
- **测试不得钉系统字体的绝对浮点或精确换行位置**；钉的是：范围覆盖、storage boundary、窄宽与宽宽的大小关系、重复调用一致、以及**真实 end-to-end 至少跨两页**。

## E. 阶段

| 段 | 内容 |
|---|---|
| **R0** | 本 ADR + `CONTEXT.md` 的两个词 + 计划里的 E3 段。**纯文档。** |
| **R1** | Core 侧类型 / 协议 / paginator + **fake backend** 的证伪测试；单独提交，推 Draft PR 跑 macOS CI 后停。至少覆盖：empty、one line、exact fit、overflow、spacing 只在行间、**oversized line 合法且单独成页**、stalled、gap、overlap / backward、out-of-bounds、non-boundary、**nonAdvancingRange**、**三种 constraints 错误各自命中**、**natural extent 非 finite 与 `<= 0`**、**inlineExtent 转发 spy**。再加四颗钉：**① constraints 非法时即使 segment 为空也必须报 constraints 错**（优先级）、**② 合法的空 segment 不创建 session**、**③ 走到末尾不会多调一次 `suggestLine`**、**④ `makeSession` 与 `suggestLine` 的错误各自原样传播**（用一个自定义的 `Equatable` 测试错误，证伪「被包装 / 被吞掉」）。**E3 不测试、也不宣称禁则修正。** |
| **R2** | `NagiEngineCoreText` target 与真实 backend + CoreText integration tests；**不做渲染**；CI 后停。 |
| **R3** | README / 计划记录、最终 CI、转 ready、合并前终审。 |

**不得恢复已关闭 PR #2 的 `PageMap` 代码，也不得恢复那份 ADR。**

## Consequences

- **`UnitPageRanges` 只在生成它的那次调用里有意义。** 它不 `Codable`、不 `Hashable`、不持久化；它**不携带 `LayoutSignature` 或 generation**，因此**两次碰巧相同的 ranges 不是同一次 layout identity** —— 那只是两个值相等。未来的 `PageMap` 必须连同 signature / generation / completeness **建立自己的身份**，不能拿这里的相等当依据。
- **`LineMeasurement` 同样不 `Codable`、不 `Hashable`、不持久化**，并且只在**生成它的那个 session 与 segment** 里可解释：一个 offset 离开那段文本就没有含义。
- 旧仓 ADR-0008 / 0009 把**页码**定成排版的输出：`UnitPageRanges` 里的顺序号只在本 unit 的这次分页内有意义，**不是** publication 页码，也不构成「第 47 页 / 共 N 页」那套语义。
- **行被压成一个 `Double` 是范围限定的简化**：旧仓 ADR-0005:65-73 要求 `LineBox` 携带 `baseAscent` / `baseDescent` / annotation 的 before/after extent / effective ascent+descent。E3 只做横排、单一字体、无 ruby，所以一个数够用；**ruby 或竖排会需要更宽的类型，那时不得把这里的 `Double` 当作既成事实。**
