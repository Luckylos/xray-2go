# SS2022 hardening implementation plan

## Goal
修复 Shadowsocks 2022 评审中的四项问题：运行时状态更新事务一致性、TCP/UDP 双协议端口检查、密钥生成错误传播，以及模块注册的分散重复。

## Scope
- 修改 `xray_2go.sh`；不引入新依赖，不改变单用户 SS2022 范围。
- 修改 `tests/probe_regressions.py`，先添加可复现的失败探针。
- 保留现有安装、服务、防火墙和插件生命周期；把公共模块动作改为由集中注册表分派，特殊配置动作继续使用专用处理器。

## Design
1. 增加事务化的模块状态更新 helper，让 SS2022 的监听地址、方法和密钥变更在 state/config/service 失败时回滚。
2. 增加 TCP/UDP 双协议端口占用检查和随机端口模式，SS2022 runtime/install-plan 均使用该模式。
3. 让 SS2022 key generator 检查生成命令返回值和生成结果，并用现有 validator 做最终校验。
4. 用 Bash 关联数组集中维护模块 label、menu、lifecycle、uninstall、port/listen handler 和 restart target；`module_dispatch` 的特殊动作保持显式。

## Verification
- 目标红测先失败。
- 目标测试转绿。
- `bash -n xray_2go.sh`。
- `git diff --check`。
- 完整 `PYTHONDONTWRITEBYTECODE=1 python3 tests/probe_regressions.py`。
