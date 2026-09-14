# PageMap 的边界与两层查找

**Status:** accepted

`CONTEXT.md` 把 Page Map 定义成「一次排版产出的 Native Position ↔ 页序号的索引，可部分完成，可由 Layout Signature 完全重建的派生缓存」。那是一个**完成态**的词。本步交的是它的第一半 —— **排序那一半**：一个位置落在哪一页，不涉及任何几何。

ADR-0008 里 `PageMapSnapshot` 引用的三个类型（`PageDescriptor`、`LayoutGeneration`、`NativeDocumentPosition`）在两个仓里**都没有定义过**，所以本步不照抄那份 sketch，只做它确有的那一句：**查找路径是两层的**。

## 决定

- **PageMap 是纯值，页边界由调用方给。** `NagiEngineCore` 不依赖 CoreText、SwiftSoup、Readium 或任何 UI（ADR-0001），排版后端将来是独立 target。核心里的 PageMap 因此不测量文字：它拿到「每页在哪里断开」，回答「这个偏移落在第几页」。

- **键是 `DocumentOrderKey(unitIndex, utf16Offset)`，`internal`、非 `Codable`、不持久化。** ADR-0003 要求它只在生成它的那份不可变 manifest snapshot 内可比较，越过 owner 公开传递就必须带 manifest scope identity。**这里它不越过 owner** —— 只在模块内由 manifest 派生、被 PageMap 使用，所以那条要求不被触发，而不是被绕过。PageMap 自己持有那份 manifest，键的作用域是结构性的，不靠约定。

- **查找是两层的。** 先由 `key.unitIndex` 选中单元（第一层），再在该单元内二分找最后一个不晚于 key 的页起点（第二层）。两层是 hard pagination boundary 的直接推论：页落在一个单元内，「哪个单元」与「单元内哪里」可以分两步问。

- **拒绝作答，不编造。** 没有页信息的单元 ⇒ `nil`。这与 spike 的 `fixedPageOrdinal` 在 `pageRanges == nil` 的可重排资源上拒绝作答是同一条规则，而且那条规则是**被测量过**的：`progress-layout-independence` 要求可重排资源拿到页序号的次数为 0。

- **平局：偏移正好落在断开处 ⇒ 属于那一页**（页从它开始），与 spike 的 `FixedPageOrdinalAxis` 的半开区间一致。要说清它与 spike 的 `unitIndex(covering:)`「前一个赢」**不是同一条规则** —— 后者回答单元跨度，前者回答页；同一个文件里两种都对。

- **末尾没有洞。** spike 的 `FixedPageOrdinalAxis` 需要一条特判（`if byte == byteCount { return last }`），因为容器知道长度，半开区间容不下文本末尾那个偏移。**core 不知道单元长度**，用的是「≥ 最后一个起点 ⇒ 最后一页」，那个洞结构上不存在。

## 为什么回答的是单元内页序号，不是全书页号

「第 47 页」是各单元页数的前缀和，而前缀和需要知道**它前面的单元是否已经分页完成** —— 那是 ADR-0008 的 `isComplete` / `frontier` 那一轴，本步没有它。

在部分完成的图上把扁平下标当全书页号，**前面某个单元缺页信息时序号会静默少算**：得到的数字看起来完全合理，指的是别的页。单元内序号 + 两层查找在结构上不会犯这个错。

## 为什么键的比较在单元内退化成偏移

在一个单元内部比较两个键时，`unitIndex` 分量恒相等，比较只剩下偏移。这不是冗余字段：单元那一层已经由外层下标回答完了，把同一个事实再塞进每一次比较，正是本仓说的「同一件事的第二份真相」。

## Consequences

- `PageMap` 是 `Sendable` 值类型；构造时**一次性**把页起点解析成键，查询不再解析。
- 「这个单元没有页信息」与「这个单元还没分页」目前**用同一种拼法**表达（字典里没有它）。E2 引入完整性模型时，两者可能需要分开。
- `pageBreaks` 的升序与正值是**前置条件**，本步不校验 —— 与 `DocumentManifest` 不对字段做校验保持一致。代价是非升序输入会静默给错答案，收益是核心不替调用方定策略。
- **负偏移回答 `nil`**（不是位置就说不出来）；**超过文本末尾的偏移无法检查**，因为 manifest 不带长度 —— 那是 `PositionResolver` 的事。
- `CONTEXT.md` 的 Page Map 词条**不改**：它描述完成态，本步是它的一半。这处落差记在这里，不靠改词表抹平。
