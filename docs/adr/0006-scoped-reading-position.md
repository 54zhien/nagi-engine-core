# 带作用域的阅读位置，不强制转换成 Locator

**Status:** accepted

原生 unit-local UTF-16 与 Readium Locator 不是同一数轴。App 的恢复协议采用带标签的原生或 Readium payload，而不要求原生排版产出未经证明的「等价 Locator」。本决定修订 ADR-0005 的宿主输入约束，不改变任何 Core/CoreText 公开 API、分页、绘制或命中行为。

## 依据与范围

- Core 基线：`54zhien/nagi-engine-core@3c1d8172997d314f6df5e2daf8c440d06bcba3ef`，`NativePosition` 为 unitID / nodeID / utf16Offset，构造不校验文本，`PrimaryTextSegment` 提供 storage boundary 判定。
- App 基线：`54zhien/Nagi@ff89ea325c1cd45b332bdee47dd61fa5628998cd`。`TXTIngestDocument` 已产出版本化输入与四字段 `TXTInputScope`；`ReaderArchitecture.swift` 的 `ReadingPosition` 仍仅有 Locator JSON，App 仍只通过派生 EPUB / Readium 阅读 TXT，尚未依赖 Core。
- 研究仓本地执行契约 `tasks/e5-s2-input-restoration-contract.md` 的 B、C、D.3 定下这次修订；本 ADR 把需要跨仓保留的决定完整写在这里，不依赖该未提交执行单可从远端取到。

本次只定边界，不引入 Core 的 `PublicationPosition`、scope、恢复记录或桥接类型。下列 App 协议是后续实现要求，不是已经上线的能力。

## 决定

1. 书库阅读位置由 App 所有，不进入 Manifest、Page Map 或 Page Scene。恢复记录按标签携带 payload；只保存和路由 payload 不等于解释坐标或执行 Location Bridge。
2. 原生 payload 必须连同输入作用域使用：Book.id、原始源字节 SHA-256、ingestRevision、有序 manifestDigest。源字节、规则或清单变化时，旧偏移不能仅凭相同 ordinal 继续作为 exact。裸 `NativePosition` 的 Codable / Hashable 不赋予它跨作用域的有效性，也不是独立持久化许可。
3. 原生精确恢复须先核对完整作用域，再核对 unit / node 与当前文本的合法 storage boundary。单节点 TXT 的 node 必须是当前 ingest 注入的那个；不由排序 API 承担合法性校验，不以 caret 吸附、最近位置或引文搜索冒充原坐标验证。
4. Readium payload 使用实际已知的源与派生资源证据。旧 Locator 缺少这些证据时必须保持 legacy/unverified，不能回填虚构摘要。来源与资源验证通过只证明 renderer-local 恢复资格，不证明与原生字符等价；Locator 的解析及执行仍由 App / Readium 负责。
5. 恢复结果区分 exactNative、rendererLocal、approximate（方法与原因）及 unavailable（原因）。原生与 Locator 之间只有经同源作用域、变换版本及真实映射证明，且目标能表达并兑现该坐标，才可称 exact；其余明确降级或拒绝。Location Bridge 是解释并转换两套坐标的边界，不保证全域或可逆。
6. 百分比是带 metric 的导航提示，不是精确坐标；不得将 progression 乘文本长度，或将 UTF-16 偏移塞入 Locator position/progression 字段。已验证同源的章节路由至多是 chapter-level approximate，不是字符级桥。
7. pageIndex、layout signature、surface generation 不是持久坐标。换布局重算包含关系：页范围半开，普通页界归同单元后一页；合法 unit EOF 归该非空单元最后一页；空单元无页时明确 unavailable。这是后续恢复策略要求，不表示已实现 Page Map 或完整 Position Resolver。
8. unavailable 不删除旧记录。恢复、自动初显与预热不算用户进展；后续单一 writer 必须拒绝失效会话、迟到与取消回调，并以单调 revision 防止较老 renderer 快照回放。近似恢复的 provenance 不因后来发生有效用户导航而被追认为 exact。

## 取舍与门禁

否决 Locator-only：它迫使没有真实映射的 renderer 猜造坐标。也否决用百分比统一数轴：那会把有损导航伪装为精确恢复。接受带标签协议的额外分支与显式不可用结果，以保留证据和用户旧记录。

先实现不写数据库的 App 恢复纯策略，再以真实磁盘冷/暖重开验收决定 wire schema、迁移、单一 writer 与资源失效。通过这些门禁前，不启用原生持久写入、renderer 切换或用户引擎开关。本契约修订不改变现有 Book 字段、旧 Locator 读取行为、Readium fork 或任何用户数据。
