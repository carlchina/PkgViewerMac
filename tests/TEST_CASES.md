# PkgViewerMac 测试用例 — `TEST/` 包

> 生成日期：2026-10-05
> 被测版本：`build/PkgViewer.app`（`CFBundleShortVersionString 1.1`，`CFBundleVersion 3`）
> 测试对象目录：`/Volumes/512 1/TEST`
> 配套脚本：`tests/run_test_cases.py`（自动化，见文末）

## 1. 测试对象总览

| 编号 | 对象 | 文件 | 平台 / 格式 | 体积 | 关键特征 |
|---|---|---|---|---|---|
| **F1** | ACA NEOGEO KOF 2002（Base Game） | `JP0571-CUSA13694_00-HAMPRDC000000001-A0100-V0100-CyB1K.pkg` | PS4 CNT / FPKG | 168.19 MB | Base Game v1.00，31 条，含 `trophy/trophy00.trp`（TRP，ESFM 加密，6 奖杯，日文名） |
| **F2** | ACA NEOGEO KOF 2002（Update） | `JP0571-CUSA13694_00-HAMPRDC000000001-A0101-V0100-CyB1K.pkg` | PS4 CNT / FPKG | 168.12 MB | Update v1.01（Base 1.00），38 条 |
| **F3** | Hades II | `PPSA36082-Hades2.pkg` | PS5 finalized FIH / FPKG | 7.95 GB | Application v1.006.000，29 条，含 `trophy2/trophy00.ucp`（UCP，13 MB，50 奖杯），5 张封面 |
| **F4** | Shovel Knight | `UP2200-NPUB31682_00-...pkg/`（**目录包装**，内含同名 `.pkg`） | PS3 NPDRM retail | 185.53 MB | **exFAT 下载目录包装**场景，102 文件，含 `TROPDIR/NPWR08388_00/TROPHY.TRP`（明文 SFM，38 奖杯） |

> F1/F2 同标题不同版本/类型，用于验证「Base Game vs Update」与「版本识别」。
> F3 是大型 PS5 包 + 大 UCP 奖杯包，用于验证 >64MB 容器读取（A1 修复）与封面内存优化（C1）。
> F4 是 **目录形式** 的 exFAT 下载包，用于验证目录自动解包（`unwrapSingleFileDirectory`）。

## 2. 执行环境与前置

- 运行 `./build.sh` 完成最新构建，生成 `build/PkgViewer.app`。
- macOS 12+；CLI 使用 `build/PkgViewer.app/Contents/MacOS/PkgViewer`。
- `TEST/` 目录内存在上述 4 个对象（自动跳过缺失项）。
- 系统语言为简体中文（`zh-Hans-CN`），影响语言/奖杯文本预测结果。

## 3. 用例清单（自动化部分）

用例执行方式：`python3 tests/run_test_cases.py "/Volumes/512 1/TEST"`。每个对象跑 `--info` / `--covers` / `--trophies` 三组断言。

### TC-A 基础信息解析（--info）

| 用例 | 对象 | 断言项（预期） | 结果 | 状态 |
|---|---|---|---|---|
| TC-A01 | F1 | `Title=ACA NEOGEO THE KING OF FIGHTERS 2002`、`Platform=PS4 (CNT metadata)`、`Package=FPKG (Fake)`、`Title ID=CUSA13694`、`Content ID=JP0571-CUSA13694_00-HAMPRDC000000001`、`Region=Japan`、`Type=Base Game`、`Version=01.00`、`Entries=31`、`format=ps4` | 全部命中 | ✅ PASS |
| TC-A02 | F2 | 同上标题/平台/Title ID/Region；`Type=Update`、`Version=01.01`、`Base Version=01.00`、`Entries=38` | 全部命中 | ✅ PASS |
| TC-A03 | F3 | `Title=Hades II`、`Platform=PS5 (finalized FIH)`、`Package=FPKG (Fake)`、`Signature=debug`、`Title ID=PPSA36082`、`Content ID=EP4484-PPSA36082_00-0912328937643383`、`Region=Europe`、`Type=Application (APP)`、`Content Ver=01.006.000`、`Master Ver=01.00`、`Concept ID=10018449`、`Min. System=9.00`、`DRM=Standard`、`Entries=29` | 全部命中 | ✅ PASS |
| TC-A04 | F4 | `Title=Shovel Knight`、`Platform=PS3 NPDRM (retail)`、`Content ID=UP2200-NPUB31682_00-SHOVELKNIGHT0001`、`Title ID=NPUB31682`、`Region=Americas`、`Version=01.02`、`Min. System=04.7000`、`Files=102` | 全部命中 | ✅ PASS |

### TC-B 封面提取（--covers）

| 用例 | 对象 | 断言项（预期） | 结果 | 状态 |
|---|---|---|---|---|
| TC-B01 | F1 | `icon=icon0.png`、`candidates=6`、`icon0=126183B`、`pic1=1541666B` | 全部命中 | ✅ PASS |
| TC-B02 | F2 | `icon=icon0.png`、`candidates=6` | 全部命中 | ✅ PASS |
| TC-B03 | F3 | `icon=icon0.png`、`candidates=5`、`icon0=428958B`、`pic1=4977596B`（另含 `pic0`、`pic2`、`save_data` 5 张，全部写出） | 全部命中 | ✅ PASS |
| TC-B04 | F4 | `resolved path`（已解包到内部 `.pkg`）、`icon=ICON0.PNG`、`candidates=3`（`ICON0.PNG`、`PIC1.PNG`、`USRDIR/data/SAVEICON0.PNG`） | 全部命中 | ✅ PASS |

