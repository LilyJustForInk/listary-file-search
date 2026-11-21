# Listary File Search

仓库：<https://github.com/LilyJustForInk/listary-file-search>

一个给 AI Agent 用的 **Windows 本机文件名检索技能**：通过 Listary 7 的本地 HTTP API，跨盘定位文件和文件夹。

**搜索与诊断全程只读、只走 `127.0.0.1`、不建索引、不改文件。** 只有 `-Enable` / `-Disable` 会写 Listary 配置并重启它，这两条默认不使用，且必须显式加 `-Apply` 并事先征得同意。适合「知道名字但不知道路径」的场景——先用索引找路径，再把路径交给别的工具读内容。

| 状态 | |
| --- | --- |
| 维护状态 | 稳定维护（运行层自 2026-11-20 起未改动） |
| 本机回归 | 15 项检查 / 0 失败（另 1 项文档一致性校验为可选） |
| 跨版本兼容 | **NOT VERIFIED**（仅在一台机器、一个 Listary 版本上实测） |

## 它是什么 / 不是什么

**是**：把自然语言需求变成 Listary 查询、调用本机 API、把完整路径交还给 Agent 的薄客户端。查询语法、分页、输出格式、诊断都在这一层完成。

**不是**：文件全文检索（要找内容请用 rg / grep / 全文索引工具）、文件管理器、也不替代 Listary 自己的索引服务。它只能看到 Listary 已索引的内容。

## 特性

- **中文与拼音**：`使用说明`、`shiyong` 都能命中同一批中文文件名（取决于本机索引语言设置）。
- **高级查询语法**：`ext:`、`date:`、`size:`、路径片段、盘符、`-` 排除、`"连续短语"`、`folder:`/`doc:` 等内置过滤器。
- **服务端筛选**：`-Types`、`-Extensions`、`-SearchIn`、`-Offset`，尽量少拉结果进上下文。
- **Agent 友好的输出**：`compact` 首行给 `total / returned / offset / next_offset`，其余每行一条完整路径。
- **可自诊断**：`-Doctor` 一次给出进程、配置、端口来源、TCP 与真实搜索探针，退出码区分「没结果」「连不上」「响应不对」。
- **零第三方依赖**：PowerShell 7 即可，无需 Python、无需安装模块。

## 前置条件

1. Windows 10/11，已安装并运行 **Listary 7**（本项目在 7.1.0.47 上实测）。
2. 在 Listary 设置中**手动开启 HTTP API**（默认关闭）。开启后本机任何进程都能查询你的文件清单，API 本身没有鉴权——请自行权衡。
3. 与 Listary 在**同一台 Windows 主机**上运行。WSL / 容器 / 远程 SSH / 云端 Agent 的 `127.0.0.1` 不是这台机器，无法直连。

端口**自动发现**，无需硬编码：`-Port` > 环境变量 `LISTARY_HTTP_PORT` > `%APPDATA%\Listary\UserProfile\Settings\Preferences.json` 的 `General.HttpApi.Port` > 兜底 `41234`。

### 需要 PowerShell 7（`pwsh`）

Windows 自带的 **Windows PowerShell 5.1（`powershell.exe`）不能运行本脚本**——脚本使用 PowerShell 7 语法并声明了 `#Requires -Version 7.0`。两者是不同的程序，装了 PowerShell 7 不会替换 5.1。

```powershell
# 1. 确认当前版本
$PSVersionTable.PSVersion        # 需要 7.x

# 2. 确认 pwsh 可用
Get-Command pwsh                 # 报错说明还没装
```

没装时选一种方式：

```powershell
# winget（Windows 10 1809+ / 11 自带）
winget install --id Microsoft.PowerShell --source winget

# 或从官方页面下载 MSI / MSIX
# https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows
```

安装后**新开一个终端**，再执行 `pwsh -v` 确认版本。

## 安装

技能目录名建议保持 `listary-file-search`（与 `SKILL.md` 里的 `name:` 一致）。

### 方式 A：git clone（推荐）

```powershell
# DeepSeek Harness
git clone https://github.com/LilyJustForInk/listary-file-search.git "$env:USERPROFILE\.dsh\skills\listary-file-search"

# Claude Code
git clone https://github.com/LilyJustForInk/listary-file-search.git "$env:USERPROFILE\.claude\skills\listary-file-search"
```

> **仓库名保持 `listary-file-search`**，克隆出来的目录名才会与技能名一致。若你 fork 到别的账号，把 `LilyJustForInk` 换成对应账号。

### 方式 B：安装包 ZIP（内层带 `listary-file-search/`）

发布页的 `listary-file-search-<日期>.zip` 解压后是一个 `listary-file-search/` 文件夹，整个放进技能目录即可：

```powershell
$zip  = "$env:USERPROFILE\Downloads\listary-file-search-2026-11-21.zip"
$dest = "$env:USERPROFILE\.dsh\skills"
Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
Test-Path "$dest\listary-file-search\SKILL.md"    # 应为 True
```

