# Windows 本机验收流程（手动执行；默认不更改系统）

> 自动化版本：`tests/syntax-regression.ps1` 覆盖 `ext:`/`date:`/`size:` 是否真的生效、中文与拼音、分页去重、中文路径完整性，约 10 秒，只读。下面仍保留人工抽查项（分辨率更高、可看原始输出）。

在 PowerShell 7 中打开一个新的窗口，将 `$S` 改成当前 Skill 脚本的**实际绝对路径**：

```powershell
$S = Join-Path $env:USERPROFILE '.dsh\skills\listary-file-search\scripts\listary.ps1'

# 1. 诊断：仅查询，不更改设置
pwsh -NoProfile -File $S -Doctor
$LASTEXITCODE

# 2. 小结果集；确认输出的是完整路径
pwsh -NoProfile -File $S -Query 'Listary' -Limit 5 -Format compact
$LASTEXITCODE

# 3. 原样 JSON（确认 ok/data/total/count/results）
pwsh -NoProfile -File $S -Query 'Listary' -Limit 2 -Format json

# 4. 路径模式仅输出路径，无 header
pwsh -NoProfile -File $S -Query '*.ps1' -Limit 5 -Format paths

# 5. 中文（可改成机器上确定存在的中文文件名）
pwsh -NoProfile -File $S -Query '使用说明' -Limit 5 -Format compact

# 6. 异常输入：非本机 endpoint 应退出 1，不能发送任何请求
pwsh -NoProfile -File $S -Query 'test' -Endpoint 'http://example.com:41234/api/v1/search'
$LASTEXITCODE

# 7. 安全护栏：无 -Apply 时不能更改配置或重启 Listary
pwsh -NoProfile -File $S -Enable
$LASTEXITCODE
```

**预期：** 1 返回 0（API 正常）或 2/3（诊断明确原因）；2–5 在 API 可用时返回 0；6、7 返回 1。`-Format compact` 应展示 `next_offset`，有下一页时继续用它请求；`paths` 不应额外包含标题、摘要或系统日志。`total=0` 是成功搜索，不是 API 错误。

## 需要授权的变更验证（默认不执行）

只有在用户明确同意修改 Listary 设置并接受主程序重启后，才运行：

```powershell
pwsh -NoProfile -File $S -Disable -Apply
pwsh -NoProfile -File $S -Doctor  # 预期 exit 2
pwsh -NoProfile -File $S -Enable -Apply -Port 41234
pwsh -NoProfile -File $S -Doctor  # 预期 exit 0
```

应观察：每次真实修改输出备份路径；Listary 主程序恢复；关闭后端口不监听；开启后必须能收到合法搜索响应；原设置文件其他关键字段仍在。若出现 exit 4，先阅读报错与原始备份，不要不经检查重复运行。

## 推荐增加的回归验证

在真实机器上为一个临时目录创建若干包含中文、`*.ps1`、不同大小、同名异路径的测试文件；在当前索引完成后逐项验证筛选、排序及分页。再新建/移动/删除文件，验证索引时效性。**不要直接对生产数据的 ACL 做试验**。
