# Xray-2go 全量重构实施计划

> 状态：计划已冻结，尚未开始代码重构
>
> 目标：在不破坏现有用户可见契约的前提下，逐步重构安装控制平面、状态管理、配置应用、服务/Tunnel/防火墙副作用和交互入口。
>
> 执行方式：每一个切片严格执行 `RED → GREEN → REFACTOR → 全量验证 → 独立提交`。未完成当前切片的验收，不进入下一切片。

## 1. 结论与总体策略

当前项目应进行全量结构重构，但不采用一次性推倒重写。

重构的“全量”指：

- 重新划分职责边界；
- 统一安装计划、运行时动作和状态提交模型；
- 统一配置、服务、Tunnel、防火墙等外部副作用的事务边界；
- 删除重复实现和旧调用路径；
- 最终将源码拆分为可维护模块，同时继续产出单文件发布 artifact。

不采用以下方式：

- 在现有脚本中继续逐个补 rollback；
- 保留新旧两套实现并用环境变量切换；
- 在 runtime 测试缺失时直接重写核心；
- 先改菜单，再让底层状态和应用逻辑被动适配；
- 为了“整洁”而改动没有运行时或维护收益的代码。

核心迁移原则：

```text
先冻结行为
→ 建立隔离运行态测试
→ 统一运行时动作
→ 让安装计划成为纯 draft state
→ 统一 apply/verify/commit/rollback
→ 收敛协议与插件边界
→ 收敛菜单与 dispatcher
→ 最后拆源码并生成单文件发布物
```

## 2. 当前基线

计划编写时已重新检查仓库：

- 仓库：`/tmp/xray-2go-audit`
- 分支：`refactor/trojan-main-migration`
- 当前 HEAD：`a4c21d56a6b075ea3e74bf08713f3eab855cbff1`
- 最近提交：`feat: add guided first-deployment wizard`
- 工作树：干净
- 主脚本：`xray_2go.sh`，约 5442 行
- 回归探针：`tests/probe_regressions.py`，约 1035 行
- README：约 138 行
- Bash 函数：约 347 个
- `case` 分支块：约 94 个
- `module_*` 函数：约 65 个
- `install_*` 函数：约 54 个
- `st_get` 调用：约 385 次
- `jq` 调用：约 46 次
- `|| true`：约 212 处
- `2>/dev/null`：约 180 处

当前已确认的主要结构：

- 全局 JSON 状态：`_G_STATE`、`st_get()`、`st_set()`、`st_persist()`；
- 插件运行时：`plugin_load_all()`、`plugin_call()`、`plugin_collect_*()`；
- 配置生成与应用：`config_synthesize()`、`config_apply()`；
- 状态/配置/防火墙组合提交：`_commit()`；
- 服务适配：`svc_exec()`、`svc_exec_mut()`、`svc_apply_xray()`、`svc_apply_tunnel()`；
- 安装计划：`install_plan_*()`、`install_execute_current_plan()`；
- 首次部署向导：`install_wizard_*()`；
- 运行时动作：`module_*()`、`module_dispatch()`；
- 交互层：`unified_menu_*()`、`install_plan_menu()`、主菜单；
- Argo/Tunnel/ACME/防火墙和协议插件均在同一发布脚本内。

当前已验证的安全基线：

```text
bash -n xray_2go.sh       通过
 git diff --check         通过
```

历史记录显示静态探针已覆盖大量既有契约，但部分 runtime 探针曾因固定写入 `/etc/xray2go` 而未在隔离环境执行。这个问题必须在重构开始阶段解决，不能把静态探针通过当作完整运行态验收。

## 3. 范围冻结

### 3.1 必须保持的外部契约（KEEP）