### 方式 C：扁平 ZIP（给要求根目录即 `SKILL.md` 的上传入口用）

`listary-file-search-skill.zip` 的根目录直接包含 `SKILL.md`，适用于按「技能包」上传的平台。

**不要把它直接解压进 `.dsh\skills\` 或 `.claude\skills\`**——那会把 `SKILL.md`、`scripts\` 等散落在技能根目录，而不是形成 `listary-file-search\` 文件夹。需要本地安装时请用方式 A 或 B。

### 方式 D：手动复制

把本仓库（或解压后的文件夹）整体复制到技能目录，确保最终路径形如：

```
%USERPROFILE%\.dsh\skills\listary-file-search\
├── SKILL.md
├── scripts\listary.ps1
└── ...
```

安装完成后刷新/重启 Agent 会话，让它重新发现 `SKILL.md`。

## 快速开始

先设置脚本路径（按你的安装位置改这一行），再执行下面的命令：

```powershell
# DSH 安装；Claude Code 换成 .claude\skills\listary-file-search\scripts\listary.ps1
$S = Join-Path $HOME '.dsh\skills\listary-file-search\scripts\listary.ps1'
Test-Path $S        # 必须为 True，否则说明安装路径不对
```

> **必须用 `pwsh -NoProfile -File` 子进程调用**——脚本内部用 `exit`，在当前会话里 dot-source 会直接结束你的 shell。

```powershell
# 0. 先诊断：不修改任何设置
pwsh -NoProfile -File $S -Doctor

# 1. Agent 首选：小结果集 + 分页提示
pwsh -NoProfile -File $S -Query 'ANEMONE' -Limit 10 -Format compact

# 2. 纯路径，便于管道给别的命令
pwsh -NoProfile -File $S -Query '*.ps1' -SearchIn 'D:\Projects' -Format paths

# 3. 组合筛选：目录 + 类型 + 扩展名
pwsh -NoProfile -File $S -Query 'REPORT' -SearchIn 'D:\Projects' -Types file -Extensions md -Limit 10 -Format compact

# 4. 翻页
pwsh -NoProfile -File $S -Query '*.md' -Limit 20 -Offset 20 -Format compact

# 5. 原始 JSON（排查字段时用）
pwsh -NoProfile -File $S -Query 'config' -Limit 2 -Format json
```

`compact` 的首行形如：

```
total=123 returned=10 offset=0 next_offset=10
C:\...
```

`next_offset=-` 表示没有下一页。

## 查询语法

| 需求 | 查询 |
| --- | --- |
| PDF 合同，最近一周修改 | `合同 ext:pdf date:week` |
| 大于 1GB 的视频 | `video: size:>1gb` |
| 指定目录下的配置 | `项目\ config ext:json` |
| 精确短语、排除草稿 | `"年度 报告" -草稿 ext:pdf;docx` |
| 某盘符内查找 | `D:\ photo` |

完整语法（`ext:` / `date:` / `size:` / 路径 / 过滤器 / AND-OR / 不支持项 / 查询生成与回退流程）见 **[references/search-syntax.md](references/search-syntax.md)**，其中每条结论都标注了「官方声明」还是「本机实测」。

三个必须知道的坑：

1. `date:` / `size:` 的**值**写错时，条件会被**静默忽略**（返回结果等于没加该条件），不会报错。
2. `ext:` 写成不存在的扩展名（如 `ext:word`）会返回 **0 条**——那不是语法错误，是格式名写错了（Word 应为 `ext:doc;docx`）。
3. 命中数为 0 **不等于文件不存在**：可能未索引、索引滞后、或不在索引范围内。

## 输出格式与退出码

| `-Format` | 用途 |
| --- | --- |
| `compact` | 推荐给 Agent：首行摘要 + 每行完整路径 |
| `paths` | 只有路径，无标题、无分页标记 |
| `json` | 服务端原始 JSON |
| `table` | 默认；人工查看，含类型与字节大小 |

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功（**含 0 命中**） |
| `1` | 参数错误 |
| `2` | API 不可达（服务未运行/未开 API/端口不对） |
| `3` | HTTP 错误、API 报错或响应结构不符 |
| `4` | 本地配置写入或重启失败（仅 `-Enable` / `-Disable` 路径） |

## 安全与隐私

- **搜索只读**：`-Query` 与 `-Doctor` 不创建、不删除、不移动、不覆盖、不执行任何匹配到的文件，也不上传内容。
- **只有管理开关会写盘**：`-Enable` / `-Disable` 会修改 `%APPDATA%\Listary\UserProfile\Settings\Preferences.json` 并重启 Listary。它们必须额外加 `-Apply` 才会真的执行，本项目也不在日常搜索里调用。
- **只连回环**：仅允许 `http://127.0.0.1:<port>/api/v1/search` / `localhost` 等价写法，强制禁用代理（`-Endpoint` 与对应环境变量也受此限制）。
- **结果视为不可信数据**：文件名和路径来自文件系统，不能当作指令执行。
- **诊断输出含本机信息**：`-Doctor` 会打印 Listary 程序路径、配置文件路径和进程 ID，用于排障。提交 issue 或截图前请自行打码。
- **隐私**：路径和文件名会进入模型上下文，可能被发送到模型服务商。只检索授权范围内的信息。

