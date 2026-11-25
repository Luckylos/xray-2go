# Xray-2go

Xray-2go 是一个面向 Linux VPS 的交互式 Xray 安装与管理脚本，支持通过菜单部署、更新和卸载多种入站协议，并自动生成客户端分享链接。

## 功能特性

- 默认无参数运行进入交互式自定义选项搭建菜单
- 支持 `reality` 非交互一键安装（默认参数 + 443 冲突自动随机端口）
- 交互式安装后管理菜单
- 支持 systemd 与 OpenRC
- 支持 Debian / Ubuntu / RHEL 系 / Alpine
- 内置协议：
  - Argo：VLESS + WS / XHTTP + TLS，或 Trojan + WS + TLS，通过 Cloudflare Tunnel 转发
  - FreeFlow：VLESS + WS / HTTPUpgrade / XHTTP / TCP HTTP 伪装
  - Reality：VLESS + Reality TCP Vision / XHTTP Reality
  - VLESS-TCP：明文落地，可配置监听地址
  - SOCKS5：账号密码认证，可配置监听端口与地址
  - HTTP 代理：账号密码认证，可配置监听端口与地址；协议本身为明文 TCP，公开监听前请确认防火墙与网络边界
  - Shadowsocks 2022：复用 Xray-core 内置实现，支持 AES-128-GCM、AES-256-GCM、ChaCha20-Poly1305、TCP/UDP 与节点分享链接
- 自动生成并打印分享链接
- 支持修改 UUID、端口、路径、域名、Reality 目标站点等常用参数
- xPadding 支持按协议独立开关，可实现 Argo 开启、Reality 关闭等组合
- 防火墙规则采用托管标记文件记录，只删除脚本实际创建的规则，避免误删其它服务或管理员手动规则
- 完整卸载会清理托管服务、配置、状态、Tunnel 文件、快捷命令和防火墙规则，保留归属不明的资源

### Argo 入站认证：VLESS / Trojan

Argo 工作台的“修改入站认证”可在 VLESS 与 Trojan 之间切换：

- Trojan 仅支持 WS 传输。当入站认证为 Trojan 时，脚本会拒绝把传输协议切换为 XHTTP；同样地，传输协议不是 WS 时也拒绝切换为 Trojan
- 切换到 Trojan 会自动生成一个独立的随机 Trojan 密码，与 VLESS 使用的 UUID 无关
- 可通过 Argo 工作台的“修改 Trojan 密码”单独设置或重新生成密码；输入时不回显
- 密码限制为 8-128 位 URL-safe 字符（`A-Z a-z 0-9 . _ ~ -`），避免 `#`、`?`、`@` 等字符破坏 `trojan://` 分享链接结构
- 若状态中的 Trojan 密码为空，则回退使用 UUID 作为密码；载入状态时检测到非法存量密码会清空并回退为使用 UUID
- 关闭或卸载 Argo 会把入站认证重置为 VLESS、传输重置为 WS，并清空 Trojan 密码

### Shadowsocks 2022

Shadowsocks 2022 通过 Xray-core 的 shadowsocks inbound 提供服务，不额外安装独立 Shadowsocks 二进制：

- 默认监听 8388，同时开放 TCP 与 UDP；可在安装计划或运行时工作台修改端口和监听地址
- 新部署默认使用单密钥 `2022-blake3-aes-256-gcm`。工作台 `4` 也可选择单密钥 `2022-blake3-aes-128-gcm` 或 `2022-blake3-chacha20-poly1305`，以及两种 AES-GCM 的双密钥模式
- 已有双密钥节点升级后保留原密钥和分享链接。选择加密配置或手动轮换密钥会生成新密钥，之后需重新导入节点
- 单密钥节点使用 SIP002 规定的百分号编码生成 `ss://` 分享链接。请像管理密码一样保管链接

## 安全与实现原则

- Xray 下载只使用官方 GitHub Release，并校验官方 SHA256 摘要；校验失败或无法获取摘要时拒绝继续
- Cloudflare Tunnel 遵循官方运行方式：
  - Token / remote-managed：`cloudflared tunnel --no-autoupdate run --token ...`
  - Credentials / local-managed：`cloudflared tunnel --no-autoupdate --config tunnel.yml run`
- 敏感文件使用原子写入并限制权限为 `0600`，包括 `state.json`、Tunnel env、Tunnel credentials 等
- 服务状态变更通过统一互斥接口执行，避免并发操作造成状态竞争
- 配置生成前校验端口、UUID、域名、路径、监听地址等输入，降低配置注入风险
- 不内置执行第三方 root 网络调优脚本
- 主菜单 `s` 从官方仓库的 `main` 分支通过 HTTPS 下载管理脚本，并检查 Bash 语法。`main` 的内容会以 root 权限运行，请在信任该仓库的情况下使用。

