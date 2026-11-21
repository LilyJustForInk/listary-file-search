# Changelog

本仓库按**日期快照**维护，不做 SemVer 承诺。
（早期内部归档使用的 `v1.0.0` / `v2.0.0` / `v2.0.1-patched` 只是归档标签，不是公开发行版本号，勿与本仓库的发布历史混用。）

## 2026-11-21 — 首次公开

**运行层**：`scripts/listary.ps1` 沿用稳定实现，未改动（SHA256 `DEAEE30B…7798`）。

### 新增
- `tests/syntax-regression.ps1`：只读自动回归，覆盖 `ext:` / `date:` / `size:` 是否真的生效、中文与拼音、分页去重、中文路径完整性，以及「无效语法被静默忽略」的行为是否与文档一致。
- 支持可选的文档一致性校验：`-ReferenceSyntaxPath <path>`，哈希不一致即失败；不提供时只跑功能回归。
- 集合级断言：`date:>YYYY-MM` 与 `date:<=YYYY-MM` 需满足 `A∩B=∅` 且 `A∪B=基线集合`；`size:>1` 与 `size:>1mb` 需返回相同路径集合。
- 汇总区分 `PASS / FAIL / SKIP`，SKIP 不计入通过。

### 文档
- 安装章节改为四种可复制的方式（git clone / 安装包 ZIP / 扁平 ZIP / 手工复制），去掉无法执行的 `<repo-url>` 占位。
- 快速开始补上 `$S` 的实际赋值与 `Test-Path` 自检，避免照着命令抄却不知道 `$S` 是什么。
- 新增「需要 PowerShell 7」小节：`$PSVersionTable` / `Get-Command pwsh` 自检、winget 与官方安装链接，并说明 5.1 与 7 是两个程序。
- 修正开头「只读」的表述：搜索与诊断只读；只有 `-Enable` / `-Disable` 会写配置并重启 Listary，且必须显式 `-Apply`。
- 补充 `-Doctor` 会输出程序路径、配置路径与进程 ID 的隐私提示。
- 新增「发布产物」章节：两种 ZIP 的用途、SHA256 校验方法。
- `references/search-syntax.md` 扩为完整参考（245+ 行）：精确短语、排除、`ext:`、`date:`、`size:`、路径与盘符、内置类型过滤器、AND/OR/交集、明确不支持的语法、自然语言到查询的生成与回退流程。
- 增加「本机实测记录」附录（19 组查询的命中数与结论）与**未验证项清单**。
- 全文标注 **Cross-version compatibility: NOT VERIFIED**。
- `ext:` 的表述限定为「当前实测版本表现为硬过滤」，不断言未来版本行为。
- `folder:` 冒号后空格修正为「非硬性要求」（实测两种写法结果相同）。

### 修复（相对早期内部版本）
- 端口从硬编码 `38431` 改为自动发现（`-Port` → `LISTARY_HTTP_PORT` → `Preferences.json` → 兜底 `41234`）。
- 新增分页 `-Offset`。
- 响应契约校验：非 Listary 响应退出 `3`，不再把任意 JSON 当作成功。

## 2026-11-20 — 内部版本

首次可用实现：`SKILL.md` + `listary.ps1`（只读、回环、`-Doctor`、`compact/paths/json/table` 四种输出、`-Enable/-Disable` 需 `-Apply` 且带备份回滚）。

## 未验证

- 跨 Windows / Listary 版本的兼容性：仅在 Windows 11 + Listary 7.1.0.47 上实测。
- `-*.bak` 排除通配符、`ext:tar.gz` 复合扩展名、`size:` 小数、`date:` 精确到日：本机缺样本，未验证。
