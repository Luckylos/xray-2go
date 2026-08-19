# Refactor Implementation Log

> 本日志记录 `docs/REFACTOR_PLAN.md` 的实际执行证据。每个切片必须先 RED，再 GREEN/REFACTOR，完成规定验证后才能进入下一切片。

## 基线

- 仓库：`/tmp/xray-2go-audit`
- 分支：`refactor/trojan-main-migration`
- 基线 commit：`a4c21d56a6b075ea3e74bf08713f3eab855cbff1` (`feat: add guided first-deployment wizard`)
- 本地回滚 ref：`backup/pre-refactor-phase0-a4c21d5`
- Phase 0 开始时间：`2026-08-19T17:48:56+08:00`
- 生产约束：不运行 `xray2go`，不启动 Xray/cloudflared/systemd/OpenRC，不触碰 `/etc/xray2go`、宿主防火墙、宿主 `/etc/hosts` 或公网链路。

## Phase 0：行为冻结与隔离测试基础设施

### 当前切片

- `phase0-slice1-runtime-root-boundary`
- 目标：为测试提供显式、仅测试模式可用的临时 root，使脚本派生的工作目录、state/config/plugin、服务脚本目标和备份路径落在 sandbox 内；生产默认路径保持 `/etc/xray2go`。

### RED

- 状态：进行中
- 计划测试：`test_runtime_harness_does_not_touch_host_root`
- 预期失败：现有脚本的路径常量固定为 `/etc/xray2go` 及宿主系统路径，尚无 `tests/sandbox_runner.py` 或测试 root 注入边界。

### GREEN / REFACTOR / 验证

- GREEN：新增 `tests/sandbox_runner.py` 的 `XraySandbox`，使用 `TemporaryDirectory` 提供临时 root，并在上下文退出时清理。
- GREEN：`xray_2go.sh` 增加显式 `X2G_TEST_MODE=1` + 绝对 `X2G_TEST_ROOT` 的测试边界；生产未设置测试变量时仍派生为原路径。
- GREEN：sandbox 下覆盖 `WORK_DIR`、Xray/Argo binary、config、state、plugin、shortcut、self destination、sysctl 目标及 workdir 内锁/备份相关路径。
- 安全边界：缺少 root、相对 root、`/` root 均 fail-closed；本切片没有调用 state/plugin/service/firewall 写入路径。
- RED 证据：新增测试首次执行因 `ModuleNotFoundError: No module named 'sandbox_runner'` 失败，确认缺失能力被实际捕获。
- 聚焦 GREEN：`test_runtime_harness_does_not_touch_host_root` 通过。
- 静态回归：不调用 `run_bash` / `subprocess.run` 的 `probe_regressions.py` 探针重新执行，`static_cases 47`。
- Bash 语法：`bash -n xray_2go.sh` 通过。
- Python 编译：`python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py` 通过。
- 生产默认路径：未设置测试变量时验证为 `/etc/xray2go`、`/usr/local/bin/s`、`/etc/sysctl.d/99-xray2go.conf`。
- 危险测试 root：相对路径和 `/` 均返回码 `2` 并拒绝加载。
- 工作树与临时物：`git diff --check`、未跟踪 sandbox 文件和实施日志的 `git diff --no-index --check` 通过；`tests/__pycache__` 已清理，未发现 `*.tmp`、`*.bak`、编辑器临时文件。
- 宿主边界：聚焦测试前后 `/etc/xray2go` 目录元数据未变化；未启动服务、未修改防火墙、未修改宿主 `/etc/hosts`，也未执行真实部署。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片只改变测试模式路径派生和测试 harness，不改变生产默认入口。
- 下一切片：`phase0-slice2-state-config-backup-confinement`，先新增 state/config/env/tunnel/backup/tmp 文件树与权限的 RED 测试；在其 RED 之前不继续修改生产写入逻辑。

### 停止条件

- 若路径注入改变未设置测试变量时的生产默认值，立即回滚本切片代码，只保留失败测试和诊断证据。
- 若测试需要启动宿主服务、修改防火墙、修改 `/etc/hosts` 或写入 `/etc/xray2go`，停止并改为 stub/fixture；不以降低隔离标准换取通过。

## Phase 0 / Slice 2：state/config/env/tunnel/backup/tmp confinement

### 范围

- 切片：`phase0-slice2-state-config-backup-confinement`
- 目标：在 fresh sandbox 进程中验证 state、config、Argo env、Tunnel fixture、service unit target、backup 和 temporary workspace 的文件树及权限；禁止任何 service unit 写入宿主路径。
- 测试：`test_state_backup_and_restore_are_confined_to_sandbox`

### RED

- 首次执行结果为预期失败：

```text
escaped_service_path=/etc/systemd/system/xray2go.service
escaped_service_path=/etc/systemd/system/tunnel2go.service
xray_rc=1
tunnel_rc=1
```

- 失败原因已定位为 `svc_apply_xray()` / `svc_apply_tunnel()` 将 service unit 目标硬编码为宿主 `/etc/systemd/system`，sandbox adapter 正确拒绝了越界路径；测试过程未向宿主写入文件。
- 后续 GREEN 过程中又捕获到 `with_lock()` 在 flock 子 shell 内首次创建 `.tmp_*` 目录，父进程 EXIT trap 无法清理的真实临时目录泄漏。

### GREEN / REFACTOR / 验证

