# Nagi Engine Core

Nagi 自研阅读引擎的**生产核心**。本文件是词汇表，只定义术语的含义与边界。设计决定记在 `docs/adr/`。

## Language

### 位置

**Publication Position**:
由 Readium `Locator` 承载的、与排版无关的 publication 级坐标。
跨引擎、跨会话、跨设备同步的身份，也是 Nagi 与 Readium 之间唯一共享的位置语言。
_Avoid_: Locator, position, 阅读位置, 页码

**Native Position**:
Nagi 排版内部的精确坐标 —— 内容单元 + 节点 + canonical primary text 的 UTF-16 偏移。
服务于文字选择、字形命中、批注精确区间、分页边界。
_Avoid_: offset, 光标位置, DocumentPosition

**NodeID**:
Native Position 里的元素身份 —— 一个**不透明**的字符串，按字符串自身的相等语义比较，不套用 href 的归一化规则。
它回答「哪一个元素」，**不表达文档序**；怎么生成一个稳定的 NodeID 属于 ingest / identity scheme。
_Avoid_: 元素下标, DOM path, 解析顺序, 指纹

**Document Order**:
两个 Native Position 在文档中的先后 —— 单元在 Document Manifest 的 reading order 中的序号，再是单元内 canonical primary text 的绝对 UTF-16 偏移。
它是**文档的函数**，随 reading order 重排而变，不是位置自带的常量，也不持久化。
_Avoid_: 页码, 全局偏移

**Location Bridge**:
Publication Position 与 Native Position 之间的双向转换。它是唯一被允许同时认识这两个坐标系的组件。
_Avoid_: 转换器, Adapter, Mapper

**Page Index**:
当前排版下某一页的序号。**是输出，不是真相来源** —— 任何持久化数据都不得以它为主键。
_Avoid_: 页码, page number

**Publication Progress**:
`0.0...1.0` 的导航用标量，由各格式自己的 metric 产出。
**数值本身不构成位置** —— 它必须连同产它的 metric 才指得向某处；同一个 `0.5` 在不同的 metric 下是不同地方。
**它是导航元数据，既不是身份，也不是持久化坐标。精确的阅读位置恢复不得经由它往返。**
_Avoid_: 进度, 百分比, percent

### 锚定

**Anchor**:
一段内容的可持久化引用。由位置、引文与上下文共同构成，而非单一偏移。
_Avoid_: 书签, bookmark, 高亮

**Position Resolver**:
回答「这个偏移合法吗、该吸附到哪里」，按用途采用不同的文本边界策略。
_Avoid_: 校准, normalize

**Anchor Validator**:
回答「这个位置现在指的还是原来的内容吗」。判定失败即废弃该锚，绝不静默指向别处。
_Avoid_: 检查, 校验

**Reanchor Service**:
原锚失效后，凭借引文与上下文模糊重新定位。它解决的是跨版本、跨来源恢复 —— 与身份稳定性**不是同一个问题**。
_Avoid_: 恢复, 重定位

### 文档

**Document Manifest**:
一本书的轻量完整清单 —— 元数据、内容单元目录、导航树、版本号。不可变、可跨线程传递。
它不包含正文。
_Avoid_: NagiDocument, Publication, Book

**Document Unit**:
按 publication reading order 排列的、独立可寻址的内容单元。**这是身份域。**
EPUB 通常是一个 spine item；TXT 是整本或合理的解析分块。**它不承诺可流式解析。**
_Avoid_: Section, 章节, spine item, 文件

**Content Shard**:
物化、解析调度、缓存与排版调度的单元。**这是处理域。**
Shard 身份永远不得进入 NodeID、书签、批注或 Native Position。
_Avoid_: Chunk, 分块, 片

**Document Store**:
按位置惰性物化正文的组件。文档内容经它取出，而不是从 Manifest 直接读取。
_Avoid_: 缓存, 数据库

**Content Fragment**:
一次物化产出的局部 IR —— 排版引擎的直接输入。
_Avoid_: DocumentFragment（与 DOM 同名，勿混用）, 片段

**Primary Text Stream**:
所有 Native Position 偏移所依据的那一条规范文本 —— 由各单元自己的规范文本按 reading order 直接拼接而成。
偏移在**它所在单元的那一段内**是绝对的；出版级坐标是由它**导出**的 metric，不是位置。
注音（`<rt>` / `<rp>`）与被折叠的空白**不占**它的数轴。
_Avoid_: 正文, raw text, 原文

### 排版

**Layout Signature**:
一次排版的身份 —— 影响分页的参数集合（viewport、字体及其指纹、字号、行距、边距、书写模式、locale…）。
任一参数变化即代表一次新排版，旧的 Page Scene 与 Page Map 全部失效。
_Avoid_: 配置, Preferences, Settings

**Page Map**:
一次排版产出的 Native Position ↔ 页序号的索引。**可部分完成**，是可由 Layout Signature 完全重建的派生缓存。
_Avoid_: PageCache, 目录, 分页表

**Measured Line**:
排版后端在 unit-local primary text 上，对一个连续 consumed range 给出的候选行，连同它在 block 轴上的自然 extent。
**候选行不是页边界** —— 它是后端的一次测量；页边界由引擎自己决定。
_Avoid_: 行, line box, 断行点, 页边界

**Unit Page Ranges**:
在一组约束下，一个完整 Document Unit 的**有序、unit-local、半开**页范围序列。
它是 **transient** 的 —— **不自带 Layout Signature**，只对生成它的那次调用有意义；它是未来 **Page Map** 的**输入，而不是 Page Map**。
_Avoid_: PageMap, Page Cache, 分页表, 持久页表

**Page Scene**:
一次排版条件下某一页的视觉几何结果 —— 这一页有哪些字形、图像，各自在哪。
不认识 EPUB/MOBI，不承载持久阅读位置，不承载批注。**当前可见页的交互必须完全同步** —— 它自带完成命中测试所需的全部局部映射。
_Avoid_: Page, 页面, 截图, UIImage

**Page Surface**:
Page Scene 的一次渲染结果（像素或纹理）。翻页与转场系统唯一认识的东西。
_Avoid_: Snapshot, 截图, Texture

**Flow Boundary Policy**:
分页是否允许跨越内容单元。v1 取 hard（页不跨单元）。
_Avoid_: 分页边界

### 运行时

**Reader Presentation Engine**:
阅读呈现的抽象。原生引擎与兼容渲染器是它的两个实现，二者共用同一套位置系统。
_Avoid_: Renderer, Navigator

**Native Capability Detector**:
在打开一本书时判定其内容是否落在 Nagi CSS Profile 之内，决定交给原生引擎还是兼容渲染器。
_Avoid_: 检查, Feature detection