| 类别 | 必须保持的行为 |
|---|---|
| 入口 | 无参数首次运行进入快速部署向导；已安装时进入管理菜单 |
| CLI | `reality` 与 `reality -p <port>` 非交互入口继续有效 |
| 菜单 | 现有模块菜单、返回、取消、确认和主要编号语义保持兼容 |
| 动作 | `module_dispatch()` 现有模块/动作标识保持兼容 |
| 路径 | `/etc/xray2go`、`config.json`、`state.json`、`plugins` 等路径保持兼容 |
| 服务 | `xray2go`、`tunnel2go` 服务名保持兼容 |
| 平台 | systemd 与 OpenRC 的支持边界保持兼容 |
| 协议 | Argo、FreeFlow、Reality、VLESS-TCP、SOCKS5、VLESS-XHTTP-H3、CF Origin 的现有能力保持兼容 |
| Argo | VLESS + WS/XHTTP；Trojan + WS；Trojan 与 XHTTP 组合必须拒绝 |
| 密码 | Trojan 密码使用独立 state 字段、8–128 位 URL-safe 校验、空输入生成、非法输入不覆盖旧值 |
| 状态 | `state.json` 原子写入、备份保留、权限 `0600`、旧状态迁移和 null/false/0 语义保持正确 |
| 配置 | 配置生成、Xray 校验、失败配置留存、原子替换行为保持兼容 |
| 安全 | 凭据不进入普通日志；服务/Tunnel/env/凭证文件权限和脱敏策略不降低 |
| 卸载 | 只清理脚本实际托管的服务、文件、防火墙规则和生命周期副作用 |

### 3.2 本阶段明确不做（DROP）

- 新增协议；
- 新增公网入口、Tunnel、代理出口或防火墙策略；
- 修改公开 CLI 参数面；
- 修改 state JSON 对外兼容格式；
- 引入 `whiptail`、`dialog` 等额外交互依赖；
- 迁移到 Python 或其它语言作为第一阶段目标；
- 为纯格式、纯命名、纯类型洁癖增加无运行时收益的改动；
- 修改 GitHub 远程分支或推送远程；
- 在宿主机执行真实 `xray2go`、Xray、cloudflared、systemd/OpenRC、Tunnel 或 `/etc/xray2go` 部署。

### 3.3 必须通过实测重新确认（RECHECK）

- 当前所有 runtime 探针的真实副作用和固定路径；
- 每个模块的生成 inbound、分享链接、端口和监听地址语义；
- 失败时 config/state/service/env/tunnel/firewall 是否能精确恢复；
- systemd 与 OpenRC 模板在隔离 fixture 中的等价行为；
- 生成插件被加载后的实际函数、JSON 和链接结果；
- 主菜单、Wizard、高级安装计划和运行时菜单是否对所有动作使用同一 dispatcher；
- 构建拆分后的 `xray_2go.sh` 是否与源码模块在行为上等价。

## 4. 目标架构

最终源码组织目标：

```text
src/
├── bootstrap.sh              # 入口初始化、版本、退出清理
├── paths.sh                  # 生产路径与测试 sandbox 路径
├── logging.sh                # 日志、脱敏、交互基础输出
├── platform.sh               # OS、架构、依赖、包管理器
├── state.sh                  # state schema、读写、迁移、normalize
├── validation.sh             # 端口、域名、path、UUID、凭据、组合约束
├── plan.sh                   # draft state、summary、plan validate
├── actions.sh                # 运行时 canonical actions
├── transaction.sh            # stage/apply/verify/commit/rollback
├── config.sh                 # 配置对象与 config.json 生成/校验
├── service.sh                # systemd/OpenRC 服务适配
├── tunnel.sh                 # Argo/Tunnel 文件与服务副作用
├── firewall.sh               # 托管防火墙规则协调
├── lifecycle.sh              # sysctl、hosts、卸载和恢复
├── plugins.sh                # 插件注册、合约、snapshot、collector
├── protocols/
│   ├── argo.sh
│   ├── freeflow.sh
│   ├── reality.sh
│   ├── vltcp.sh
│   ├── socks.sh
│   ├── vlquic.sh
│   └── cforigin.sh
└── ui/
    ├── wizard.sh
    ├── install-plan.sh
    ├── runtime-menu.sh
    └── main-menu.sh

tools/
└── build-single-file.sh       # 生成公开发布 artifact

tests/
├── probe_regressions.py       # 保留少量源码契约检查
├── sandbox_runner.py          # 隔离 root/workdir 运行器
├── behavior/                  # 用户可见 CLI/菜单行为场景
├── fixtures/                  # state/config/service/tunnel fixture
└── generated/                 # 生成插件和单文件 artifact 验收

xray_2go.sh                    # 继续作为公开单文件发布 artifact
```

迁移期间不要求一次性创建全部目录。每个目录只在对应切片有明确 owner、测试和回滚时创建。

### 4.1 单文件发布策略