- 新增 `_SVC_SYSTEMD_DIR` 和 `_SVC_OPENRC_DIR`，均从显式测试 root 派生；未设置测试变量时仍分别解析为 `/etc/systemd/system` 和 `/etc/init.d`。
- `svc_apply_xray()`、`svc_apply_tunnel()` 及 Argo 卸载/安装回滚/整套卸载中的托管 service unit 路径统一使用上述目录，避免通过这些路径触碰宿主 service 文件。
- `with_lock()` 在进入 flock 子 shell 前调用 `_ensure_tmp_dir`，使临时 workspace 由父进程持有并由 EXIT trap 清理。
- 新测试实际执行：两次 state 持久化产生 state backup；两次 config 写入产生 config backup；写入 `.argo_env`、Tunnel fixture 和 systemd unit fixture；检查敏感文件及 backup 均为 `0600`；退出 fresh process 后无 `.tmp_*`/探针临时残留。
- 聚焦 GREEN：`test_state_backup_and_restore_are_confined_to_sandbox` 通过。
- sandbox 回归：`test_runtime_harness_does_not_touch_host_root` 与切片 2 测试共 `2` 项通过。
- 静态回归：不调用 `run_bash` / `run_bash_result` / subprocess sandbox 的探针重新执行，`static_cases 47`。
- Bash 语法：`bash -n xray_2go.sh` 通过。
- Python 编译：`python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py` 通过。
- `git diff --check` 通过。
- 生产默认路径：`WORK_DIR=/etc/xray2go`、`CONFIG_FILE=/etc/xray2go/config.json`、`STATE_FILE=/etc/xray2go/state.json`、service dirs 为 `/etc/systemd/system` 与 `/etc/init.d`、`SHORTCUT=/usr/local/bin/s`、sysctl 为 `/etc/sysctl.d/99-xray2go.conf`。
- 宿主边界：测试前后 `/etc/xray2go` 元数据一致；未启动 systemd/OpenRC、Xray 或 cloudflared，未修改防火墙和宿主 `/etc/hosts`，未执行真实部署。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片只扩展测试 root 下的 artifact/service target 和临时 workspace 隔离，不改变生产默认路径或公开用户功能。
- 下一切片：`phase0-slice3-runtime-probe-matrix`，先为 runtime 探针建立 safe/static/sandbox 分类和 fresh-process 执行边界；在其 RED 前不进入 Phase 1。

## Phase 0 / Slice 3：runtime probe matrix

### 范围

- 切片：`phase0-slice3-runtime-probe-matrix`
- 目标：将现有 `probe_regressions.py` 探针按 `static`、`safe`、`sandbox` 分类，并保证完整入口逐项通过 fresh process 执行。
- 验收测试：`test_runtime_probe_matrix_runs_in_fresh_process`

### RED

- 首次执行失败为预期缺失能力：

```text
ModuleNotFoundError: No module named 'probe_matrix'
```

- 失败发生在新增的 harness 契约导入处，不是测试语法错误或业务断言失败。

### GREEN / REFACTOR / 验证

- 新增 `tests/probe_matrix.py`：
  - 使用 AST 发现测试函数并保持源文件定义顺序；
  - 明确划分 `static`、`safe`、`sandbox` 三类；
  - `static` 不调用 subprocess；
  - `safe` 为 subprocess 探针，由 runner 为每个 fresh process 注入一次性 `XraySandbox`；
  - `sandbox` 由探针自身持有显式 sandbox；
  - 每个探针使用独立 Python 子进程，并记录 PID、返回码和输出。
- `XraySandbox.environment()` 增加 sandbox 内 `TMPDIR`，避免 `mktemp` 等临时物落到宿主 `/tmp`。
- 将既有 runtime fixture 的证书测试路径从硬编码 `/tmp/cert.pem`、`/tmp/key.pem` 改为 `${WORK_DIR}` 内路径，并保留清理。
- `probe_regressions.py` 的 `main()` 改为只调用矩阵 runner，不再在当前进程直接遍历执行所有测试。
- 矩阵发现结果：`static=47`、`safe=31`、`sandbox=2`，合计 `80` 项。
- 聚焦 GREEN：`test_runtime_probe_matrix_runs_in_fresh_process` 通过。
- 独立矩阵验收：`executed=80`、`failed=0`、`unique_pids=80`。
- 完整入口验收：`python3 tests/probe_regressions.py` 返回码 `0`，输出 80 项 `PASS`。
- 聚合宿主边界验收：整套 80 项矩阵执行后 `host_unchanged=True`，`fixture_scraps_absent=True`。
- Bash 语法、Python 编译和 diff 检查在提交前继续执行。
- 未启动 Xray、cloudflared、systemd/OpenRC，未修改宿主防火墙、宿主 `/etc/hosts` 或真实 `/etc/xray2go`。

### 切片结论

- 状态：`completed-in-worktree`
- Phase 0 的三项测试切片均已达到各自验收目标；runtime 回归入口现在默认经过 fresh-process sandbox matrix，不再直接在主进程执行潜在副作用探针。
- 下一阶段：Phase 1 运行时 Action Layer 统一；必须重新从一个最小 dispatcher/action 行为 RED 开始。

## Phase 1 / Slice 1：SOCKS runtime action canonical owner

### 范围

- 切片：`phase1-slice1-socks-action-owner`
- 目标：先将一个低耦合模块的 runtime enable/disable 业务逻辑收敛到单一 canonical action owner，同时让 `module_dispatch()` 只负责路由。
- 验收测试：`test_socks_runtime_actions_have_single_canonical_owner`

### RED

- 新增测试后首次执行失败，原因是生产脚本尚不存在统一 action owner：

```text
bash: 行 1: module_socks_action: 未找到命令
```

- 失败发生在实际 sourced shell 的 runtime action 调用中，sandbox root 和 stubbed config/state/firewall 边界已生效。

### GREEN / 验证

