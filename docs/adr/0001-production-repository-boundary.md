# 生产仓边界

**Status:** accepted

本仓是 Nagi 的**生产实现**，与架构验证仓 `54zhien/nagi-engine` 分开。理由不是洁癖：实证代码与生产代码的合格判据不同 —— 前者要能**证伪**一个假设，后者要能**长期承载**它。同一个仓同时满足两者，两边都会退化。

## 决定

- **领域名沿用旧仓已合并的称呼。** `DocumentManifest` 与 `ContentFragment` 不改名 —— 两个仓里的这个词必须指同一件事，否则证据与实现会对不上，而「对不上」正是 ADR 存在的理由。

- **`NagiEngineCore` 不依赖 `ReadiumNavigator`、`SwiftSoup`、`CoreText` 或任何 UI 框架。** 位置桥接、XHTML 解析、字形与排版各自是独立的关注点。把它们拉进核心 target，就是把「核心能不能编译」交给三个外部世界的版本节奏。

- **未来的适配器与排版后端各自成 target**，通过协议与核心相接。核心定义它们必须满足的形状，不定义它们的实现。

- **与既有类型同名时靠 module qualification 消歧，不加 `Nagi` 前缀。** `NagiManifest` 之类的名字是把命名空间问题复制到每一个使用点；`NagiEngineCore.DocumentManifest` 只在一个地方解决它。

- **旧 spike 仓是证据源，不是包依赖。** 本仓不把 `nagi-engine` 列进 `Package.swift`，也不复制它的代码。它提供的是**读数**（ADR 与实测结论），形式是文档。依赖一个证据仓，等于让证据的每一次整理都变成生产代码的破坏性变更。

## Consequences

- 核心 target 的依赖图从**一个 target**起步，并保持只有它自己。
- 本仓第一批是纯值：`DocumentUnitID`、`DocumentUnit`、`DocumentManifest` 与错误类型。没有 I/O、没有 async、没有平台类型 —— 这也是 `Package.swift` 不声明 `platforms:` 的原因。
- 旧仓继续只做架构验证（其 `README` 写明它「不是引擎本体，也不会长成引擎」）；它的结论以文档形式进入本仓的设计，而不是以代码形式进入本仓的依赖图。