- `src/` 成为内部 canonical source；
- `tools/build-single-file.sh` 按固定顺序拼装或生成 `xray_2go.sh`；
- 发布 artifact 必须可以脱离 `src/` 独立运行；
- 构建前执行 Bash 语法检查；
- 构建后对 artifact 执行完整测试和生成插件测试；
- 不允许只测试 `src/` 而跳过最终 `xray_2go.sh`；
- 迁移完成前保留旧 artifact 作为 oracle，不允许删除旧实现直到行为对照和全量测试通过。

## 5. 每个切片的固定执行协议

后续用户说“继续”时，默认连续完成当前切片，不在低风险步骤之间停下来询问。

每一个切片必须按以下顺序执行：

### RED

1. 重新读取目标文件和当前 Git 状态；
2. 写一个最小行为测试；
3. 运行该测试；
4. 确认它因目标行为缺失或旧实现错误而失败；
5. 记录精确测试名、失败断言和退出码；
6. 如果测试立即通过，说明测试没有锁住新行为，必须修正测试后重新 RED。

### GREEN

1. 只实现让当前测试通过所需的最小代码；
2. 不顺手修其它模块；
3. 运行 focused test，确认 GREEN；
4. 运行受影响的模块测试。

### REFACTOR

1. 仅在 GREEN 后移动函数、删除重复 owner、抽取共享边界；
2. 不改变外部行为；
3. 每次小改动后立即重跑 focused test；
4. 不用兼容 flag 长期保留双 owner。

### 切片关闭

```bash
bash -n xray_2go.sh
python3 -m py_compile tests/probe_regressions.py
python3 tests/probe_regressions.py
git diff --check
git status --short
```

此外必须：

- 运行新生成 artifact 的真实函数/CLI 入口；
- 扫描旧函数名、旧 dispatcher、旧 state writer 是否仍被调用；
- 清理 `__pycache__`、临时 root、生成的敏感 fixture 和探针临时文件；
- 确认只包含本切片预期文件；
- 独立提交，提交信息描述一个边界变化；
- 提交后重新读取 HEAD、工作树和关键测试结果。

## 6. 分阶段实施路线

### Phase 0：行为冻结与隔离测试基础设施

### 目标

把当前“静态探针可运行、部分 runtime 探针触碰固定宿主路径”的状态，变成可以安全执行完整测试的隔离基线。

### 主要文件

- `xray_2go.sh`
- `tests/probe_regressions.py`
- `tests/sandbox_runner.py`
- `tests/fixtures/`
- `docs/REFACTOR_IMPLEMENTATION_LOG.md`（本阶段开始时创建）

### 设计要求

- 生产默认路径仍为 `/etc/xray2go`；
- 测试必须使用临时 root/workdir；
- 测试不启动宿主服务、不改宿主防火墙、不改宿主 `/etc/hosts`、不写宿主 `/etc/xray2go`；
- 所有 service、firewall、download、Xray binary 等副作用通过明确 adapter/stub 或 fixture 隔离；
- 测试 harness 必须在退出时清理自己的临时目录；
- 不把测试 root 环境变量作为公开用户功能写入 README。

### TDD 切片

1. `test_runtime_harness_does_not_touch_host_root`
   - RED：当前 runtime 路径仍固定指向生产路径或无法注入 sandbox；
   - GREEN：增加路径初始化边界或等价隔离入口；
   - 验收：fixture 内 state/config/plugin/backup 可读写，宿主目标路径不出现新文件。

2. `test_state_backup_and_restore_are_confined_to_sandbox`
   - 覆盖 state、config、env、tunnel、backup、tmp；
   - 断言精确文件树和权限，不只检查命令返回码。

3. `test_runtime_probe_matrix_runs_in_fresh_process`
   - 将原有 runtime 探针按 safe/static/sandbox 分类；
   - 任何需要 `/etc/xray2go` 的测试必须改为 sandbox fixture。

### Phase 0 完成标准

- 完整测试可在 fresh process 中运行；
- 所有 runtime 测试都有明确隔离边界；
- 测试前后宿主 `/etc/xray2go`、服务、端口、防火墙状态无变化；
- `bash -n`、Python 编译、静态探针和 sandbox 探针均有可重复命令；
- 本阶段不改变正常生产入口的输出和路径。

### 回滚

