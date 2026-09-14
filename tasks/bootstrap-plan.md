# 建仓计划（E0 基线）

**方案由 Codex 给出，Claude 执行。** 本文件记录本仓从零起步的顺序：先立边界，再立值模型，再让真实消费者决定形状。

## E0 —— 建仓骨架与 `DocumentManifest` 最小生产基础（已完成）

**产出**：本仓的十一个文件 —— `Package.swift`、`LICENSE`、`README.md`、`CONTEXT.md`、`.gitattributes`、`.gitignore`、`.github/workflows/ci.yml`、`docs/adr/0001-production-repository-boundary.md`、`Sources/NagiEngineCore/DocumentManifest.swift`、`Tests/NagiEngineCoreTests/DocumentManifestTests.swift`、本文件。

**这一版的形状是**：`DocumentUnitID`（`RawRepresentable` / `Codable` / `Hashable` / `Sendable`，`rawValue` 是 `String`）、`DocumentUnit`（`id` + `href` + `mediaType`，**不含正文**）、`DocumentManifestError.duplicateUnitID`、`DocumentManifest`（公开只读 `readingOrder`，构造时一次建表，重复 ID 立即抛错，`readingOrderIndex(of:)` 零基 O(1)）。

**边界**：本仓不依赖 Readium、SwiftSoup、CoreText 或 UI；旧仓 `54zhien/nagi-engine` 是**证据源不是包依赖**。见 `docs/adr/0001`。

**没做的**：不实现 `NodeID`、`NativePosition`、`DocumentOrderKey`、`PageMap`、`PositionResolver`、`DocumentStore`；`DocumentManifest` 暂不 `Codable`；不公开索引 map；不做 href 查找；不加字段校验。

## E1 —— `DocumentOrderKey`，由 PageMap 消费

**形状来自旧仓已合并的契约**（`54zhien/nagi-engine` 的 ADR-0003，commit `47c071ad0cc99685cd6b51cfca5160b193706546`）：

- 次序 = **（单元在 manifest reading order 中的序号, 该单元 canonical primary text 内的绝对 `utf16Offset`）**。
- `DocumentOrderKey(unitIndex, utf16Offset)` 是一个**瞬态投影**，**不是** `NativePosition` 的 `Comparable` —— 后者的 `Equatable` 含 `NodeID`，一个忽略它的 `<` 会得到 `a != b` 而双向 `<` 皆 false。
- 它 `internal`、**非 `Codable`**、不持久化；**只在生成它的那份不可变 manifest snapshot 内可比较**，不得跨 manifest 比较。将来若要越过 owner 公开传递，必须给它一个 **manifest scope identity**，而不是继续沿用裸二元组。
- **排序层不校验 offset 合法性** —— 越界偏移归 `PositionResolver` 与 PageMap containment；否则为构造键，轻量 manifest 得预先掌握每个单元的长度。

**E1 的判据**：有一个**真实消费者**（PageMap 的查找）在同一次改动里用上它。先写一个没人调用的比较函数，正是旧仓点名过的「零覆盖词汇」。

## E2 —— 再扩展

E1 之后才谈。**顺序不是日程，是依赖**：每个值模型的形状应由它的消费者倒推，而不是先摆好再去找人用。

## 一条约束

**计划写在这里，不写进 `CONTEXT.md`。** 词汇表只定义术语的含义与边界；把阶段、待办、实现顺序写进去，它就不再是词汇表，而两个用途会互相污染。