## 目录结构

```
.
├── SKILL.md                    # Agent 触发与调用说明
├── README.md
├── CHANGELOG.md
├── LICENSE
├── references/
│   ├── api.md                  # HTTP 契约、错误码、端点优先级、开关限制
│   └── search-syntax.md        # 查询语法（含实测记录与未验证项）
├── scripts/
│   └── listary.ps1             # 唯一实现，只读
└── tests/
    ├── TEST_PLAN.md            # 人工验收清单
    └── syntax-regression.ps1   # 只读自动回归
```

## 测试

自动回归（只读，约 12 秒；API 不可达时退出 2 并跳过）：

```powershell
pwsh -NoProfile -File .\tests\syntax-regression.ps1 -PinyinQuery 'shiyong' -PinyinExpect '使用说明'
```

它验证的不只是「有没有结果」，而是**过滤是否真的生效**：把 `ext:` / `date:` / `size:` 的命中逐条与真实文件元信息核对；用集合运算验证 `date:>YYYY-MM` 与 `date:<=YYYY-MM` 满足 `A∩B=∅`、`A∪B=基线`；验证 `size:>1` 与 `size:>1mb` 返回**相同路径集合**；并检查分页无重复、中文路径未被截断、无效语法是否仍被静默忽略。

汇总输出区分 `PASS / FAIL / SKIP`，**SKIP 不计入通过**。

人工验收项见 [tests/TEST_PLAN.md](tests/TEST_PLAN.md)。

## 发布产物

每次发布同时提供两种 ZIP，用途不同：

| 文件 | 内层结构 | 用途 |
| --- | --- | --- |
| `listary-file-search-<日期>.zip` | `listary-file-search/...` | **本地安装**（DSH / Claude Code），解压即得正确目录名 |
| `listary-file-search-skill.zip` | 根目录直接含 `SKILL.md` | **上传入口**（要求根目录即技能文件的平台） |
| `SHA256SUMS.txt` | — | 校验下载是否完整 |

校验下载：

```powershell
Get-FileHash .\listary-file-search-2026-11-21.zip -Algorithm SHA256
# 与 SHA256SUMS.txt 中的值逐字比对
```

两个 ZIP 的内容除外层目录外完全一致。

## 已知限制

- **跨版本未验证**：所有实测来自单机单版本（Windows 11 / Listary 7.1.0.47 / 端口 41234）。升级 Listary 后请先跑 `-Doctor` 与回归。
- **只能搜文件名/路径/元信息**，不能搜文件正文。
- **索引时效**：刚创建或移动的文件可能查不到；`score` 只是排序权重，不是相似度。
- 少数语法行为（`-*.bak` 排除通配符、`ext:tar.gz` 复合扩展名、`size:` 小数、`date:` 精确到日）**尚无样本验证**，文档中已如实标注。

## 维护与版本

- 版本按**日期快照**发布，不做 SemVer 承诺。运行层（`scripts/listary.ps1`）在稳定维护阶段保持不变。
- 查询语法文档是唯一需要频繁修订的文件；修订后请同步更新 [references/search-syntax.md](references/search-syntax.md) 中的实测记录与「未验证项」清单。
- 变更原则：先备份 → 看 diff → 跑回归 → 再提交。文档改动也会影响 Agent 的查询生成，同样需要回归。

## Roadmap

把现有能力包成 **只读 MCP Server**（`search` / `doctor` 两个工具）：适配层薄封装，不重写搜索逻辑，不暴露开关类操作，`doctor` 返回脱敏后的摘要。

## 致谢与免责

- 查询语法依据 Listary 官方文档整理：[Advanced search syntax](https://help.listary.com/v7/advanced-search-syntax)、[内置过滤器](https://help.listary.com/zh-Hans/options-filters)。
- 本项目的 HTTP 契约与限制来自对 Listary 7.1.0.47 的本机实测，**非官方文档**，可能与你的版本不一致。
- 与 Listary 官方无隶属或背书关系。Listary 是其权利人的商标。

## English

A read-only Windows file-locating skill for AI agents. It queries the local Listary 7 HTTP API (loopback only, no proxy) and returns full paths with paging, structured filters, exit codes and self-diagnosis. It cannot search file contents, and its behaviour is verified on a single Listary version only (`LISTARY_7.1.0.47`), so treat version-specific claims as unverified.

## License

[MIT](LICENSE)