只回滚测试隔离边界和 harness；不删除现有生产逻辑。若路径注入影响生产默认值，立即恢复旧 artifact，保留 RED 测试和诊断日志，停止进入 Phase 1。

### Phase 1：运行时 Action Layer 统一

### 目标

让运行时菜单、`module_dispatch()` 和具体 `module_*` action 只有一个 canonical owner，先解决“入口存在但动作实现分散/分叉”的问题。

### 主要对象

- `module_dispatch()`
- `module_*` action
- `unified_menu_*()`
- `_unified_dispatch_or_plan()`
- `_unified_runtime_fn_or_plan()`
- 运行时菜单中的重启、查看节点、更新端口/协议/认证/域名等路径

### 规则

- dispatcher 只负责动作路由，不负责业务状态修改；
- 每个公开动作映射到一个可直接测试的 action 函数；
- runtime action 不依赖首次安装旧的 `ask_*_mode`；
- 菜单不能直接复制一份 action 逻辑；
- 统一动作返回码和错误输出；
- 不为旧动作增加新的别名。

### TDD 切片顺序

1. enable/disable 一个低耦合模块；
2. update_port；
3. update_listen/path；
4. show links/summary；
5. restart/status；
6. Argo protocol/auth/domain/password；
7. 失败路径和状态回滚。

每个切片都用 sourced shell + sandbox + stubbed side-effect boundary 验证，不仅做字符串存在性检查。

### 验收

- 菜单暴露的每个 runtime action 都能通过 dispatcher 执行；
- 代表性 action 通过真实函数调用测试；
- action 失败后旧 state 保持不变；
- 不再从 runtime action 进入已废弃的 `ask_*_mode`；
- `module_dispatch()` 不直接承担 config/service/firewall 事务；
- 旧重复 action owner 被删除，而不是保留未调用副本。

### 停止条件

如果发现某个 action 的外部契约不明确、不同入口行为不一致且无法从现有测试确定，停止实现并先补 BDD 场景，不擅自选择行为。

### Phase 2：Install Plan 与 Draft State 纯化

### 目标

把首次 Wizard、高级安装计划和执行路径彻底分层：编辑安装计划只修改 draft state，不写运行时文件、不启动服务、不改防火墙；执行阶段只消费已验证的 state。

### 主要对象

- `install_plan_reset_defaults()`
- `install_plan_*()`
- `install_wizard_*()`
- `install_plan_validate()`
- `install_execute_current_plan()`
- `module_xray_install()`
- `module_xray_install_core()`

### 规则

```text
Wizard / 高级菜单
    ↓ 只修改 draft state
plan summary + validate
    ↓
execute current plan
    ↓ 统一 apply core
```

安装计划阶段禁止：

- 写 `/etc/xray2go/config.json`；
- 写 service unit；
- 写 Tunnel env/config/credentials；
- 执行 firewall reconcile；
- 启动、重启、enable 服务；
- 依赖交互输入作为 execute 的隐式 fallback。

### TDD 场景

- 进入高级菜单只改变 draft state；
- 取消 Wizard 不产生 runtime 文件；
- 重新选择 Reality/Argo 不残留上一个方案的模块；
- 缺失 Argo domain/token/credentials 在 execute 前失败；
- 非法 Trojan 密码不覆盖旧密码；
- `install_execute_current_plan()` 只消费 state，不重新询问用户；
- 同一 plan 重复执行具备幂等性。

### 验收

- install-plan 编辑前后 runtime 文件树相同；
- `install_plan_validate()` 在任何副作用前失败；
- execute path 只有一个 apply 入口；
- Wizard、advanced plan、非交互 Reality 入口最终进入同一执行核心；
- 安装失败时 draft、已提交 state 和外部文件的边界清晰，不出现草稿污染正式状态。

### Phase 3：统一 Transaction / Apply / Rollback

### 目标

用统一事务边界替代各个 `module_*` 中重复的“保存旧值 → apply → 手工恢复”。

### 目标流程

```text
load committed state
    ↓
create draft / desired state
    ↓
validate state + capability combinations
    ↓
render config/service/tunnel/firewall desired artifacts
    ↓
stage all artifacts in same filesystem
    ↓
validate generated artifacts
    ↓
apply external side effects in defined order
    ↓
health/semantic verification
    ↓
commit state + artifact manifest
```

失败时：

```text
restore previous state
restore config/service/env/tunnel files
restore firewall managed rules
remove only files created by this transaction
return non-zero with the first causal error
```

