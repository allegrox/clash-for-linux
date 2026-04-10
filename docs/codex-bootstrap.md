# clash-for-linux ｜Codex 首次投喂文档（Bootstrap）

> 用途：这是 **第一次喂给 Codex** 的启动文档。  
> 目标不是讲完整历史，而是让 Codex 先建立**正确项目认识、真实主链认知、修改边界和输出契约**。  
> 最高原则：**以当前代码真实行为为准，不以旧设计、旧记忆、旧残留为准。**

---

## 0. 使用方式

这份文档的定位不是“每轮任务单”，而是 **Codex 的首次基线输入**。

第一次使用 Codex 时，建议只喂三类东西：

1. **这份 Bootstrap 文档**
2. **当前仓库代码**
3. **本轮任务单**

不要第一次就把所有历史设计稿、旧方案、推演过程、聊天记录全部塞进去，否则 Codex 很容易被旧信息污染。

---

## 1. 项目定位

你正在维护的是 `clash-for-linux`。

它不是单纯的安装脚本集合，也不是节点管理小工具。它当前的真实形态是：

> 一个以 **active-only 主订阅编译链** 为核心、以 **runtime 后端抽象** 为底座、以 **shell 体验闭环** 和 **状态 / 诊断系统** 为外壳的本地代理运行平台。

你的默认目标不是发散式重写，而是：

1. 顺着当前真实架构继续收敛
2. 清理旧残留
3. 降低解释成本
4. 提高稳定性
5. 保持主路径简单、优雅、稳定

---

## 2. 当前最高事实

### 2.1 三层架构

```text
Control（控制层）
  ↓
Build（配置编译层）
  ↓
Runtime（运行时层）
```

### 2.2 当前真实主链

当前已不是多订阅 merge 编译，而是：

```text
active 主订阅
→ 下载原始订阅
→ 直接校验
→ 必要时走一次 subconverter
→ normalize_runtime_config
→ test_runtime_config
→ 输出 runtime/config.yaml
```

### 2.3 订阅策略的唯一真相

> **多订阅保存，单订阅激活，active-only 编译。**

含义：

- 可以保存多个订阅源
- 任意时刻只有一个 `active` 主订阅
- `generate_config()` 只处理当前主订阅
- 不再把多个订阅 merge 进最终运行配置

### 2.4 旧残留不是主设计

下列内容即使还残留在代码或配置里，也**不是未来设计中心**：

- `subscriptions.yaml` 中的 `mode` / `selected`
- `.env` 中的 `BUILD_MIN_SUCCESS_SOURCES`
- 旧 merge / repair / explain / helper 时代的兼容逻辑

结论：

> **优先让代码继续向 active-only 收口，而不是把旧 merge 逻辑修得更复杂。**

---

## 3. 协作方式

### 3.1 三方分工

- 用户
  - 负责真实体验
  - 负责产品裁决
  - 负责判断哪里不顺、哪里不符合预期、哪里应该改
- ChatGPT
  - 负责问题收敛
  - 负责任务翻译
  - 负责边界设计与风险约束
  - 负责决定这轮任务更适合“目标导向型”还是“定点收口型”
- Codex
  - 负责搜索代码
  - 负责定位影响链
  - 负责执行真实修改
  - 负责最小闭环验证

### 3.2 一条默认原则

默认不是：

- 用户把每个文件、每个函数、每一行都指定死
- Codex 只负责机械照改

也不是：

- 完全放手让 Codex 自己猜需求、自己决定方向

而是：

> **用户给体验裁决，ChatGPT 给任务框架和边界，Codex 负责自己定位并修改；只有在高风险收尾时，才明确指定它改哪里。**

---

## 4. 任务模式

### 4.1 默认优先：目标导向型

适用场景：

- 根因未完全锁定
- 只知道现象或目标
- 希望 Codex 发挥搜索与判断能力
- 当前最怕的是“找不到根因”，不是“它改太多”

表达方式应以这四项为主：

- 目标
- 约束
- 验收
- 输出格式

不要一上来就指定：

- 改哪几个文件
- 删哪几个函数
- 哪几行必须怎么写

### 4.2 高风险收尾：定点收口型

适用场景：