- 在 `xray_2go.sh` 新增 `module_socks_action()`，集中处理 SOCKS `enable`、`disable` 和非法 action。
- 保留原有 `module_socks_enable()` / `module_socks_disable()` 作为无业务逻辑的薄包装，避免破坏既有函数边界测试和内部调用契约。
- 将 `module_dispatch()` 的 `socks:enable`、`socks:disable` 路由直接指向 `module_socks_action`；dispatcher 不再拥有 SOCKS 状态修改逻辑。
- 聚焦 GREEN：`test_socks_runtime_actions_have_single_canonical_owner` 通过，实际验证 enable、disable 及 dispatcher 路由。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，`81` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `git diff --check` 通过。
- 测试只使用 sandbox/stub，不启动服务、不触碰宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片只统一 SOCKS enable/disable action ownership，未改变 CLI、状态格式、服务名、生产默认路径或公开协议行为。
- 下一切片：Phase 1 `update_port`，仍需先写一个最小失败测试；若发现端口更新的外部契约在不同入口不一致，先补 BDD 场景再改实现。

## Phase 1 / Slice 2：同构 runtime update_port canonical owner

### 范围

- 切片：`phase1-slice2-update-port-action-owner`
- 目标：将 FreeFlow、Reality、VLESS-TCP、VLESS-XHTTP-H3 和 SOCKS5 的同构 runtime `update_port` 路径收敛到一个 canonical action；保留 Argo 与 CF Origin 的专用实现，因为它们分别包含 Tunnel/回源端口语义。
- 验收测试：`test_runtime_port_actions_have_single_canonical_owner`

### RED

- 新增测试后首次执行失败，原因是生产脚本没有统一端口 action：

```text
bash: 行 1: module_update_port_action: 未找到命令
```

- 失败来自实际 sourced shell 的 sandbox runtime 调用，而非静态字符串检查。

### GREEN / 验证

- 新增 `module_update_port_action()`，只接受同构模块 `ff|reality|vltcp|vlquic|socks`，统一调用既有 `_menu_update_port`。
- 统一保留各模块已有 `module_*_update_port()` 函数作为薄包装，保持现有函数边界和安装计划调用契约。
- `module_dispatch()` 对上述五个模块的 `update_port` 直接路由到 canonical action，并显式保留：
  - TCP：FreeFlow、Reality、VLESS-TCP、SOCKS5；
  - UDP + `udp` label：VLESS-XHTTP-H3。
- Argo 继续使用 `module_argo_update_port`；CF Origin 继续使用 `module_cforigin_update_port`，未改变专用回源/Tunnel 逻辑。
- 更新两条静态回归断言，使其验证 canonical owner 的 TCP/UDP 参数，而不是已删除的 wrapper 直接调用细节。
- 聚焦 GREEN：`test_runtime_port_actions_have_single_canonical_owner` 通过，实际验证 Reality 端口更新和 dispatcher 到 VLESS-TCP 的路由。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `81` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过，测试缓存已清理。
- 本切片测试使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片未改变 CLI、状态格式、服务名称、生产默认路径或协议行为；只改变 runtime 同构端口 action 的内部 ownership/routing。
- 下一切片：Phase 1 `listen/path` action；继续先写一个最小 RED，若发现不同模块的输入/提交语义不一致则拆成独立 BDD 场景，不强行泛化。

## Phase 1 / Slice 3：同构 runtime update_listen canonical owner

### 范围

- 切片：`phase1-slice3-update-listen-action-owner`
- 目标：将 VLESS-TCP、VLESS-XHTTP-H3 和 SOCKS5 的同构 runtime `update_listen` 路径收敛到一个 canonical action；保留 CF Origin 的专用监听提示与 `update_path` owner。
- 验收测试：`test_runtime_listen_actions_have_single_canonical_owner`

### RED

- 新增测试后首次执行失败，原因是生产脚本没有统一监听地址 action：

```text
[INFO] 状态已初始化
bash: 行 1: module_update_listen_action: 未找到命令
```

- 失败来自实际 sourced shell 的 sandbox runtime 调用，而非静态字符串检查。

### GREEN / REFACTOR / 验证

- 新增 `module_update_listen_action()`，只接受 `socks|vltcp|vlquic`，统一完成监听地址输入、`val_listen_addr` 校验、state 更新、可选配置应用/持久化和节点输出。
- 保留 `module_socks_update_listen()`、`module_vltcp_update_listen()`、`module_vlquic_update_listen()` 作为薄包装；`module_dispatch()` 对三个 `update_listen` 动作直接路由到 canonical owner。
- GREEN 过程中发现并修复一个真实返回码边界：模块未启用时条件式节点输出会返回 `1`，在 `set -e` fresh shell 中把成功更新误报为失败；canonical action 现在显式 `return 0`。
- 更新事务静态测试，使共享提交断言落在 canonical owner，专用 CF Origin action 仍单独验证。
- 聚焦 GREEN：`test_runtime_listen_actions_have_single_canonical_owner` 通过，实际验证 VLESS-TCP 地址更新和 SOCKS dispatcher 路由。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `82` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过，测试缓存已清理。
- 本切片测试使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片未改变 CLI、状态格式、服务名称、生产默认路径或协议行为；只改变 runtime 同构监听地址 action 的内部 ownership/routing。
- `cforigin:update_listen`、`cforigin:update_path` 保持专用 owner，未被不安全地纳入通用 action。
- 下一切片：Phase 1 `show/summary` action；仍需先写最小 RED。

## Phase 1 / Slice 4：runtime show canonical owner

### 范围

- 切片：`phase1-slice4-show-action-owner`
- 目标：将各模块 runtime `show` 路由收敛到一个 canonical action，同时保留 CF Origin 的额外 Cloudflare 提示；全局 `nodes:show` 继续保留安装/运行检查。
- 验收测试：`test_runtime_show_actions_have_single_canonical_owner`