### 事务顺序必须由测试冻结

初始候选顺序：

1. 读取并锁定旧状态；
2. 生成并校验 desired config；
3. stage config/service/env/tunnel/firewall manifest；
4. 应用配置和必要服务变更；
5. 应用 Tunnel；
6. 同步防火墙；
7. 真实健康检查；
8. 原子提交 state；
9. 清理临时物。

最终顺序以失败注入测试和实际依赖验证为准，不凭直觉固定。

### TDD 场景

每个场景都要先用 stub 注入失败：

- config 生成失败；
- Xray config test 失败；
- state persist 失败；
- service unit 写入失败；
- Tunnel 文件写入/校验失败；
- service restart 失败；
- firewall open/close 失败；
- 健康检查失败；
- 中断/退出 trap；
- 并发 apply。

验收目标不是“返回非零”而是：

- state 是否保持旧值；
- config 是否恢复旧内容；
- 文件路径集合是否精确恢复；
- 权限是否恢复；
- 备份数量是否符合约定；
- 临时文件和运行锁是否清理；
- managed firewall 是否恢复；
- 未托管的管理员规则是否保留。

### 重点规则

- `|| true` 必须逐个分类：可忽略、告警但继续、必须失败；
- 不能用全局静默错误代替回滚；
- `st_persist`、config apply、Tunnel apply 和 firewall reconcile 的失败语义必须显式；
- 事务单测不直接触碰真实服务和防火墙；
- 真实隔离集成测试必须覆盖生成 artifact 和服务 adapter 的调用边界。

### Phase 4：状态、校验、配置与插件边界收敛

### 目标

让状态 schema、校验、协议配置对象、插件 collector 和最终 config 生成形成单向依赖，删除重复的字段解释和重复遍历。

### 主要对象

- `_STATE_DEFAULT`
- `_st_normalize_schema()`
- state migration helpers
- `val_*()` 系列
- `_plugin_snapshot_rebuild()`
- `config_synthesize()`
- `fw_desired_rules()`
- `config_print_nodes()`
- 各 `_plugin_write_*()` 和生成插件函数

### 依赖方向

```text
state → normalize → validate → protocol model/plugin output
                                  ↓
                  config / firewall / links consumers
```

禁止：

- 插件直接修改 state；
- 配置生成自己重新解释协议规则；
- 防火墙、config、node output 各自遍历 registry 并形成不同结果；
- 用兼容字段作为第二个可写真相源；
- 误把 `null`、`false`、`0` 当作同一种空值。

### TDD 场景

- state 默认值和迁移保持 JSON 类型；
- `false`、`0`、`null` 读取语义分别正确；
- 非法旧 state 可自愈但不静默丢失合法字段；
- 每个协议生成的 inbound 结构正确；
- inbound、firewall desired rules、分享链接使用相同启用状态和端口；
- wildcard listen 与 exact listen 的冲突规则一致；
- 生成插件经过 `bash -n`、source/load、函数实际调用和 JSON 解析；
- Trojan + XHTTP 等非法组合在统一校验层失败。

### 验收

对每个协议至少保留一组 fixture：

- 最小启用状态；
- 完整配置状态；
- 禁用状态；
- 非法组合；
- 旧 schema 迁移状态。

比较内容优先使用语义 JSON 比较，而不是脆弱的整段字符串比较；外部链接则逐字段解析验证。

### Phase 5：菜单、Wizard、Dispatcher 控制流收敛

### 目标

让菜单成为薄控制器，只负责显示、输入和调用 plan/action API，不再直接承担状态和副作用。

### 主要对象

- `install_wizard_menu()`
- `install_wizard_render()`
- `install_plan_menu()`
- `unified_menu_*()`
- `_menu_render()`
- `main()`
- `module_dispatch()`

### 规则

- Wizard 只负责少量高频场景和最终确认；
- 高级安装计划继续提供完整字段级控制；
- 运行时管理菜单继续复用 canonical action；
- 菜单不能直接 `st_set`、`config_apply`、`svc_exec`、`fw_reconcile`；
- 返回、取消、确认、非法输入和已安装状态行为必须明确；
- 不引入额外 UI 依赖。

### BDD 场景

