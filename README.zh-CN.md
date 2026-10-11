# PKG Viewer — macOS

[English](README.md) · 简体中文

<img width="940" height="648" alt="image" src="https://github.com/user-attachments/assets/31085614-f2e9-48f6-bdab-86c661ea260d" />


一款原生 macOS 的 PlayStation 安装包查看器。无需解包即可查看 PS3/PS4/PS5 内容。

Swift + SwiftUI，不依赖 Python，无运行时依赖 —— 解析器、加解密与界面全部在进程内完成。

- **原始项目：** [pkg-viewer](https://github.com/Loopayeh/pkg-viewer)，作者
  [Loopayeh](https://github.com/Loopayeh)（MIT）
- **macOS 移植版：** CarlChina

本移植版还参考了其他项目，详见[致谢](#致谢)。

## 安装

从 [releases](https://github.com/carlchina/PkgViewerMac/releases) 下载
`PkgViewer-1.2.2-universal.zip`，然后：

```bash
unzip PkgViewer-1.2.2-universal.zip
xattr -r -d com.apple.quarantine PkgViewer.app     # 见下方说明
open PkgViewer.app
```

**为什么需要 `xattr` 这一步。** 下载的文件是**临时签名（ad-hoc signed）**，并未使用
Developer ID 证书签名，也没有做过公证（notarization）。因此 macOS 会将其视为未经验证的
开发者：`spctl` 报告 `rejected`，Gatekeeper 会阻止启动。`com.apple.quarantine`
属性正是触发这一行为的标记，清除它就等于告诉 Gatekeeper「你已经自行做出了判断」。

从源码构建（见下节）可以完全绕开这个问题 —— 应用在本地生成，永远不会被加上隔离标记。

只要条件允许，从源码构建都是更好的选择：任何装有 Command Line Tools 的 Mac 都能轻松
完成，你能确切知道自己运行的是什么，而且你信任的是自己本就拥有的编译器，而不是一个
预编译的二进制文件。如果你只是想快速看看，或者所处的机器上搭建工具链不划算，那就用
下载版。

首次启动时也可以右键点击应用并选择**打开**，这与上述命令表达的是同一个决定。

## 构建

```bash
./build.sh          # 生成 build/PkgViewer.app
open build/PkgViewer.app
```

只需 Swift 工具链 —— Command Line Tools 即可，不必安装完整的 Xcode。

默认构建为**通用二进制**（arm64 + x86_64），因此在 Apple 芯片与 Intel 机器上都能运行。
耗时较多的是交叉编译；不需要双架构时可以收窄：

```bash
ARCHS=arm64 ./build.sh          # 仅原生架构，更快
ARCHS=x86_64 ./build.sh         # 仅 Intel
```

脚本会将成品二进制中的架构与 `ARCHS` 比对，不一致就报错，因此单架构的产物不会被
悄悄发布出去。

每次构建都会递增版本号后括号里的数字（`1.2.2 (22)`），便于将截图或问题报告对应到
确切的二进制。该计数器会从上一个 bundle 中读回，因此全新克隆从 `1` 开始，删掉
`build/` 也会重新从 `1` 开始。发布时可以锁定它：

```bash
NO_BUMP=1 ./build.sh       # 保持当前数字
BUILD=42 ./build.sh        # 指定为固定值
```

## 支持的格式

| | 格式 | 说明 |
|---|---|---|
| PS4 | `.pkg` (CNT) | 元数据、条目、封面 |
| PS5 | `.pkg` (FIH + CNT) | 元数据、条目、封面、奖杯 |
| PS5 | `.exfat` 镜像 | 只读、封面、奖杯包 |
| PS3 | `.pkg` (NPDRM) | retail 与 debug，AES / SHA-1 解密 |
| PS5 | 单独的 `.ucp` / `.trp` | 独立读取的奖杯归档 |
| — | 游戏文件夹 | `sce_sys/param.json`、`PS3_GAME/`、NPDRM 解包 |
| PS5 | `.ffpkg` | UFS2 镜像 —— 元数据与主视觉 |
| PS5 | `.ffpfsc` | 包裹压缩 `pfs_image.dat` 的 PFS 镜像 —— 元数据与主视觉 |
| Switch | `.nsp`、`.xci` | 安装包与游戏卡镜像 |
| Switch | `.nsz`、`.xcz` | 上述两者的压缩形式 |

`.ffpfsc` 为进程内读取：PFS inode 表与压缩的内层镜像均按需解码，多 GB 的负载不会被
解包到磁盘。

Switch 的元数据取自安装包内的 `cnmt.xml`，或其 Meta NCA 中的二进制 CNMT。将
`prod.keys` 安装到 `~/.switch/prod.keys` 还可解锁官方的 NACP 标题、发行商、显示版本
与图标，以及权威的逐 NCA 类型。被 NSZ 重新打包为 `.ncz` 的条目会标记为压缩 —— 它们
的头部随压缩一同处理。

## 功能

- **封面** 带缩略图栏；可保存或复制到剪贴板
- **主视觉作为概览页背景**
- **摘要标签** —— 平台、区域、大小、类型、安装包
- **文件标签页** —— 每个条目均带筛选与内联预览
- **奖杯标签页** —— 支持两种归档格式，点击查看单个奖杯图标，可导出
  - **多语言奖杯文本** —— 奖杯标签页提供语言菜单，列出该奖杯包实际包含的所有 locale，
    因此一款有 17 种翻译的游戏无需离开应用即可用任意一种阅读。默认从奖杯包自身的默认
    语言（即主机上显示的语言）开始，其次回退到界面语言，再回退到英文；显式选择永远
    优先。切换语言只重新读取元数据，已加载的图标得以保留，列表也不会重新扫描。
    导出工具并不总能保证 `tropmeta_<locale>.json` 与其内容一一对应，因此每个文件的
    脚本会被检测，与文本矛盾的标签会被纠正 —— 对汉字/假名/谚文/西里尔/阿拉伯/泰语
    语系是精确的。
  - 奖杯等级与隐藏标记读取自奖杯包的**配置**，而非各语言文件，因此无论选择哪种语言
    都保持正确。
- **重命名** —— `标题 - TID - v版本 - 区域`，带实时预览
- **截图** —— 以完整 Retina 分辨率将窗口保存为 PNG
- **拖放**，并支持 Open With 与双击打开
- **语言** —— English、简体中文、繁體中文、日本語

请注意两者是独立的：*界面*语言（即上表）与*奖杯*语言（由奖杯包提供）分别选择。

### 外观

全面采用系统外观，浅色与深色皆可，通过语义化颜色与材质实现，因此「减弱透明度」与
「增强对比度」等辅助功能设置得以被真正遵循，而不是被绕开。在 macOS 26+ 上标签栏
采用 Liquid Glass，其中一个窗格会在标签间滑动；较旧的系统则使用平涂。部署目标为
macOS 12。

承载含义的颜色按外观分别声明，而非固定值。徽章与奖杯等级的配色最初是为深色界面挑选
的 —— 在那里 PS5 的近白色标签体现为「最新主机」—— 但在浅色背景上同样的数值就是白底
白字。每种颜色都配有为浅色背景加深过的对应版本，并通过对比度测量（而非肉眼）加以验证。

元数据的值按安装包的原始存储方式展示；只有字段标签会被翻译。中文标签配英文取值，能让
此面板与文件本身、CLI 输出以及 Copy Info 保持一致。

## 命令行

```bash
PkgViewer --info <file>          # 安装包摘要
PkgViewer --trophies <file>      # 奖杯包导出
PkgViewer --covers <file>        # 封面，可加 --export-to <dir>
PkgViewer --languages            # 列出内置的本地化
PkgViewer --lang-check [code]    # 导出全部界面字符串以供审阅
```

CLI 输出有意保持英文：字段名是一份稳定的契约，`verify.sh` 会据此与原版逐项比对。

## 添加一种语言

1. 将 `Sources/Resources/en.lproj` 复制为 `<code>.lproj` 并翻译其中的值。
2. 在 `L10n.Language.all` 中注册该语言代码。
3. 在 `build.sh` 的 `CFBundleLocalizations` 中加入它。
4. 运行 `PkgViewer --lang-check <code>` —— 缺失的键会直接以键名本身打印出来。

`en` 是基础语言；其余文件应与其逐键对应。

## 验证

`verify.sh` 会用本次构建与 Python 原版处理同一批文件，并逐项比对每个元数据字段以及
条目清单：

```bash
./verify.sh          # → ALL FIELDS MATCH
```

## 给贡献者的说明

在改动解析器之前值得了解的实现细节 —— 容器布局、NPDRM 密钥流、ESFM 密钥搜索、
UCP/TRP 的差异等 —— 都记录在相关代码的注释中。其中有两点特别容易踩坑：

- **`Data.subdata(in:)` 遇到越界索引会 trap**，而不是返回 nil。所有读取都已做边界检查；
  请保持这一点。
- **容器条目表是权威依据。** UCP 与 TRP 都在头部记录了成员数量。请严格读取该数量的
  条目，而不是扫描到看起来不对劲为止 —— 扫描会静默丢弃负载为零长度的条目。

## 致谢

本移植版的诞生得益于以下项目，也是通过阅读它们构建出来的：

- **[Loopayeh/pkg-viewer](https://github.com/Loopayeh/pkg-viewer)** —— 原始项目。解析器、
  命令行形态、摘要徽章与整体功能集都沿袭自它；本项目是一次 Swift/SwiftUI 重写，
  而非 fork。
- **[pearlxcore/PkgViewer](https://github.com/pearlxcore/PkgViewer)** 及其所依赖的
  [PS4PKGTool](https://github.com/pearlxcore/PS4PKGTool) /
  [PS5PKGTool](https://github.com/pearlxcore/PS5PKGTool) 库。它们的读取器是
  **TRP 与 UCP 容器布局**的参考 —— 字段偏移、头部版本、条目大小 —— 也是 PS5 奖杯元数据中
  配置/文本分离的参考。这些偏移在本项目中一度是错的，直到与这些项目核对后才修正；
  `Trophy.swift` 中的注释引用了它们。
- **[PSBrew/MkPFS](https://github.com/PSBrew/MkPFS)** —— **`.ffpfsc` 的 PFS + PFSC 布局**
  参考：外层 PFS inode 表、super-root 的 `uroot` 树，以及 PFSC 块偏移表与其 zlib 压缩的
  内层 `pfs_image.dat`。原版 pkg-viewer 依赖调用外部 mkpfs 处理该格式；这里改为一个
  自包含的 Swift 读取器（`PFS.swift`），借助系统 zlib 惰性解码各块，并使用 mkpfs 的
  CLI 对真实镜像交叉验证了读取器的正确性。
- **[psdevwiki](https://psdev.wiki)** 以及更广泛的 homebrew 社群，提供了 NPDRM 与 ESFM
  的格式文档，包括公开的奖杯主密钥。

也感谢每一位报告过无法解析的安装包的用户 —— 本次移植中修复的若干 bug 正是这样被发现的。

## 许可

MIT，与原始项目保持一致。

Copyright © Loopayeh（原始 pkg-viewer）· Copyright © CarlChina（macOS 移植版）。