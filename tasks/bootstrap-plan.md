# 建仓计划（E0 基线）

**方案由 Codex 给出，Claude 执行。** 本文件记录本仓从零起步的顺序：先立边界，再立值模型，再让真实消费者决定形状。

## E0 —— 建仓骨架与 `DocumentManifest` 最小生产基础（已完成）

**产出**：本仓的十一个文件 —— `Package.swift`、`LICENSE`、`README.md`、`CONTEXT.md`、`.gitattributes`、`.gitignore`、`.github/workflows/ci.yml`、`docs/adr/0001-production-repository-boundary.md`、`Sources/NagiEngineCore/DocumentManifest.swift`、`Tests/NagiEngineCoreTests/DocumentManifestTests.swift`、本文件。

**这一版的形状是**：`DocumentUnitID`（`RawRepresentable` / `Codable` / `Hashable` / `Sendable`，`rawValue` 是 `String`）、`DocumentUnit`（`id` + `href` + `mediaType`，**不含正文**）、`DocumentManifestError.duplicateUnitID`、`DocumentManifest`（公开只读 `readingOrder`，构造时一次建表，重复 ID 立即抛错，`readingOrderIndex(of:)` 零基 O(1)）。

**边界**：本仓不依赖 Readium、SwiftSoup、CoreText 或 UI；旧仓 `54zhien/nagi-engine` 是**证据源不是包依赖**。见 `docs/adr/0001`。

**没做的**：不实现 `NodeID`、`NativePosition`、`DocumentOrderKey`、`PageMap`、`PositionResolver`、`DocumentStore`；`DocumentManifest` 暂不 `Codable`；不公开索引 map；不做 href 查找；不加字段校验。

## E1 —— `DocumentOrderKey` 与它的真实消费者 PageMap（已完成）

**交付**：`internal` 的 `DocumentOrderKey(unitIndex, utf16Offset)`、`DocumentManifest.orderKey(of:at:)`、公开的纯值 `PageMap`（两层查找、拒绝作答）与 `PageMapError`。契约见 **ADR-0002**。

**判据达成**：键**有真实消费者** —— PageMap 在单元内对页起点做二分。这不是「先写好比较函数再去找人用」，键的 `Comparable` 每一次查询都在被调用。

**形状来自旧仓已合并的契约**（`54zhien/nagi-engine` 的 ADR-0003，commit `47c071ad0cc99685cd6b51cfca5160b193706546`），四条都照做：键是瞬态投影、不是 `NativePosition` 的 `Comparable`；`internal`、非 `Codable`、不持久化；只在生成它的那份 manifest snapshot 内可比较；排序层不校验 offset 合法性。

**本步自己定的三处**（Codex 复审时请重点看）：

1. **输入是「断开处」不是「页起点」** —— 于是「只有一页」= `[]`，「没有页信息」= 单元不在字典里，两种含义各有拼法。
2. **回答单元内页序号，不是全书页号** —— 部分完成的图上做前缀和会静默少算。
3. **负偏移回答 `nil`**，超过末尾的偏移无法检查（manifest 不带长度）。`pageBreaks` 的升序与否**不校验**，只写为前置条件。

## E2 —— 完整性模型，以及全书页号

E1 之后才谈。最自然的下一刀是 ADR-0008 的 `isComplete` / `frontier` 那一轴：**「这个单元没有页」与「这个单元还没分页」目前是同一种拼法**，而全书页号必须能把两者分开。**顺序不是日程，是依赖**：每个值模型的形状应由它的消费者倒推。

## 一条约束

**计划写在这里，不写进 `CONTEXT.md`。** 词汇表只定义术语的含义与边界；把阶段、待办、实现顺序写进去，它就不再是词汇表，而两个用途会互相污染。