- 根因已经锁定
- 旧链路已经明确
- 当前任务重点是防止扩散修改
- 这轮任务本质是“清残留 / 删死代码 / 做收尾”
- 当前最怕的是“改散、改多、顺手重构”

只有这类情况下，才应该明确指定：

- 允许修改哪些文件
- 哪些函数或旧链路要删
- 哪些行为绝对不能动
- 验收 grep / bash -n / status 要怎么做

### 4.3 模式切换规则

默认先问：

```text
这轮任务更像“定位问题”，还是“清理残局”？
若更像“定位问题”：
用目标导向型
若更像“清理残局”：
用定点收口型
```

---

## 5. 目录与关键文件职责

### 5.1 根目录

- `install.sh`：安装入口，负责初始化、依赖准备、命令入口安装、运行后端安装、必要时生成配置、安装后验证、安装摘要
- `uninstall.sh`：卸载入口，支持普通卸载、`--purge-runtime`、`--dev-reset`
- `.env`：运行参数来源之一，负责内核类型、订阅地址、端口、下载参数、版本等

### 5.2 `scripts/core/`

- `common.sh`：公共能力中心；路径初始化、环境兼容、下载系统、缓存、命令入口安装、shell 注入安装、状态读写
- `config.sh`：配置编译中心；订阅读取、订阅缓存、active-only 构建主链、运行配置规范化、构建记录、订阅健康、端口裁决
- `runtime.sh`：运行时能力；yq / mihomo / clash / subconverter 解析与安装、配置回退、Tun 检查
- `proxy.sh`：controller / proxy 相关能力；代理地址、controller API、策略组读取与切换
- `clashctl.sh`：主 CLI 控制面；`add/use/select/on/off/status/doctor/ui/tun/config/profile/sub/proxy/update/upgrade/dev` 等命令实现
- `alias.sh`：shell function 劫持层；提供 `clashctl` / `clashon` / `clashoff` / `clashproxy` / `clashselect` 等体验闭环
- `update.sh`：Git 更新与运行时依赖同步

### 5.3 `scripts/init/`

- `systemd.sh`：systemd 后端
- `systemd-user.sh`：user systemd 后端
- `script.sh`：script fallback 后端

### 5.4 `config/`

- `subscriptions.yaml`：订阅集合；当前真实核心字段是 `active` 和 `sources`
- `template.yaml`：基础模板
- `mixin.yaml`：运行配置补丁
- `profiles.yaml`：profile 配置

### 5.5 `runtime/`

`runtime/` 是**唯一运行时容器**，不是源码目录，也不是静态资源目录。

典型内容：

- `runtime/config.yaml`
- `runtime/config.last.yaml`
- `runtime/bin/`
- `runtime/logs/`
- `runtime/cache/`
- `runtime/tmp/`
- `runtime/install.env`
- `runtime/build.env`
- `runtime/runtime-events.env`
- `runtime/tun.env`

原则：

> 一切运行态文件尽量收口到 `runtime/`，不要散落回项目根目录。

---

## 6. CLI 与用户主路径

### 6.1 主路径

```text
clashctl add
clashctl use
clashctl select
clashctl on
clashctl off
clashctl status
clashctl doctor
```

### 6.2 关键命令组

当前 CLI 至少包含：

- `add` / `use` / `ls` / `health`
- `select` / `on` / `off` / `status` / `logs` / `doctor`
- `ui` / `secret` / `tun`
- `config` / `mixin` / `profile`
- `sub` / `proxy`
- `upgrade` / `update` / `dev`

### 6.3 Shell 体验闭环

当前 shell 层不是 alias，而是 function 劫持。

必须保持：

- `clashctl on` 统一走真实主链
- on 成功后，再为当前 shell 注入 `http_proxy` / `https_proxy` / `all_proxy` / `NO_PROXY`
- off 前先清理 shell 代理，再调用真实 off
- shell 层不抢 runtime / build 的职责
- shell 被 source 时不自动偷偷执行代理动作

结论：

> **shell 层只负责体验闭环，不负责偷偷维护后台状态。**

---

## 7. Build 规则

### 7.1 主函数链

围绕以下函数理解构建主链：

- `resolve_build_sources()`
- `build_runtime_candidate_from_payload()`
- `fetch_subscription_source()`
- `generate_config()`

