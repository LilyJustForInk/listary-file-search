---
name: listary-file-search
description: Windows 本地按文件名、目录名、路径片段跨盘找文件。路径未知且 Listary 7 已索引时使用；支持中文与拼音、glob、按扩展名/日期/大小筛选、目录/类型过滤和分页。不能搜索文件正文；已知工作区内精确枚举用 glob，内容检索用 grep。
---

# Listary：文件名 → 完整路径

**使用场景：知道名字但不知道路径。** 避免先递归遍历整盘；只在已索引磁盘中查找。文件内容交给 grep，已知根目录的精确枚举交给 glob / `Get-ChildItem`。

**查询语法：** 只要用到 `ext:`、`date:`、`size:`、路径、排除、组合条件或拼音，先读 [`references/search-syntax.md`](references/search-syntax.md)——它记录的是**实测过**的语法与三个坑（无效 `date:`/`size:` 值会被静默忽略；`ext:` 写错只是零命中；`folder:` 后空格非必需）。这些结论只在一个 Listary 版本上验证过；升级 Listary 或结果异常时先跑 `tests/syntax-regression.ps1`（只读，退出码 0/1/2）。

## 调用

`$S` 指向**本 Skill 根目录**下 `scripts\listary.ps1` 的绝对路径。务必使用 `pwsh -NoProfile -File $S` **子进程调用**，不可用 `& $S` 在调用方会话内执行（脚本使用 `exit`）。

```powershell
# Agent 首选：最小结果集 + 分页提示
pwsh -NoProfile -File $S -Query 'ANEMONE' -Limit 10 -Format compact

# 纯路径，给其他命令继续处理
pwsh -NoProfile -File $S -Query '*.ps1' -SearchIn 'C:\Users' -Format paths

# 限定目录、类型和扩展名
pwsh -NoProfile -File $S -Query 'REPORT' -SearchIn 'D:\Projects' -Types file -Extensions md -Limit 10 -Format compact

# 只读诊断
pwsh -NoProfile -File $S -Doctor
```

`-Query` 必填（诊断/开关除外）；`-Limit` 1–100，默认 20；`-Offset` 零基分页；`-SearchIn` 绝对路径；`-Types` `file/folder`；`-Extensions` 如 `md` / `.pdf`；`-Format`：`compact`（推荐）、`paths`（无标题）、`json`（原始响应）、`table`（默认）。可用 `-Port` 或 `-Endpoint` 指定本地服务地址。

## 处理搜索结果

1. 优先 `-Limit 5~10`，必要时缩小目录/扩展名。找到目标就停止，不要将大批路径送入对话。
2. `compact` 首行是 `total / returned / offset / next_offset`，其后每行一条完整路径；`next_offset=-` 表示没有下一页。`paths` 只有路径，**不含总数或分页状态**。
3. `score` 仅是排序权重，不是相似度；同名的多个版本必须另行核对实际文件。`total=0` 不等于文件不存在（可能未索引或索引滞后）。
4. `-Doctor` 只读；`exit 2` 通常是 API 不可达，`exit 3` 是服务端/响应错误，不能当成零命中。

## 安全与权限

- **不得擅自调用 `-Enable` / `-Disable`。** 它们会更改设置并可能重启 Listary；必须先征得用户明确同意，再加 `-Apply`。开启后本机其他进程也能查询文件清单（无鉴权）。
- 为搜索文件**不需要也不应该**修改目录 ACL、取得所有权或授予完全控制权限。不要把全盘路径清单无必要地放入模型上下文。
- `exit 0` 成功（含零命中）；`1` 参数错；`2` 不可连接；`3` HTTP/API/格式错误；`4` 配置/重启失败。

详细字段、端点优先级、开关命令、备份/回滚限制和本机验收见 [`references/api.md`](references/api.md) 与 [`tests/TEST_PLAN.md`](tests/TEST_PLAN.md)。
