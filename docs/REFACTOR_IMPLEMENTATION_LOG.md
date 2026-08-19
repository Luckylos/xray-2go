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