- 首次无状态运行显示快速向导；
- 选择 Reality 只得到单一 Reality 计划；
- 选择 Argo 逐步要求 domain/auth/transport 等必填项；
- Trojan 仅在 WS 下可选；
- 选择高级自定义部署进入现有完整安装计划；
- 取消保留/不保留 draft 的规则一致且可观察；
- 已安装时无参数运行进入运行时管理菜单；
- 每一个菜单动作最终都能追踪到一个 dispatcher action。

### 验收

- 菜单函数体明显只保留交互控制流；
- 所有状态修改通过 plan/action/transaction 边界；
- 旧的 inline 分叉被删除；
- 行为测试不再依赖旧实现字符串，而是通过真实菜单/dispatcher 路径观察结果。

### Phase 6：源码拆分与单文件构建

### 目标

在行为和边界已经稳定后，把源码从单体脚本拆为模块，并继续提供单文件发布 artifact。

### 前置条件

以下条件全部满足后才能开始：

- Phase 0–5 的 focused/full/sandbox 测试通过；
- 所有协议至少有生成 artifact 验收；
- 事务回滚测试通过；
- 没有两个 state writer 或两个 action owner；
- 旧函数和旧 dispatcher 的调用路径已完成清扫；
- 当前 `xray_2go.sh` 已被明确标记为 oracle 或生成产物。

### TDD/迁移顺序

1. 搬移纯函数和校验层；
2. 搬移 state/schema；
3. 搬移 config/plugin；
4. 搬移 service/firewall/tunnel；
5. 搬移 transaction；
6. 搬移 action/plan；
7. 搬移 UI；
8. 加入构建器；
9. 生成新的 `xray_2go.sh`；
10. 对源码入口和最终单文件入口运行同一测试矩阵。

每次只移动一个模块；移动本身也必须先有“新路径可执行”的 RED，再做代码移动和 GREEN。

### 验收

- `src/` 可被测试和构建；
- 生成的 `xray_2go.sh` 可独立运行；
- 生成 artifact 的 Bash 语法、静态、sandbox、行为测试全部通过；
- `src/` 与 artifact 的关键行为结果一致；
- 发布包不依赖仓库内 `src/`；
- 旧单体实现不再作为第二个可写 owner 存在。

### Phase 7：最终质量、文档和发布前验收

### 目标

完成重构后的全链路验证、旧路径清理、文档同步和本地交付准备。

### 检查项

- `bash -n xray_2go.sh`；
- Python 测试编译；
- 静态回归全通过；
- sandbox runtime 全通过；
- 生成插件实际加载和 JSON/link 验收；
- systemd/OpenRC fixture 验收；
- config/state/service/tunnel/firewall 失败注入和精确回滚；
- 多次重复执行和并发锁测试；
- `git diff --check`；
- 旧函数、旧 dispatcher、旧 state writer、旧路径引用扫描；
- README、帮助文本、菜单文案与实际入口一致；
- 临时文件、测试凭据、`__pycache__` 清理；
- 工作树只保留计划内提交内容。

### 最终“不变性”验收

对以下入口执行相同输入/fixture，对比重构前 oracle 与重构后 artifact：

- `reality`；
- `reality -p <port>`；
- 首次部署 Reality Wizard；
- 首次部署 Argo Wizard；
- 高级安装计划；
- runtime module dispatch；
- 协议启用/禁用；
- 端口、domain、path、auth、Trojan password 更新；
- 生成 config、links、firewall desired rules；
- 失败 apply 和 rollback。

对比以用户可见结果、JSON 语义、文件树、权限、返回码和错误类别为准，不要求内部函数名或日志颜色保持不变。

## 7. 测试矩阵

### 7.1 静态层

用途：锁定架构边界和发布 artifact 基本有效性，不替代 runtime 测试。

```bash
bash -n xray_2go.sh
python3 -m py_compile tests/probe_regressions.py
python3 tests/probe_regressions.py --static
```

现有 Python 探针如果尚未支持 `--static`，先在 Phase 0 以最小改动拆出分类入口；不得用参数存在性代替实际分类。

### 7.2 Sandbox 函数层

用途：source 真实脚本，在临时 root 中调用真实函数，stub 仅隔离外部副作用。

覆盖：

- state load/get/set/persist/normalize；
- validators；
- plan editor/summary/validate；
- config/plugin/link 生成；
- action rollback；
- transaction failure injection；
- service/firewall/tunnel adapter 调用记录。