### 7.2 必须坚持

- 只处理当前 `active` 且 `enabled=true` 的主订阅
- `clash` 类型先直下、直校验，失败时只允许一次 `subconverter` fallback
- `convert` 类型走转换后再校验
- 运行时配置必须经过 `normalize_runtime_config()`
- 最终必须经过 `test_runtime_config()`
- 失败必须明确留证据

### 7.3 不要再做

- 不要恢复多订阅 merge 进 `runtime/config.yaml`
- 不要再引入复杂 repair 流程去修订 YAML 语义
- 不要再围绕“最少成功源数量”设计主链
- 不要把旧 `mode / selected` 拉回主逻辑

### 7.4 失败策略

当前失败模式应保持为：

> **快速失败 + 明确保留证据**

而不是：

> 深度自动修订 + 隐式容错 + 用户看不懂发生了什么

---

## 8. Runtime 规则

### 8.1 后端抽象

当前运行后端统一抽象为：

- `systemd`
- `systemd-user`
- `script`

统一入口：

- `service_start`
- `service_stop`
- `service_restart`
- `service_status_text`
- `service_logs`

### 8.2 运行原则

- root + systemd 可用时优先 `systemd`
- 普通用户 + user systemd 可用时走 `systemd-user`
- 否则 fallback 到 `script`

### 8.3 配置回退

如果当前 `runtime/config.yaml` 不可用，允许回退到 `runtime/config.last.yaml`，但必须记录：

- 是否触发回退
- 回退时间
- 回退原因

### 8.4 端口原则

- 安装期可以裁决端口
- 运行中尽量不要乱改端口

核心原则：

> **运行中避免再次重写端口，防止搅乱已运行实例。**

---

## 9. 下载系统规则

### 9.1 下载层已经是平台能力

当前支持：

- GitHub 镜像池
- probe + fetch 两阶段
- 最近失败降权
- 冷却期
- 下载成功 / 失败记忆
- 下载缓存
- 非 GitHub 直连下载

### 9.2 修改下载层时的准则

可以做：

- 提高稳定性
- 提高清晰度
- 减少重复代码
- 强化缓存复用
- 提升失败可解释性

不可以做：

- 退回到单镜像硬编码
- 破坏缓存机制
- 在 install / update / upgrade 各写一套下载逻辑
- 无依据引入复杂并发下载机制

原则：

> **下载能力统一，不要分散。**

---

## 10. 状态系统规则

### 10.1 `status` 的定位

`status` 不是简单看 service 是否运行，而是系统聚合判断层。

核心状态：

- `ready`
- `stopped`
- `degraded`
- `broken`

### 10.2 聚合维度

至少参考：

- runtime
- build
- subscription
- risk
- tun
- shell proxy
- controller reachability

### 10.3 设计目标

用户执行 `clashctl status` 时，应直接得到：

- 当前是否可用
- 当前主订阅是谁
- 当前节点是什么
- 风险等级
- 下一步该做什么

本质：

> **面向用户动作决策的解释层。**

### 10.4 `doctor` 的定位

> **status 给结论，doctor 给证据。**

不要把 `doctor` 变成炫技式日志倾倒。

---

## 11. Tun 规则

Tun 是高级能力，不属于默认主路径。

必须保持：

- Tun 必须显式开启
- 不能安装时默认偷偷接管
- `clashctl tun doctor` 应先于 `clashctl tun on`
- 需要考虑 host / container、`/dev/net/tun`、`ip` 命令、内核支持、默认路由是否接管

不要做：

- 安装时自动启用 Tun
- 用模糊逻辑默认打开 Tun
- 在容器高风险环境里静默强开

---

## 12. install / uninstall 规则

### 12.1 install

`install.sh` 必须保持：

- 本体薄
- 主逻辑内化到函数
- 输出线性、简洁、面向用户
- 不在顶层堆解释性文字

理解安装流程：

```text
初始化目录
→ 校验基础依赖
→ 下载 / 准备 runtime 依赖
→ 记录安装环境与计划
→ 安装命令入口与 shell 入口
→ 安装运行后端
→ 必要时引导订阅
→ generate_config
→ post_install_verify
→ print_install_summary
```

### 12.2 uninstall

必须保留三种语义：

