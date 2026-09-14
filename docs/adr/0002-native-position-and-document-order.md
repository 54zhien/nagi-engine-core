# Native Position 与文档序

**Status:** accepted

位置的身份与位置的次序是两件事。

次序那一条不是本仓自己定的：**旧验证仓** `54zhien/nagi-engine` 在 commit `47c071ad0cc99685cd6b51cfca5160b193706546` 的 `docs/adr/0003-identity-scheme.md` 里已经把文档序键定成「单元在 manifest reading order 中的序号 + 单元内绝对 `utf16Offset`」。**本 ADR 把那条结论纳入 Core** —— 因为本仓的 `NativePosition` 里还住着一个 `NodeID`，需要把两者的形状各自定下，并说明它们**互不表达**。

## NodeID

**Core 里的 `NodeID` 是一个不透明的字符串身份。**

- 类型：`RawRepresentable`、`Codable`、`Hashable`、`Sendable`，`rawValue` 是 `String`。
- **访问级别**：`public struct`、`public let rawValue`、`public init(rawValue:)`。身份是**模块外构造出来的** —— ingest 造它 —— 所以构造入口必须公开；一个只读得出、造不出的身份类型没有用。
- 比较：**直接采用 Swift `String` 的 `==`** —— 不额外做 href 归一化、大小写折叠、trim，也不做百分号处理。**不承诺逐字节比较**：Swift 的字符串相等对 Unicode 规范等价序列可能判相等，而那是字符串相等本身的层，不是这个类型要重定义的东西。归一化是 href 的事 —— href 是路由信息，不是身份。
- `Codable`：**单值字符串**，不是键控的 `{ "rawValue": … }`。声明 `Codable` 就已经决定了 wire shape，那就在这里决定，不留给合成去替我们决定。
- **怎么生成一个稳定的 `NodeID` 属于 ingest / identity scheme，不属于 Core。** 旧仓阶梯（显式 id → source-local path → fingerprint → …）是实现那个 scheme 的一条路；Core 不解释它内部取了哪一级，也不依赖它取哪一级。
- **`NodeID` 不表达文档序。** 它回答「哪一个元素」，不回答「在文档的哪里」—— 后者是偏移的事。把次序挂在身份上，是旧仓 provisional 阶段的病根。

## NativePosition

**不可变的 `Codable` / `Hashable` / `Sendable` 值**，字段恰好三个：

```swift
DocumentUnitID unitID
NodeID         nodeID
Int            utf16Offset
```

- **没有 `documentOrder` 字段**，也没有任何第二份次序编码：次序由 `(unitIndex, utf16Offset)` 导出，存一份就是同一件事说两遍。
- **不给 `Comparable`。** 合成出来的 `Equatable` 含 `NodeID`，一个忽略它的 `<` 会得到 `a != b` 而双向 `<` 皆 false —— 三值互斥的语义被打破。排序由下面的比较函数承担。
- **访问级别**：`public struct`、三个 `public let`、一个公开的 `public init(unitID:nodeID:utf16Offset:)`。
- **那个 initializer 不校验 `utf16Offset`。** 负值与越界不是次序问题；而且一旦在这里校验，一个刻意不带正文的 manifest 就得预先知道每个单元的长度。

## 次序

- **`DocumentOrderKey(unitIndex, utf16Offset)`**：`internal`、**非 `Codable`**、不持久化。它只在生成它的那份不可变 manifest snapshot 内可比较；将来若要越过 owner 公开传递，必须给它一个 **manifest scope identity**，裸二元组不够。
- **公开面是一个三值结果**，不是 `<`：

  ```swift
  public enum DocumentOrderComparison: Equatable, Sendable {
      case before, sameCoordinate, after
  }
  ```

  **不带 `Codable`，也不带 `Comparable`**：它是一次比较的**结果**，不是要存下来的东西，也不是一个可以再排序的坐标 —— 给它 `Comparable` 会让人以为次序是它自己的属性，而次序属于位置。

- **`DocumentManifest.compareInDocumentOrder(_ lhs: NativePosition, _ rhs: NativePosition) -> DocumentOrderComparison?`**
  - 任一 `unitID` 不在 manifest 中 ⇒ **`nil`**。没有键就没有次序 —— 这是**已定义的**结果，不是崩溃，也不是「排到最后」。
  - 同单元、同偏移 ⇒ **`.sameCoordinate`**，且 **`NodeID` 不破平局**。那是同一个文本坐标，不是两个需要分出先后的位置。
  - **manifest 重排会改变跨单元的结果**，这是**正确**的：次序是**文档的函数**，不是位置自带的常量。
  - **排序层不验证 offset**（按本 ADR 的职责边界）：越界归 `PositionResolver` 与将来的 PageMap containment。
- 键不出模块，`NativePosition` 也不带 `Comparable`；两者之间的唯一通道就是上面这个函数。

## PageMap 后置

`PageMap` **暂不在本仓实现**。它要等这些定案：**Native Position**、**页范围与单元长度**、**Layout Signature / generation**、**完整性状态**，以及**部分分页下的 Page identity**。

在那之前把它做出来，做的是 `CONTEXT.md` 里一个**完成态**术语的一半 —— 被关闭的 PR #2 是这条路的一次实测，四条原因记在 `tasks/bootstrap-plan.md`。