## 支持系统

- Debian / Ubuntu
- RHEL 系发行版
- Alpine Linux

说明：Alpine / OpenRC 环境下，Argo / Cloudflare Tunnel 需要用户按 Cloudflare 官方文档预先安装 `cloudflared`。

## 快速使用

### 首次部署：快速向导

首次运行时，从首页选择 `1` 快速部署 Reality、`2` 快速部署 Argo 或 `3` 自定义部署。回车默认选用 VLESS + Reality TCP，优先使用 `443/tcp`，占用时会选择一个可用的随机 TCP 端口。自定义部署可以配置多个入站。安装前会预览监听端口和占用情况，输入 `y` 确认后开始。

服务启动后，从首页 `1` 查看与导出节点。复制分享链接，在支持该协议和传输方式的客户端中从剪贴板导入，然后用自己的设备访问一个网页来验证连接。

安装需要 root 权限。可切换到 root，或使用下面的“下载后运行”方式配合 `sudo`。用 `bash xray_2go.sh --help` 或已安装的 `xray2go --help` 查看命令帮助，无需 root 权限。

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh)
```

### 非交互一键安装：Reality

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) reality
```

### 非交互一键安装：Reality + 自定义监听端口

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh) reality -p 2443
```

说明：
- 仅 `reality` 会直接触发非交互安装
- `reality`：默认优先尝试 `443`，若 `443` 已被占用，则自动切换到随机高位 TCP 端口
- `reality -p <port>`：使用你指定的 Reality TCP 监听端口，不再自动优先尝试 `443`
- `-p` 后必须显式传入合法端口号，例如 `2443`、`8443`

### 下载后运行

```bash
curl -Lo xray_2go.sh https://raw.githubusercontent.com/Luckylos/xray-2go/refs/heads/main/xray_2go.sh
chmod +x xray_2go.sh
sudo ./xray_2go.sh
```

### 已安装控制台

首页显示 Xray 状态和已启用的入站。`1` 查看与导出节点，`2` 管理入站，`3` 进入维护，`0` 退出。子菜单按 `0` 返回上一级。

- **查看与导出节点**。选择节点后可导出支持的格式。单个节点会跳过节点选择，只支持分享链接时直接显示链接。多个节点可一次导出全部分享链接。服务停止或状态未知时，仍可导出配置完整的已启用节点。同一次打开节点页时，同一 XHTTP 节点的各格式使用相同连接参数。Argo 分离节点暂不可用时会显示提示，可继续导出可用的普通节点。
- **管理入站**。已启用的入站排在前面。进入工作台后可直接改端口、协议或域名等设置。停用已启用的入站需要确认。
- **维护**。可重启 Xray、更新脚本或内核、更新 UUID、卸载整套服务。重启和卸载需输入 `y` 确认。

如需重装，请先在维护页完成卸载。安装失败后可以重试，已下载且通过检查的 Xray 可执行文件可复用。

### 创建快捷命令并更新管理脚本

从首页选择 `3` 维护，再选 `2` 更新脚本。脚本会下载官方 `main` 的最新内容，安装为 `/usr/local/bin/xray2go`，并创建 `/usr/local/bin/s`。成功后同一终端会进入新版菜单，重新读取现有状态并加载插件。以后可用 `sudo s` 打开管理菜单。

旧版本的 `s` 若提示自更新已禁用，先按上面的下载方式运行当前 `main`，再从维护页选择更新脚本。如果快捷命令路径已被其他文件占用，菜单会提示冲突。成功替换已有脚本时，上一版保存在 `/usr/local/bin/xray2go.bak`。替换失败或更新过程中收到 `SIGINT`、`SIGTERM` 时会恢复原脚本和原备份。

### 升级 Xray 内核

从首页选择 `3` 维护，再选 `3` 更新 Xray 内核。脚本会显示已安装版本和 Xray-core 官方最新稳定版。已有版本相同或更高时直接返回。输入 `y` 后，脚本会校验发布包的 SHA256、下载版本及现有配置，再替换内核。

运行中的 Xray 会短暂重启。若新版启动或健康检查失败，脚本会恢复旧内核并尝试恢复服务。原本停止的服务升级后仍保持停止。

### Argo XHTTP 配置

在 Argo 工作台选择 VLESS + XHTTP。`9` 上下行分离可启停分离、改模式和 REALITY 上行端口，并显示当前配置。`x` 高级设置会显示模式、Padding 和 XMUX，按 `7` 可逐项修改，输入 `-` 清除对应覆盖。

分离节点的上行使用 **XHTTP + REALITY**，直连服务器的独立公网 TCP 端口。下行使用 **XHTTP + TLS**，通过 Cloudflare CDN 和 Tunnel 回源。两条链路汇入同一个本机 `/argo` 入站。启用分离时，请为 REALITY 上行选一个可从公网访问的 TCP 端口，并在云平台安全组放行。

按 `2` 打开高级 Extra 编辑。当前配置显示在提示上方，可直接粘贴新的单行 JSON，空行返回。校验失败会指出对应字段，可修正后重新粘贴。`server` 配置入站 Extra，`client` 配置普通客户端和分离上行 Extra，`split.download` 覆盖分离下行参数。

```json
{
  "mode": "auto",
  "server": { "scMaxEachPostBytes": 1000000 },
  "client": { "scMinPostsIntervalMs": 30, "xmux": { "maxConcurrency": "16-32" } },
  "split": {
    "port": 28443,
    "mode": "stream-up",
    "download": { "xhttpSettings": { "extra": { "xmux": { "maxConnections": 2 } } } }
  }
}
```

上行自动使用本机公网地址、`split.port` 和 Reality 的 SNI、公钥及 Short ID。下行默认使用 Argo 的 CDN 地址、端口和域名，域名同时用作 TLS SNI 和 HTTP Host。`split.download` 可覆盖 CDN 地址、端口、路径、Host 和 TLS 参数。覆盖路径时，转发后的请求仍需进入同一个 `/argo` 入站。新建分离配置默认保存 `stream-up`，也可显式选择 `packet-up`。历史分离配置省略模式时仍使用 `packet-up`，已有显式模式继续生效。

升级后请重新导出并替换已导入的分离节点。旧版下行安全层会自动切换为 TLS。如果曾在 `split.download` 中手工指定 REALITY 直连地址或端口，请清除这些覆盖，或改为实际的 CDN 参数。

更新固定隧道的域名、凭证、传输或回源端口时，脚本会在保存状态及同步防火墙前确认本地隧道服务已启动。服务启用、重启或健康检查失败时，事务会尝试恢复旧配置与服务状态。

Argo 工作台的 `h` 探测域名根路径，HTTP 请求上限为 15 秒。菜单会显示返回状态码，例如 `404`，并单独提示 `5xx` 和未收到 HTTP 响应。请通过客户端验证节点连通。

### Reality 分享链接与 Mihomo

重新导出的直连 Reality TCP Vision 和 XHTTP 链接包含 `&support-x25519mlkem768=true`。Mihomo v1.19.34 和支持该参数的 MiSub 内置转换器会将它写为 `reality-opts.support-x25519mlkem768: true`。请重新导出并替换订阅源里的旧链接，再刷新客户端订阅。

从首页 `1` 查看与导出节点，选择 Argo 分离节点及 `Mihomo provider`。将输出保存为 JSON 文件，作为本地 `proxy-provider` 使用，也可把其中的节点加入现有 Mihomo 配置的 `proxies` 列表。配置在上行 `reality-opts` 下启用 ML-KEM 兼容开关，并在 `xhttp-opts.download-settings` 中显式清除下行继承的 REALITY 公钥。菜单会提示 Mihomo 无法等效表示的下行覆盖。Mihomo 1.19.34 的下行 Padding 继承上行，拨号设置由两路共享。

### Reality XHTTP 配置

在 Reality 工作台按 `4` 选择 XHTTP，再按 `x`。已安装的工作台和高级部署计划都提供这个入口。默认使用 `stream-one` 和根路径 `/`。切回 TCP Vision 后，保存的 XHTTP 配置可在下次切换时继续使用。

按 `1` 选择模式，按 `2` 查看当前 Extra 并粘贴新的单行 JSON，按 `5` 逐项设置 Padding 和 XMUX，按 `3` 导出分享链接或客户端出站 JSON。设置服务端 Extra 后，该配置优先于上一级的旧版 xPadding 开关。在 XHTTP 页面按 `4` 可恢复 `stream-one` 和旧版 Padding 行为。

### FreeFlow 与直连 VLESS-XHTTP-H3 配置

FreeFlow 按 `2` 选择 XHTTP 后进入 `x`，直连 VLESS-XHTTP-H3 可直接进入 `x`。两者都默认使用 `stream-one`。按 `1` 选择模式，按 `2` 编辑 Extra JSON，按 `5` 设置常用 Padding 和 XMUX，按 `3` 导出分享链接或客户端出站 JSON，按 `4` 恢复默认。FreeFlow 的旧版 xPadding 在未设置服务端 Extra 时生效。

直连 H3 使用 UDP、根路径 `/` 和 TLS `alpn=h3`。请使用支持 XHTTP over HTTP/3 的客户端。高级部署计划会在最终确认后签发 ACME 证书。从 H3 工作台 `4` 或 CF Origin 工作台 `9` 进入证书页，可查看证书状态和到期时间。两者都默认使用 Cloudflare API Token，也可选其他签发方式或导入现有文件。提交前会预览域名、证书来源和可能受影响的已启用入站。两种入站共用证书或私钥时，换证会校验受影响入站的域名、证书有效期和私钥配对。已启用入站的证书内容或引用有变化时，Xray 会重载一次，已停止的 Xray 可能因此启动。另一会话扩大影响范围时须重新确认。失败后会尝试恢复变更前的文件、配置及服务状态，证书草稿可以继续重试。

### CF Origin XHTTP 配置

使用 TLS 回源时，脚本会检查证书覆盖的域名、有效期和私钥配对，支持 Cloudflare Origin CA。更换域名时，如果现有证书不覆盖新域名，请从 CF Origin 工作台的 `9` 导入或签发证书，与域名一同保存。

在 CF Origin 工作台按 `2` 选择 XHTTP，再按 `x`。高级部署计划和已安装的工作台都提供该入口，页面会显示当前模式、Padding、XMUX 和 Edge HTTP/3 状态。按 `5` 逐项设置常用参数，输入 `-` 恢复该项默认值。分享链接和客户端出站 JSON 可从首页 `1` 选择 CF Origin 节点后导出。默认传输模式为 `stream-one`。

按 `2` 查看当前高级 Extra JSON，可直接粘贴下面的单行示例。其中 `server` 设置入站 Padding，`client` 设置客户端 XMUX，省略 `mode` 时沿用当前模式。

```json
{"server":{"xPaddingBytes":"128-768"},"client":{"xmux":{"maxConnections":4}}}
```

分享链接和出站 JSON 使用 CF Origin 域名及 Cloudflare 客户端入口端口。高级设置中的 `3` 可切换实验性的 Edge HTTP/3，启用后导出会把 HTTP/3 标记和自定义 Extra 合并。Argo 的 `split` 分离配置用于 Cloudflare Tunnel 模式。

## 安装后的主要路径

- 工作目录：`/etc/xray2go`
- Xray 二进制：`/etc/xray2go/xray`
- Cloudflared 二进制：`/etc/xray2go/argo`
- Xray 配置：`/etc/xray2go/config.json`
- 状态文件：`/etc/xray2go/state.json`
- 插件目录：`/etc/xray2go/plugins`
- 快捷命令：`/usr/local/bin/s`
- 主脚本安装位置：`/usr/local/bin/xray2go`

当 `state.json` 无法读取为 JSON 对象时，交互启动会列出可读取的备份。选择一个编号恢复，损坏文件会保留为 `state.json.corrupt.*`。回车退出可保留现场。

内置插件名由脚本保留。启动时会刷新有对应托管标记的内置插件文件。同名文件缺少托管标记时会保留原件，运行时仍使用脚本自带的实现。自定义插件请使用独立文件名。

插件的 `ports` 接口每行返回一个 `端口` 或 `端口/tcp`、`端口/udp`，省略协议时按 TCP 处理。`link` 接口每行返回一个 `scheme://…` 分享链接，支持插件自定义的 scheme。诊断信息写到标准错误。首页 `1` 汇总可用节点，插件返回的多条链接均可选择或一并导出。

