# AAUV 第三方组件

AAUV 源码中的 MIT 声明见同目录的 `LICENSE`。第三方组件各自保留原有的许可和著作权声明。

iOS 隧道扩展将 AAUV 的适配代码与 Libbox 静态链接，这个组合扩展按 GPL-3.0-or-later 发行，随附原 MIT 声明、sing-box 上游声明和 GPLv3 正文。Mac 的 sing-box 以独立进程运行，适用其 GPL 许可。具体范围写在 `Licenses/AAUV-Distribution.txt`。[GNU 的许可证兼容说明](https://www.gnu.org/licenses/license-compatibility.en.html)

| 组件 | 在 AAUV 中的用途 | 许可及源码位置 |
| --- | --- | --- |
| sing-box 与 Libbox | Mac 上运行的独立代理进程，iOS 隧道扩展中的静态库 | GPL-3.0-or-later。固定提交由 `Scripts/build-proxy.sh source-info` 给出。二进制包随附上游声明和完整 GPLv3 正文。 |
| MarkdownUI、NetworkImage、SwiftMath、swift-cmark | 苹果客户端的 Markdown 和数学排版 | 固定提交见 `Package.resolved`，原始许可文本在 `Licenses/`。 |
| Go 与 SagerNet gomobile | 共享核心、构建工具和桥接运行时 | Go 许可见 `Licenses/Go.txt`，gomobile 版本见 `Scripts/build-mobile-tools.sh`。相关 Go 模块源码带有各自的许可。 |
| GeoNames 世界地名数据 | 新机器人随机默认名称，原有数据文件及声明保持不变 | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/)。来自 PendingBot 的 GeoNames cities15000 地名库，[原始来源](https://www.geonames.org/)，见 `Resources/bot-place-names.txt`。 |
| SQLite | 苹果端使用系统库，Android 编译固定的 SQLite amalgamation | SQLite 是公有领域。Android 源码地址及 SHA3-256 见 `Scripts/prepare-android-sqlite.sh source-info`。 |
| GitHub Copilot Go SDK | Mac 的可选 Copilot 桥接 | 版本和校验见 `copilot/go.mod`、`copilot/go.sum`。SDK 许可随桥接打包。 |
| GitHub Copilot CLI 运行时 | 可选的预编译运行时 | 使用 GitHub 的独立许可。构建脚本校验上游下载的哈希，按架构打包原始运行时和随附许可。 |

源码包包括 AAUV 的源码、构建脚本、锁文件、固定版本的 sing-box 和 Swift 依赖，以及按当前构建目标选出的 Go 模块源码和 Android SQLite 源码。Swift 镜像保留锁定提交，Go 模块及版本元数据可用本地文件代理读取。`ThirdPartySources/inventory.json` 记录来源、版本和校验值。Copilot 的预编译运行时由可选构建脚本单独获取。

Mac 本地测试包将应用与对应源码一起打包。Copilot 预编译运行时保留上游字节、签名和独立许可，其许可允许作为提供额外功能的应用的一部分分发。iOS 设备签名与最终渠道条款仍需针对所选渠道核对。[GitHub Copilot CLI 许可](https://github.com/github/copilot-cli/blob/main/LICENSE.md)

- [GNU GPLv3 正文](https://www.gnu.org/licenses/gpl-3.0.en.html)
- [sing-box 上游项目](https://github.com/SagerNet/sing-box)
- [GitHub Copilot CLI 发布页](https://github.com/github/copilot-cli/releases)