### TC-C 奖杯解析（--trophies）

| 用例 | 对象 | 断言项（预期） | 结果 | 状态 |
|---|---|---|---|---|
| TC-C01 | F1 | 选中 `trophy/trophy00.trp`、`NpCommId=NPWR16488_00`、`Trophies=6`、`RESULT=OK`（ESFM 加密，key search≈0.49s，日文名从 `TROP_00.ESFM` 提取） | 全部命中 | ✅ PASS |
| TC-C02 | F2 | 选中 `trophy/trophy00.trp`、`RESULT=OK` | 全部命中 | ✅ PASS |
| TC-C03 | F3 | 选中 `trophy2/trophy00.ucp`（13 MB）、`NpCommId=NPWR59398_00`、`Trophies=50`、`RESULT=OK`（69 成员、17 语言、简体中文显示、50/50 奖杯有图） | 全部命中 | ✅ PASS |
| TC-C04 | F4 | 选中 `TROPDIR/NPWR08388_00/TROPHY.TRP`、`plain XML=yes (no key needed)`、`NpCommId=NPWR08388_00`、`Trophies=38`、`RESULT=OK` | 全部命中 | ✅ PASS（修复后） |

## 4. 其余测试项

### TC-D 本地化与语言

| 用例 | 命令 | 预期 | 结果 | 状态 |
|---|---|---|---|---|
| TC-D01 | `--languages` | 4 语言：`en`、`zh-Hans`、`zh-Hant`、`ja`；系统偏好 `zh-Hans-CN`，当前 `zh-Hans` | 命中 | ✅ PASS |
| TC-D02 | `--lang-check` | `all sampled keys resolved`（本地化 key 一致，含 `drop.choose` 等） | 命中 | ✅ PASS |

### TC-E 容器 / 目录处理

| 用例 | 对象 | 预期 | 结果 | 状态 |
|---|---|---|---|---|
| TC-E01 | F4（目录包装） | `--covers` 的 `resolved path` 指向内部同名 `.pkg`；`--info`/`--trophies` 均自动解包，102 文件正常列出 | 命中 | ✅ PASS |
| TC-E02 | F1/F2 | 标准单文件 PKG 直接解析，无解包 | 命中 | ✅ PASS |

### TC-F GUI（手动）

| 用例 | 操作 | 预期 | 状态 |
|---|---|---|---|
| TC-F01 | 打开 F1 | 概览页显示封面、标题、规格；文件页列出 31 条；奖杯页能加载 TRP | ⬜ 手动 |
| TC-F02 | 打开 F3（8.5GB） | 快速进入（解析 <0.2s）；封面 5 张缩略图；奖杯页 50 条；内存不因封面全量读入而飙升（C1 优化） | ⬜ 手动 |
| TC-F03 | 打开 F4 | 目录包装自动解包，PS3 页显示 102 文件；奖杯页 38 条 | ⬜ 手动 |
| TC-F04 | 概览页点封面缩略图 | 切换到对应封面并加载完整图（惰性 `loadCoverFull`） | ⬜ 手动 |
| TC-F05 | `--test-screenshot <url>` | 生成截图 PNG（需图形会话） | ⬜ 手动 |

### TC-G 整体回归

| 用例 | 命令 | 预期 | 结果 | 状态 |
|---|---|---|---|---|
| TC-G01 | `./verify.sh` | `ALL FIELDS MATCH`（sample.pkg / sample.exfat 与 Python 原版逐字段对比） | 命中 | ✅ PASS |
| TC-G02 | `python3 tests/run_test_cases.py` | `12/12 checks passed` | 命中 | ✅ PASS |

## 5. 本次测试发现的缺陷与修复

| 缺陷 | 表现 | 根因 | 修复 |
|---|---|---|---|
| **BUG-1** | F4（PS3 目录包装）执行 `--trophies` 报 `cannot open`，奖杯无法读出 | `TrophyPrinter.run` 用用户传入的原始 `url` 打开读句柄；exFAT 下载包是**目录**，`FileHandleReader` 无法读目录 → 返回 nil。而 `--covers` 与 GUI 都使用 `PkgLoader.load` 解包后的 `res.path`，故不受影响 | 改为使用 `res.path`（与 `InfoPrinter.printCovers`/`PkgViewModel.open` 保持一致），修复后 F4 奖杯 `RESULT=OK` |

> 同步发现：A0101（Update）能正确识别 `Base Version=01.00` 与 `Type=Update`，验证了版本/更新识别逻辑；Hades II 的 13MB UCP 奖杯包读取正常，覆盖了 A1（大容器内存映射）与 C1（封面惰性加载）的回归点。

## 6. 一键回归

```bash
cd ~/WorkBuddy/PS5/PkgViewerMac
./build.sh                       # 先构建最新 app
python3 tests/run_test_cases.py "/Volumes/512 1/TEST"   # 自动化回归，退出码 0 即全部通过
./verify.sh                      # 与 Python 原版字段对比
```