### 7.3 生成 artifact 层

用途：证明主脚本实际写出的插件和配置可用。

覆盖：

- 生成插件通过 `bash -n`；
- 在 sandbox 中 source/load；
- 实际调用 inbound/link/ports/enabled；
- JSON 解析、协议/传输/认证字段验证；
- 分享链接字段与 inbound 一致；
- 非法能力组合拒绝。

### 7.4 行为/CLI 层

用途：证明用户真正使用的入口行为不变。

覆盖：

- Wizard 方案选择；
- 高级安装计划；
- runtime 管理菜单；
- 返回/取消/非法输入；
- `reality` CLI；
- 错误提示和下一步行动。

### 7.5 明确不在本机执行的测试

以下不在当前宿主机执行：

- 真实 `xray2go` 安装或卸载；
- 真实 Xray 启停；
- 真实 cloudflared/Tunnel；
- 真实 systemd/OpenRC 服务改写；
- 真实防火墙变更；
- 真实 `/etc/xray2go` 写入；
- 真实公网、Cloudflare、客户端互通。

如果未来需要这些验收，必须明确目标环境、备份、回滚、切换和验收方式后另行授权，不属于本计划默认执行范围。

## 8. 提交与回滚策略

### 提交粒度

每个提交只对应一个完整边界：

```text
refactor: isolate sandbox paths
refactor: canonicalize runtime actions
refactor: make install plan side-effect free
refactor: centralize apply transaction
refactor: unify protocol collectors
refactor: thin menu controllers
refactor: split source modules
build: generate single-file release artifact
```

实际提交信息以当时内容为准，但禁止一个提交同时改变 state schema、菜单契约、协议生成和服务生命周期。

### 回滚

- 重构开始前保留当前 HEAD 的本地 backup branch/tag；
- 每个阶段结束保留可运行、可测试的提交；
- 任一阶段失败时优先回滚整个阶段，不在失败状态上继续堆 patch；
- 旧 oracle 在新 artifact 完成全量验证前不得删除；
- 不 force push，不自动推送远程；
- 不删除任何用户数据、服务数据卷或生产回滚资产。

### 停止条件

遇到以下情况立即停止当前阶段：

- focused test 无法按预期 RED；
- GREEN 依赖修改测试断言、关闭校验或静默错误；
- state/config/service/firewall/tunnel 任一副作用无法证明回滚；
- 新旧入口存在两个可写 owner；
- 发现外部行为契约不明确；
- sandbox 测试触碰宿主路径；
- 需要重启服务、改变公网入口、修改 Tunnel/代理/SSH/证书或生产数据；
- 需要扩大范围到本计划之外的功能。

## 9. 每阶段报告格式

每个切片完成后只报告实际证据：

```text
结论：完成 / 部分完成 / 未修改 / 阻塞

切片：<Phase + slice>

变更：
- 实际修改的文件和边界

RED：
- 测试命令
- 预期失败原因
- 实际失败输出/退出码

GREEN：
- focused test 结果
- 受影响测试结果

全量验证：
- bash -n
- Python/sandbox/生成 artifact 测试
- git diff --check
- 工作树状态

回滚：
- 当前阶段的恢复 ref 或恢复命令

风险/遗留：
- 每项标为 fixed / retracted / self-resolving / deferred
```

禁止只报告“测试通过”，必须指出测试运行在哪个入口、哪个 sandbox、哪个 artifact、哪个副作用边界。

## 10. 下一步执行顺序

本次只完成计划文档，不开始代码改动。下一次执行从以下步骤开始：

1. 重新确认 Git 状态和当前 HEAD；
2. 创建本地重构 backup ref；
3. 读取并分类现有测试：static / safe sourced / sandbox-required；
4. 先运行当前允许的静态基线；
5. 为 sandbox 路径隔离写第一个 RED 测试；
6. 只实现 Phase 0 的最小路径边界；
7. 运行 focused GREEN、完整 sandbox 回归和静态回归；
8. 清理临时物并提交 Phase 0；
9. 未完成 Phase 0 前不进入 Action Layer、Wizard、事务或源码拆分。

本计划不是“先写完所有测试再一次性实现”。后续严格按单个垂直切片执行：

```text
一个行为 → 一个 RED → 最小 GREEN → 重构 → 全量验证 → 一个提交
```