## 服务名称

- Xray 服务：`xray2go`
- Cloudflare Tunnel 服务：`tunnel2go`

systemd 系统可使用：

```bash
systemctl status xray2go
systemctl status tunnel2go
```

OpenRC 系统可使用：

```bash
rc-service xray2go status
rc-service tunnel2go status
```

## 卸载说明

从首页选择 `3` 维护，再选 `5` 卸载整套 Xray-2go 并确认后，脚本停止、禁用托管服务，清理托管防火墙规则，再移除托管配置、状态、Tunnel 文件和管理入口。导入证书的原始路径、`~/.cloudflared` 中的独立 Tunnel 文件，以及归属不明的文件和防火墙规则会保留。

如果防火墙后端拒绝清理，菜单会列出待处理规则并保留托管记录和管理入口。恢复防火墙后端后，重新运行脚本，选择 `1` 继续卸载并确认。清理完成前，运行 `reality` 会提示先完成卸载。
防火墙清理只针对脚本记录为“已托管”的规则，不会盲目按端口删除系统中已有的其它规则。

## 免责声明

本项目仅供学习研究使用。使用者应遵守服务器所在地及用户所在国家和地区的相关法律法规。因使用本项目造成的任何后果由使用者自行承担，项目作者不对使用者的不当行为承担责任。