### RED

- 新增测试后首次执行失败，原因是生产脚本没有统一 show action：

```text
bash: 行 1: module_show_action: 未找到命令
```

- 失败来自实际 sourced shell 的 sandbox runtime 调用，而非静态字符串检查。

### GREEN / REFACTOR / 验证

- 新增 `module_show_action()`：普通模块调用 `config_print_nodes`，CF Origin 额外调用 `cforigin_print_cloudflare_hint`，非法模块显式失败。
- 保留 `module_show_nodes()` 与 `module_cforigin_show()` 作为兼容薄包装；`module_dispatch()` 的七个模块 `show` 路由直接指向 canonical owner。
- `module_summary()` 已是现有单一 summary owner，本切片没有复制或重写 summary 格式；`nodes:show` 的安装检查语义也未改变。
- 聚焦 GREEN：`test_runtime_show_actions_have_single_canonical_owner` 通过，实际验证节点输出、CF Origin 提示和 Reality dispatcher 路由。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `83` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过，测试缓存已清理。
- 本切片测试使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 本切片未改变 CLI、状态格式、服务名称、生产默认路径、节点链接内容或 summary 格式；只改变 show action 的内部 ownership/routing。
- 下一切片：Phase 1 Argo protocol/auth/domain/password 专用 action 统一；继续先写最小 RED，保留 Trojan WS-only 和失败回滚边界。

## Phase 1 / Slice 5：Argo field action canonical owner

### 范围

- 切片：`phase1-slice5-argo-field-action-owner`
- 目标：将 Argo runtime 的 `update_protocol`、`update_auth_protocol`、`update_trojan_password`、`update_domain`、`update_auth` 五个字段动作收敛到统一 `module_argo_update_action` owner。
- 保留 `update_port` 专用实现；安装计划 helper 继续只修改 draft state，不与 runtime apply 混合。
- 验收测试：`test_runtime_argo_field_actions_have_single_canonical_owner`

### RED

- 初始测试先要求 canonical owner 存在，旧代码按预期失败：

```text
bash: 行 1: module_argo_update_action: 未找到命令
```

- 将测试临时改为验证旧 dispatcher 时，首个旧 runtime 路由在 Argo 未启用状态下输出：

```text
[WARN] 请先选项 1 启用 Argo
```

这确认 dispatcher 仍直接绑定旧动作 owner，而不是统一路由；该 RED 证据已保留在本记录，最终回归测试只保留 GREEN 契约。

### GREEN / REFACTOR / 验证

- 将五个原 runtime 实现重命名为内部实现：
  - `_module_argo_update_protocol_impl`
  - `_module_argo_update_auth_protocol_impl`
  - `_module_argo_update_trojan_password_impl`
  - `_module_argo_update_domain_impl`
  - `_module_argo_update_auth_impl`
- 新增 `module_argo_update_action()` 按字段动作路由到上述唯一实现；未知字段显式失败。
- 保留原有 `module_argo_update_*()` 函数作为兼容薄包装，直接委托 canonical owner，既不复制校验，也不绕过原 apply/rollback 逻辑。
- `module_dispatch()` 的五个 Argo runtime 字段路由已直接调用 `module_argo_update_action`。
- Trojan WS-only 守卫、独立密码校验、固定 Tunnel apply 失败回滚、域名失败回滚均保留在原内部实现中。
- 更新静态 transport guard 测试，使其检查 canonical 内部实现，而不是过时的薄包装函数体。
- 聚焦 GREEN：`test_runtime_argo_field_actions_have_single_canonical_owner` 通过，实际 sourced shell sandbox 验证五个 dispatcher action 均到达 canonical owner。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `84` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过，测试缓存已清理。
- 本切片仅执行 sandbox/stub 与静态测试，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 未改变 CLI、状态格式、服务名称、生产默认路径、安装计划语义、Trojan WS-only 约束或失败回滚行为；只收敛 Argo runtime 字段动作的 ownership/routing。
- 下一切片：Phase 1 runtime restart/status 与跨 action 事务边界；继续先写最小 RED，不把真实服务启动作为本地验收。

## Phase 1 / Slice 6：runtime restart/status canonical owner

### 范围

- 切片：`phase1-slice6-restart-status-action-owner`
- 目标：将 runtime restart 与服务状态查询收敛到明确的 canonical owner，dispatcher 只负责 restart 路由，兼容函数不再复制动作逻辑。
- 验收测试：
  - `test_runtime_restart_status_actions_have_single_canonical_owner`
  - `test_runtime_restart_status_canonical_owner_preserves_failure_and_status_contract`

### RED

- 首次执行新增聚焦测试时，旧脚本按预期缺少 canonical owner；探针首先报告 restart owner 缺失：

```text
Traceback (most recent call last):
  ...
AssertionError: restart/status canonical-owner RED/GREEN probe failed: missing_restart_owner
```

- RED 发生在实际 sourced shell 的 sandbox 进程中，失败原因是 `module_restart_action` 尚未存在，而不是 Python 编译、测试导入或宿主路径错误。

### GREEN / REFACTOR / 验证

- 新增 `module_restart_action()`：
  - `xray` 委托既有 `svc_restart_xray`，保留配置文件、service unit、daemon reload、restart 与 health check 顺序；
  - `argo` 统一执行 `tunnel2go` restart 和 `svc_verify_health`；restart 或健康检查失败均返回非零并输出失败日志；
  - 非法目标 fail-closed。
