# Aero for macOS

Aero 是一个使用 SwiftUI 编写的原生 macOS Mihomo 客户端。

## 已实现

- 内置并管理 Mihomo v1.19.30，支持 Apple Silicon 与 Intel
- 通过 Mihomo 本地 REST API 切换规则 / 全局 / 直连模式
- 真实流量、累计用量、连接、规则、策略组、节点和测速数据
- 导入本地 YAML 配置或远程订阅，支持完整 Clash / Mihomo 配置、Provider YAML、Base64 和节点 URI 列表，导入前由 Mihomo 校验
- macOS HTTP、HTTPS 与 SOCKS 系统代理授权、备份和精确恢复
- 自动规避 ClashX 等客户端造成的端口冲突
- PID 文件保护与崩溃后残留内核清理
- 常用网络设置、命令面板（⌘K）和菜单栏控制器
- 原生暗色界面、窗口自适应和应用图标
- Apple Silicon 与 Intel 双架构支持，最低兼容 macOS 13

## 使用

1. 打开 Aero，Mihomo 内核会以默认直连配置启动，但不会自动修改系统网络。
2. 在“配置”页导入 Clash / Mihomo YAML 配置或订阅地址。遇到 HTTP 403 时会自动尝试三种常见 Clash 客户端标识，并兼容 Provider、Base64 及常见节点链接格式。
3. 点击主界面的电源按钮。macOS 会请求管理员授权，用于保存并修改当前网络服务的系统代理。
4. 再次点击可恢复原代理设置；正常退出 Aero 时也会自动恢复。

本构建采用 macOS 系统 HTTP / HTTPS / SOCKS 代理，不开启 TUN，也不修改路由表。需要代理 UDP 或不遵循系统代理的应用时，应使用经过 Developer ID 签名的 Network Extension 版本。

## 构建

在项目目录运行 `./build.sh`。如果本地没有内核，构建脚本会调用 `download-core.sh` 从 Mihomo 官方 GitHub API 下载 ARM64 与 Intel 文件，并在解压前验证固定 SHA-256。生成的应用和压缩包位于 `../../outputs`。

Mihomo 作为独立子进程运行，使用 GPL-3.0 许可证。应用包内包含完整许可证、版本、源代码链接和所分发二进制的校验值。
