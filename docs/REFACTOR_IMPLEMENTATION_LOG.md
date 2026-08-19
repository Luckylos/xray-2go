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