- 新增 `module_status_action()`，统一承载 `xray` 与 `argo` 的状态文本和返回码：`running`、`stopped`、`not installed`、`disabled` 及既有错误码均保留。
- `module_xray_restart()`、`module_argo_restart()`、`check_xray()`、`check_argo()` 保留为兼容薄包装，仅委托 canonical owner；`_xray_runtime_status()` 也改为通过统一状态 owner 查询。
- `module_dispatch()` 的 Argo restart 及其他模块共享的 Xray restart 路由直接调用 `module_restart_action`，不再经过旧 restart wrapper。
- 聚焦 GREEN：
  - sourced shell sandbox 验证 dispatcher 的 Argo/Xray restart 路由与 status wrapper 路由；
  - 验证 wrapper 不复制业务逻辑；
  - 使用 stubbed service boundary 验证 Xray restart 失败、Argo health 失败均 fail-closed；
  - 验证 running/stopped 状态文本与返回码契约。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `87` 项 `PASS`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存在最终清理阶段删除。
- 本切片只使用 sandbox/stub 和静态源码断言，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- 未改变 CLI、状态格式、服务名称、生产默认路径、安装计划语义、协议行为或节点输出；只收敛 runtime restart/status 的内部 ownership/routing，并修复 `module_xray_restart()` 吞掉 restart 失败码的边界。
- 真实服务生命周期、systemd/OpenRC 和公网 Tunnel 仍未在宿主上验收，符合当前安全边界；后续需要在隔离 runtime fixture 中继续覆盖事务失败与跨 action rollback。
- 下一切片：Phase 1 失败路径与状态回滚；继续先写最小 RED。

## Phase 1 / Slice 7：runtime action failure state rollback

### 范围

- 切片：`phase1-slice7-action-failure-state-rollback`
- 目标：修复 runtime action 在 commit/apply 失败后只返回错误、却把内存 state 留在新值的问题。
- 本切片只覆盖 canonical SOCKS action 的 state 边界；配置、服务、Tunnel、firewall 等跨 artifact 事务回滚留到后续统一 transaction 阶段。
- 验收测试：`test_runtime_socks_disable_failure_restores_previous_state`

### RED

- 新增 sourced-shell sandbox 测试后，旧实现真实失败：

```text
AssertionError: failed SOCKS disable must restore committed state: rc=1 memory=false disk=true
```

- 失败语义正确：`_module_disable_commit` 被 stub 为失败后，action 返回非零，磁盘中的已提交 state 仍为 `true`，但 `_G_STATE` 已错误变成 `false`，形成内存/磁盘状态漂移。

### GREEN / REFACTOR / 验证

- `module_socks_action disable` 现在先保存 `.socks.enabled` 的原始 JSON 值，再尝试禁用和 commit。
- commit 失败时恢复原始 typed state，并返回非零；成功时保持原有禁用成功输出和调用路径。
- 使用原始 JSON 值而不是字符串参数，避免将 `true`/`false` 类型退化为字符串。
- 聚焦 GREEN：`test_runtime_socks_disable_failure_restores_previous_state` 通过，确认：
  - 返回码为 `1`；
  - 内存 state 仍为 `true`；
  - 磁盘 `state.json` 仍为 `true`。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `87` 项 `PASS`，`0` 项失败。
- 探针矩阵统计：`static=46`、`safe=31`、`sandbox=10`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：SOCKS disable 在 commit 失败时的内存 state 漂移已修复。
- **deferred**：如果失败发生在统一 commit 已经写入部分 config/state/artifact 之后，跨文件恢复仍需 Phase 3 transaction/apply/rollback 设计和失败注入测试；本切片没有伪装成完整事务回滚。
- 下一切片：继续覆盖另一个 canonical runtime action 的失败状态边界，仍需先写最小 RED。

## Phase 1 / Slice 8：runtime action enable failure state rollback

### 范围

- 切片：`phase1-slice8-action-enable-failure-state-rollback`
- 目标：补齐 canonical SOCKS action 的 enable 失败状态边界，避免重复 enable 失败时把原本已启用的 state 错误改成 disabled。
- 验收测试：`test_runtime_socks_enable_failure_restores_previous_state`

### RED

- 首次执行新增测试时，旧实现真实失败：

```text
AssertionError: failed SOCKS enable must restore committed state: rc=1 memory=false disk=true
```

- 同时在补测过程中发现上一切片的 README 测试函数定义被误放置在 SOCKS disable 测试体内，导致该测试未被 probe matrix 单独发现；已在本切片中修复函数边界，并通过矩阵数量和完整执行结果确认恢复。

### GREEN / REFACTOR / 验证

