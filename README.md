# Kong for macOS

Kong 是一个使用 SwiftUI 编写的原生 macOS Mihomo 客户端。

## 已实现

- 内置并管理 Mihomo v1.19.30 稳定版，支持 Apple Silicon 与 Intel；预留可选的 `mihomo-preview` 预览版内核槽位
- 通过 Mihomo 本地 REST API 切换规则 / 全局 / 直连模式
- 真实流量、近 90 天按日用量、连接、规则、策略组、节点和测速数据
- 导入本地 YAML 配置或远程订阅，支持完整 Clash / Mihomo 配置、Provider YAML、Base64 和节点 URI 列表，导入前由 Mihomo 校验
- macOS HTTP、HTTPS、SOCKS 系统代理与 PAC 模式，授权前备份并精确恢复
- TUN 参数支持（mixed/system/gVisor、auto-route、接口识别与 DNS 劫持）
- 非破坏性运行时覆写：可视化规则添加、PROCESS-NAME、远程 RULE-SET、分层 DNS 与域名嗅探
- Fake-IP / Redir-Host、DoH / DoT、proxy-server-nameserver、prefer-h3 与 respect-rules
- 局域网共享、混合端口或独立 HTTP/SOCKS 端口
- 每个订阅独立更新间隔与 User-Agent、流量/到期信息和二维码
- YAML 语法高亮编辑、Mihomo 校验与最近 5 份自动备份
- 远程规则集真实刷新、单连接/全部连接关闭，并显示命中规则与出站链
- WebDAV 一键备份/恢复（恢复前校验，密码仅存 macOS 钥匙串）；可直接导入 Sub-Store 生成的聚合订阅
- 自动规避 ClashX 等客户端造成的端口冲突
- PID 文件保护与崩溃后残留内核清理
- 原生登录项、MetaCubeXD 外部面板、真实网络诊断和命令面板（⌘K）
- 实时速率菜单栏控制器：左键打开快速面板，右键打开与主弹窗同色的快捷面板，可切换模式、节点、系统代理、局域网、配置并执行测速等常用操作
- 清爽的原生浅色界面、窗口自适应和应用图标
- Apple Silicon 与 Intel 双架构支持，最低兼容 macOS 13

## 使用

1. 打开 Kong，Mihomo 内核会以默认直连配置启动，但不会自动修改系统网络。
2. 在“配置”页导入 Clash / Mihomo YAML 配置或订阅地址。遇到 HTTP 403 时会自动尝试三种常见 Clash 客户端标识，并兼容 Provider、Base64 及常见节点链接格式。
3. 在“设置”中选择系统代理、PAC 或 TUN 后应用。系统代理/PAC 首次开启时 macOS 会请求管理员授权；Kong 会保存当前网络服务设置。
4. 再次点击可恢复原代理设置；正常退出 Kong 时也会自动恢复。

## 发布限制

- 当前公开构建内置稳定版内核；只有在应用资源中额外放入名为 `mihomo-preview` 的兼容二进制时，预览版选项才会启用，否则自动回退稳定版。
- TUN 配置会真实传给 Mihomo，但这个临时构建仅使用临时签名。若 macOS 拒绝创建路由，正式分发必须加入 Developer ID 签名的特权辅助程序或 Network Extension。
- 应用更新器尚未接入。后台下载和下次启动安装需要稳定的签名发布源、校验清单及更新框架，不能用未签名下载替代。

## 构建

在项目目录运行 `./build.sh`。如果本地没有内核，构建脚本会调用 `download-core.sh` 从 Mihomo 官方 GitHub API 下载 ARM64 与 Intel 文件，并在解压前验证固定 SHA-256。生成的应用和压缩包位于 `../../outputs`。

Mihomo 作为独立子进程运行，使用 GPL-3.0 许可证。应用包内包含完整许可证、版本、源代码链接和所分发二进制的校验值。