- 普通卸载：保留 runtime 数据
- `--purge-runtime`：删除 runtime
- `--dev-reset`：清安装状态，但保留订阅与缓存，方便开发调试

---

## 13. 修改代码时的硬约束

### 13.1 先收敛，再扩展

如果问题可以通过以下方式解决：

- 删除旧代码
- 收紧主链
- 减少分支
- 消灭兼容残留

那就**不要优先加新层、新抽象、新文件**。

### 13.2 不要把旧架构修回主链

旧 merge 时代的字段、函数、注释可以识别、可以建议清理，但不要重新扶正成主设计。

### 13.3 优先最小修改面

除非明确必要，否则：

- 不随意新增文件
- 不随意拆太多函数
- 不随意跨多个模块做风格统一改造
- 不为了“理论更优雅”改坏当前稳定路径

### 13.4 先保用户主路径

任何改动，都优先保护：

```text
install.sh
clashctl add
clashctl use
clashon
clashctl select
clashctl status
clashctl doctor
```

### 13.5 不做静默副作用

禁止：

- 自动改订阅
- 自动启用 Tun
- 自动切换用户关键配置
- 自动恢复代理环境
- 自动引入后台行为但不告知用户

### 13.6 输出风格

当前脚本用户输出风格必须保持：

- 中文
- 简洁
- 线性
- 图标提示
- 不用大段技术日志污染主路径

### 13.7 运行态文件收口

新增运行态文件、缓存、临时文件、状态文件时，优先放到 `runtime/` 下。

---

## 14. 默认工作流程

### 第一步：先确认当前真实行为

优先看：

- 当前命令入口怎么走
- 当前主函数链怎么串
- 最终 override 在哪里
- 当前运行态文件写到哪里

### 第二步：找主链，不找边角

优先锁定：

- `install.sh`
- `scripts/core/clashctl.sh`
- `scripts/core/config.sh`
- `scripts/core/common.sh`
- `scripts/core/runtime.sh`
- `scripts/init/*.sh`

### 第三步：优先做最小闭环修改

先问自己：

- 能否只改 1–2 个文件解决？
- 能否删除旧逻辑而不是新增绕路逻辑？
- 能否不增加新的状态分叉？

### 第四步：最后才考虑扩展

只有当前主链确实无法承载需求时，再考虑：

- 新函数
- 新文件
- 新抽象

---

## 15. Codex 输出契约（默认）

### 15.1 执行模式

- 默认直接修改代码，不停留在“建议修改”或“展示方案”
- 任务明确时不需要再次征求确认
- 优先执行，而不是解释

### 15.2 默认输出内容

未被明确要求展开时，只保留四部分：

1. 已修改文件列表
2. 每个文件改动说明（1–2 句）
3. 静态 / 运行验证结果
4. 剩余问题或风险点

### 15.3 禁止输出内容

在未被明确要求时，禁止：

- unified diff
- patch / 补丁块
- 大段代码
- 冗长解释
- 多方案对比

### 15.4 例外开放条件

只有用户明确提出以下请求时，才允许突破限制：

- “给我 diff”
- “给我具体代码”
- “展开某个函数实现”
- “详细解释改动”

### 15.5 修改策略约束

- 优先最小修改面（1–2 个文件解决问题）
- 优先删除 / 收口旧逻辑，而不是增加新逻辑
- 不允许顺手重构无关代码
- 不跨模块做风格统一改造

### 15.6 主路径保护

任何修改不得破坏：

```text
install.sh
clashctl add
clashctl use
clashctl on
clashctl select
clashctl status
clashctl doctor
```

---

## 16. 每轮任务单应该怎么下

这份 Bootstrap 只负责建立基线，**不替代每轮任务单**。

每轮任务单必须至少包含：

- 问题现象
- 根因判断（如果已知）
- 改动目标
- 改动边界
- 明确不要动的地方
- 验证方式
- 输出格式

如果这轮任务是“定位问题”，优先用目标导向型任务单。  
如果这轮任务是“清理残局”，再用定点收口型任务单。

---

## 17. 最终目标

这个项目后续阶段的重点不是继续堆功能，而是：

> **清旧架构，压缩主链，降低解释成本，让代码与真实设计彻底一致。**