- `module_socks_action enable` 现在保存 `.socks.enabled` 的原始 JSON 值，再执行 `_module_enable_with_state`。
- enable/commit 失败时恢复原始 typed state 并返回非零；原本为 `false` 的 enable 失败行为也保持不变。
- 聚焦 GREEN：`test_runtime_socks_disable_failure_restores_previous_state` 与 `test_runtime_socks_enable_failure_restores_previous_state` 均通过。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `89` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=11`、`total=89`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：SOCKS enable 在 commit 失败时不再把原有 `true` 状态错误恢复为 `false`；README regression test 的函数边界也已恢复。
- **deferred**：跨 config/state/service/Tunnel/firewall artifact 的统一事务回滚仍属于 Phase 3，不由本切片宣称完成。
- 下一切片：继续按 failure-injection 顺序覆盖下一个 canonical runtime action，仍需先写最小 RED。

## Phase 1 / Slice 9：VLESS-TCP enable failure state rollback

### 范围

- 切片：`phase1-slice9-vltcp-enable-failure-state-rollback`
- 目标：覆盖非 SOCKS canonical runtime action 的 enable 失败状态边界，确认 `_module_enable_commit` 失败后 VLESS-TCP 不会留下内存/磁盘 state 漂移。
- 验收测试：`test_runtime_vltcp_enable_failure_restores_previous_state`

### RED

- 首次执行新增 sourced-shell sandbox 测试时，旧实现真实失败：

```text
AssertionError: failed VLESS-TCP enable must restore committed state: rc=1 memory=false disk=true
```

- 失败发生在 `_module_enable_commit` 被 stub 为失败后：action 返回非零，磁盘 state 仍为 `true`，但 `_G_STATE` 被旧的固定 `false` 回滚逻辑错误覆盖。

### GREEN / REFACTOR / 验证

- `module_vltcp_enable` 现在先保存 `.vltcp.enabled` 的原始 JSON 值。
- enable commit 失败时恢复原始 typed state 并返回非零；成功路径、dispatcher 路由和公共行为保持不变。
- 聚焦验证通过：
  - `test_runtime_socks_disable_failure_restores_previous_state`
  - `test_runtime_socks_enable_failure_restores_previous_state`
  - `test_runtime_vltcp_enable_failure_restores_previous_state`
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `90` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=12`、`total=90`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：VLESS-TCP enable commit 失败时的内存 state 漂移。
- **deferred**：SOCKS、VLESS-TCP、FreeFlow、Reality、VLQUIC、CF Origin 等模块仍存在不同程度的局部 rollback 实现；统一的 state/config/service/Tunnel/firewall transaction 仍应按计划在后续边界集中设计，未通过逐模块补丁宣称完成。
- 下一切片：优先评估并以 RED 测试确定共享 enable rollback/transaction 边界，不继续无条件复制模块级补丁。

## Phase 1 / Slice 10：共享 enable helper failure rollback

### 范围

- 切片：`phase1-slice10-shared-enable-helper-failure-rollback`
- 目标：将简单 enable action 的 commit 失败恢复逻辑收敛到 `_module_enable_with_state`，避免每个调用方复制 state snapshot/restore。
- 验收测试：`test_shared_enable_helper_restores_state_on_commit_failure`

### RED

- 共享 helper 测试首次执行时，旧实现真实失败：

```text
AssertionError: shared enable helper must restore prior state: rc=1 memory=false disk=true
```

- 失败语义确认 `_module_enable_with_state` 在 `st_set` 成功、`_module_enable_commit` 失败后只返回错误，没有恢复调用前 `_G_STATE`；磁盘 state 仍保持旧值。

### GREEN / REFACTOR / 验证

- `_module_enable_with_state` 现在在修改前保存完整 `_G_STATE`。
- `_module_enable_commit` 失败时恢复完整内存 state 并返回非零；成功路径不变。
- `module_socks_action enable` 和 `module_vltcp_enable` 已改为直接复用该 helper，删除重复的局部 snapshot/restore 逻辑。
- 聚焦验证通过：
  - `test_shared_enable_helper_restores_state_on_commit_failure`
  - `test_runtime_socks_disable_failure_restores_previous_state`
  - `test_runtime_socks_enable_failure_restores_previous_state`
  - `test_runtime_vltcp_enable_failure_restores_previous_state`
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `91` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=13`、`total=91`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：共享 enable helper 的内存 state rollback，以及 SOCKS/VLESS-TCP 两个调用方的重复实现。
- **deferred**：helper 只覆盖其调用时已经进入 `_module_enable_with_state` 的状态变更；FreeFlow、Reality、CF Origin 等在调用 helper 前还会修改默认值或生成材料的复杂路径，仍需独立 transaction/全量快照设计和失败注入测试。
- 下一切片：继续以 failure-injection 覆盖复杂 enable 前置变更，或进入统一 transaction 设计；必须先建立对应 RED，不得直接扩大修改范围。

## Phase 1 / Slice 11：FreeFlow enable 前置状态失败回滚

### 范围

- 切片：`phase1-slice11-freeflow-enable-precommit-state-rollback`
- 目标：修复 FreeFlow enable 在调用共享 commit 前修改默认传输协议、随后 commit 失败时的完整状态恢复；本切片只覆盖 FreeFlow 的 pre-commit 内存 state 边界，不扩展为跨 config/state/service/Tunnel/firewall 的统一事务。
- 验收测试：`test_runtime_ff_enable_failure_restores_complete_previous_state`

### RED

- 新增 sourced-shell sandbox failure-injection 测试后，旧实现真实失败：

```text
AssertionError: failed FreeFlow enable must restore complete prior state: rc=1 memory=false/none/old.example disk=true/tcphttp/old.example
```

- 失败链路已确认：`module_ff_enable()` 会先把 `.ff.protocol` 从 `none`/空值调整为 `ws`，再设置 `.ff.enabled` 并进入 commit；commit 失败时旧分支只把内存 state 强制改成 `enabled=false, protocol=none`，没有恢复调用前的完整 `.ff` 对象。磁盘 state 仍是原提交值，形成内存/磁盘漂移。

### GREEN / REFACTOR / 验证

- 新增 `_module_ff_enable_prepare()`，只负责 FreeFlow enable 前置默认值和 `.ff.enabled = true` 的 state 修改。
- 将 `_module_enable_transaction()` 提取为通用的 prepare → commit → 内存 state restore 边界，并让 `_module_enable_with_state()` 保持为兼容薄包装；`module_ff_enable()` 调用 `_module_enable_transaction FreeFlow _module_ff_enable_prepare`。因此前置 state 修改失败或 `_module_enable_commit` 失败时，均恢复调用前完整 `_G_STATE` 并返回非零。
- 删除旧的固定回滚 `.ff.enabled = false | .ff.protocol = "none"`，避免覆盖原有协议、host 及其他 FreeFlow 字段。
- 聚焦 GREEN：`test_runtime_ff_enable_failure_restores_complete_previous_state` 通过，确认返回码为 `1`，且内存与磁盘同时保持 `true/tcphttp/old.example`。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `92` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=14`、`total=92`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，不启动 Xray、cloudflared、systemd/OpenRC，不修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：FreeFlow enable 的 pre-commit 失败不再把原有协议和内存 state 强制改成 `false/none`；完整调用前 state 会恢复，失败码仍保留。
- **deferred**：`_module_enable_transaction` 当前只保证其负责的内存 state 快照边界；若 commit 内部已经部分写入 config/state/service/firewall 等 artifact，跨 artifact 恢复仍需 Phase 3 的统一 transaction/apply/rollback 设计和失败注入测试。
- 下一切片：继续以最小 RED 覆盖下一个复杂 enable 路径的前置变更，或在证据充分后进入统一 transaction 设计；不得把本切片宣称为完整事务回滚。

## Phase 1 / Slice 12：Reality enable 生成材料失败回滚

### 范围

- 切片：`phase1-slice12-reality-enable-generated-material-rollback`
- 目标：修复 Reality enable 在 commit 前生成 x25519 密钥对和 short ID、随后 commit 失败时只恢复 enabled 标志而遗留新材料的问题；本切片只覆盖 Reality 的 pre-commit 内存 state 边界，不扩展为跨 config/state/service/firewall 的统一事务。
- 验收测试：`test_runtime_reality_enable_failure_restores_generated_material`

### RED

- 新增 sourced-shell sandbox failure-injection 测试，并以 sandbox 内 stub Xray 的 `x25519` 输出模拟密钥生成；旧实现真实失败：

```text
AssertionError: failed Reality enable must restore generated material and prior state: rc=1 memory=false/NEWPRIVATEKEY_1234567890/NEWPUBLICKEY_1234567890/da81dfa4767da91b disk=false/null/null/oldsid
```

- 失败链路已确认：`module_reality_enable()` 在 commit 前由 `crypto_gen_reality_keypair()` 写入 `.reality.pvk/.reality.pbk`，随后生成 `.reality.sid` 并启用 Reality；`_module_enable_commit` 失败时旧分支只写回 `.reality.enabled = false`，导致内存 state 保留新密钥和新 SID，而磁盘 state 仍保持旧提交值。

### GREEN / REFACTOR / 验证

- 新增 `_module_reality_enable_prepare()`，集中 Reality enable 的前置状态准备：必要时生成密钥对和 SID，最后设置 `.reality.enabled = true`。
- `module_reality_enable()` 保留 Xray 可执行文件前置检查，并改为调用 `_module_enable_transaction Reality _module_reality_enable_prepare`；prepare 或 `_module_enable_commit` 失败时恢复调用前完整 `_G_STATE`，删除旧的只恢复 enabled 标志的局部回滚。
- 聚焦 GREEN：`test_runtime_reality_enable_failure_restores_generated_material` 通过，确认返回码为 `1`，且内存与磁盘同时保持 `false/null/null/oldsid`。
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，共 `93` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=15`、`total=93`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，未启动真实 Xray、cloudflared、systemd/OpenRC，未修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：Reality enable 的 pre-commit 失败会恢复生成前完整内存 state，不再遗留新密钥和新 SID；失败码仍保留，已提交 state 不被覆盖。
- **deferred**：`_module_enable_transaction` 当前只保证其负责的内存 state 快照边界；若 commit 内部已经部分写入 config/state/service/firewall 等 artifact，跨 artifact 恢复仍需 Phase 3 的统一 transaction/apply/rollback 设计和失败注入测试。
- 下一切片：继续以最小 RED 覆盖下一个复杂 enable 路径的前置变更；不得把本切片宣称为完整事务回滚。

## Phase 1 / Slice 13：CF Origin enable 前置默认值失败回滚

### 范围

- 切片：`phase1-slice13-cforigin-enable-precommit-state-rollback`
- 目标：修复 CF Origin enable 在 commit 前补齐协议、path、listen 和 edge port 默认值、随后 commit 失败时只恢复 enabled 标志而遗留默认值的问题；本切片只覆盖 CF Origin 的 pre-commit 内存 state 边界，不扩展为跨 config/state/service/firewall 的统一事务。
- 验收测试：`test_runtime_cforigin_enable_failure_restores_precommit_defaults`

### RED

- 新增 sourced-shell sandbox failure-injection 测试，预置 CF Origin 的多个可选字段为 `null` 并注入 `_module_enable_commit` 失败；旧实现真实失败：

```text
AssertionError: failed CF Origin enable must restore pre-commit defaults and prior state: rc=1 memory=false/ws//origin/::/443/old.example disk=false/null/null/null/null/old.example
```

- 失败链路已确认：`module_cforigin_enable()` 在进入 `_module_enable_with_state` 前依次补齐协议 `ws`、path `/origin`、listen `::` 和 edge port `443`；共享 helper 的快照从默认值已写入之后才开始，commit 失败时旧分支又只设置 `.cforigin.enabled = false`，导致内存 state 遗留默认值，而磁盘 state 仍保持旧提交值。

### GREEN / REFACTOR / 验证

- 新增 `_module_cforigin_enable_prepare()`，集中 CF Origin enable 的前置默认值和 `.cforigin.enabled = true` 状态修改。
- `module_cforigin_enable()` 改为调用 `_module_enable_transaction "CF Origin" _module_cforigin_enable_prepare`，成功后继续执行原有 `cforigin_print_cloudflare_hint`；prepare 或 commit 失败时恢复调用前完整 `_G_STATE`，删除旧的局部 enabled-only 回滚。
- 聚焦 GREEN：`test_runtime_cforigin_enable_failure_restores_precommit_defaults` 通过，确认返回码为 `1`，且内存与磁盘同时保持 `false/null/null/null/null/old.example`。
- 完整 fresh-process 回归：探针矩阵返回码 `0`，共 `94` 项 `PASS`，`0` 项失败。
- 最终探针矩阵：`static=47`、`safe=31`、`sandbox=16`、`total=94`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；测试缓存已清理。
- 本切片只使用 sandbox/stub，未启动真实 Xray、cloudflared、systemd/OpenRC，未修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`
- **fixed**：CF Origin enable 的 pre-commit 失败会恢复调用前完整内存 state，不再遗留自动补齐的协议、path、listen 和 edge port 默认值；失败码仍保留，已提交 state 不被覆盖。
- **deferred**：`_module_enable_transaction` 当前只保证其负责的内存 state 快照边界；若 commit 内部已经部分写入 config/state/service/firewall 等 artifact，跨 artifact 恢复仍需 Phase 3 的统一 transaction/apply/rollback 设计和失败注入测试。
- 下一切片：`phase3-slice1-core`，先以最小 RED 证明跨 artifact rollback 缺口，再实现统一事务快照；不得把本切片宣称为完整事务回滚。

## Phase 3 / Slice 1：统一事务快照与回滚核心

### 范围

- 切片：`phase3-slice1-core`
- 目标：建立可复用的事务边界，快照并恢复内存 state、持久化 state/config、服务单元、Argo/ACME/Tunnel 文件、防火墙 managed artifact、sysctl 及相关 backup 文件；事务失败时只删除事务中新建的路径，并保留原文件内容、权限和存在性。
- 入口：`_transaction_run`、`_transaction_begin`、`_transaction_rollback`、`_transaction_end`。
- 集成范围：普通 `_commit`、`_module_enable_commit`、`_module_disable_commit` 与 `_module_enable_transaction` 已通过事务包装接入；本切片不宣称所有 module action 都已在状态修改前建立外层事务。

### RED

- 新增 `test_runtime_transaction_restores_cross_artifact_state_after_commit_failure` 后，旧实现真实失败：commit stub 在失败前写入新 config、state、service、Argo env、Tunnel 与 firewall marker，结果仅返回非零，工件全部保留新值。
- 初始失败输出：

```text
rc=1
memory=false
config=new-config
state={"socks":{"enabled":true}}
service=new-service
env=new-env
tunnel=new-tunnel
fw=iptables:9999/tcp
ports=9999
```

- 修正 probe 的 JSON 输出为 `jq -c` 后，确认失败断言表达的是事务行为而非多行输出格式。
- 新增 `test_runtime_transaction_restores_service_enabled_state_after_commit_failure` 后，旧实现再次形成有效 RED：

```text
AssertionError: failed commit must restore service active and enabled state: rc=1 active=1 enabled=0
```

- 该失败隔离了此前快照只记录 active 状态、未记录 service enable 状态的缺口。

### GREEN / REFACTOR / 验证

- 新增 `_transaction_collect_artifacts`、`_transaction_snapshot_files`、`_transaction_restore_files`，使用事务目录 `files/` 与 tab 分隔 `manifest` 保存路径、存在性及 `cp -a` 文件快照；原先不存在的路径在失败回滚时被删除。
- 新增事务锁获取/释放和嵌套事务复用：事务内 `with_lock` 不重复申请同一锁；事务外继续使用原有 read-modify-write 锁。
- 新增 firewall managed snapshot 恢复：关闭事务新增规则、重新打开快照缺失规则，并保留失败标记。
- `_transaction_rollback` 先恢复 firewall managed rules 和文件 artifact，再恢复 state 及服务运行/enable 状态；中断 trap 在活动事务中执行 rollback 后以 `130` 退出。
- 新增 `svc_is_enabled`：systemd 使用 `systemctl is-enabled --quiet`，OpenRC 使用 `rc-update show default` 解析 enable 状态；服务快照同时记录 active 与 enabled 两个维度。
- `_commit`、`_module_enable_commit`、`_module_disable_commit` 拆分为 `*_inner` 实现与统一事务包装；`_module_enable_transaction` 复用相同核心。
- 聚焦 GREEN：
  - `test_runtime_transaction_restores_cross_artifact_state_after_commit_failure`
  - `test_runtime_transaction_restores_service_enabled_state_after_commit_failure`
- 完整 fresh-process 回归：`python3 tests/probe_regressions.py` 返回码 `0`，当前输出共 `95` 项 `PASS`，`0` 项失败。
- 矩阵分类：`static=47`、`safe=31`、`sandbox=17`、`total=95`。
- `bash -n xray_2go.sh` 通过。
- `python3 -m py_compile tests/probe_regressions.py tests/sandbox_runner.py tests/probe_matrix.py` 通过。
- `git diff --check` 通过；`tests/__pycache__` 已清理。
- 全部测试仅使用 sandbox/stub；未启动 Xray、cloudflared、systemd/OpenRC，未修改宿主 `/etc/xray2go`、防火墙、`/etc/hosts` 或公网链路。

### 切片结论

- 状态：`completed-in-worktree`（待独立提交）。
- **fixed**：事务失败时恢复当前覆盖范围内的跨 artifact 文件、managed firewall marker、内存/持久化 state，以及服务 active/enabled 状态；提交辅助函数保持 firewall fail-closed。
- **deferred**：disable action 目前多数在调用 `_module_disable_commit` 前已修改内存 state，尚未全部由事务在“状态修改前”建立外层快照；Argo Tunnel enable/disable 的完整生命周期、健康检查、interrupt 和并发失败注入仍需独立切片；外部真实 init/service 行为未在宿主验收。
- 下一切片：`phase3-slice1-integrate`，先以 RED 覆盖 disable/普通 action 在 pre-mutation 边界的统一接入，再补 config/state/service/Tunnel/firewall 失败注入。
