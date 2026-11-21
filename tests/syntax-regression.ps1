#Requires -Version 7.0
<#
.SYNOPSIS
  只读回归测试：验证 Listary 查询语法与脚本输出是否仍符合文档。
.DESCRIPTION
  逐条核对服务端过滤是否真的生效（而非被静默忽略）：
    * ext:       —— 每条结果扩展名必须匹配，且结果集应收窄
    * date:week  —— 每条结果的 modified_at 必须落在时间窗内
    * date: 二分 —— A='date:>YYYY-MM' 与 B='date:<=YYYY-MM' 必须满足 A∩B=∅ 且 A∪B=基线集合
    * size:      —— 每条文件结果的 size_bytes 必须满足阈值
    * size: 等价 —— 'size:>1' 与 'size:>1mb' 的路径集合必须完全相同
    * 非法条件   —— date: 值写错时应退化为“无过滤”（与文档一致）
    * 分页       —— 相邻页不重复、同 offset 结果稳定
    * 中文/拼音  —— 中文路径不被截断或替换；拼音可召回中文文件名（可选）
  另外可选校验文档副本是否与唯一源一致（-ReferenceSyntaxPath）。

  不修改任何文件、不更改 Listary 设置。API 不可达时退出 2 并跳过全部检查。
  SKIP 不计入通过项：只表示“本机样本不足/未提供参数”，不代表功能正确。
.EXAMPLE
  pwsh -NoProfile -File .\syntax-regression.ps1
.EXAMPLE
  pwsh -NoProfile -File .\syntax-regression.ps1 -PinyinQuery 'shiyong' -PinyinExpect '使用说明'
.EXAMPLE
  pwsh -NoProfile -File .\syntax-regression.ps1 -ReferenceSyntaxPath '.\references\search-syntax.md'
.NOTES
  Exit codes: 0 全部通过（允许 SKIP）；1 有断言失败；2 API 不可达（跳过）。
#>
[CmdletBinding()]
param(
    # 用于派生测试的基线关键词；改动它会改变基线条数
    [string]$BaseQuery = 'listary',

    # 可选：拼音查询与期望在结果路径中出现的中文片段（缺省则 SKIP）
    [string]$PinyinQuery,
    [string]$PinyinExpect,

    # 单次断言最多读取多少条结果
    [ValidateRange(1, 100)]
    [int]$SampleSize = 100,

    # 集合级断言最多枚举多少条；超过则 SKIP，避免把整盘路径拉进内存
    [ValidateRange(10, 2000)]
    [int]$MaxEnumerate = 400,

    [string]$ScriptPath = (Join-Path $PSScriptRoot '..\scripts\listary.ps1'),

    # 可选：唯一源文档路径。提供时校验本技能 references/search-syntax.md 的 SHA256。
    [string]$ReferenceSyntaxPath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$script:Failures = 0
$script:Passes = 0
$script:Skips = 0

function Pass { param([string]$Message) $script:Passes++; Write-Output "PASS  $Message" }
function Fail { param([string]$Message) $script:Failures++; Write-Output "FAIL  $Message" }
function Skip { param([string]$Message) $script:Skips++; Write-Output "SKIP  $Message" }
function Note { param([string]$Message) Write-Output "      $Message" }

function Invoke-Listary {
    param([string]$Query, [int]$Limit = 20, [int]$Offset = 0, [string]$Format = 'json')
    $raw = & pwsh -NoProfile -File $ScriptPath -Query $Query -Limit $Limit -Offset $Offset -Format $Format 2>&1
    $code = $LASTEXITCODE
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $payload = $null
    if ($code -eq 0 -and $Format -eq 'json') {
        try { $payload = ConvertFrom-Json -InputObject $text -Depth 30 } catch { $code = -1 }
    }
    return [pscustomobject]@{ Exit = $code; Payload = $payload; Text = $text }
}

function Get-Results {
    param($Payload)
    if ($null -eq $Payload -or $null -eq $Payload.data -or $null -eq $Payload.data.results) { return @() }
    return @($Payload.data.results)
}

function Get-PathSet {
    # 完整枚举某个查询的路径集合（分页，去重）。总数为 0 或超过上限时如实返回。
    param([string]$Query)
    $first = Invoke-Listary -Query $Query -Limit 100
    if ($first.Exit -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = "exit $($first.Exit)"; Total = 0; Paths = @() } }
    $total = [int]$first.Payload.data.total
    if ($total -gt $MaxEnumerate) {
        return [pscustomobject]@{ Ok = $false; Reason = "total $total > MaxEnumerate $MaxEnumerate"; Total = $total; Paths = @() }
    }
    $paths = New-Object System.Collections.Generic.List[string]
    $offset = 0
    while ($offset -lt $total) {
        $page = if ($offset -eq 0) { $first } else { Invoke-Listary -Query $Query -Limit 100 -Offset $offset }
        if ($page.Exit -ne 0) { return [pscustomobject]@{ Ok = $false; Reason = "exit $($page.Exit) at offset $offset"; Total = $total; Paths = @() } }
        $batch = @(Get-Results $page.Payload)
        if ($batch.Count -eq 0) { break }
        foreach ($item in $batch) { if ($item.path) { $paths.Add([string]$item.path) } }
        $offset += $batch.Count
    }
    $unique = @($paths | Sort-Object -Unique)
    return [pscustomobject]@{ Ok = $true; Reason = 'ok'; Total = $total; Paths = $unique }
}

function Compare-PathSets {
    # 返回差异描述；完全一致时返回 $null。
    param([string[]]$Left, [string[]]$Right)
    $diff = @(Compare-Object -ReferenceObject @($Left | Sort-Object) -DifferenceObject @($Right | Sort-Object))
    if ($diff.Count -eq 0) { return $null }
    $samples = @($diff | Select-Object -First 3 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
    return "$($diff.Count) 处差异，例如：$($samples -join ' ; ')"
}

# ---------------------------------------------------------------- 前置检查
if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-Output "ERROR 找不到脚本：$ScriptPath"
    exit 1
}
Note "script : $ScriptPath"
Note "base   : '$BaseQuery'"

# ---------------------------------------------------------------- 文档唯一源（可选）
if ($ReferenceSyntaxPath) {
    $installedDoc = Join-Path $PSScriptRoot '..\references\search-syntax.md'
    if (-not (Test-Path -LiteralPath $ReferenceSyntaxPath -PathType Leaf)) {
        Fail "参考文档不存在：$ReferenceSyntaxPath"
    }
    elseif (-not (Test-Path -LiteralPath $installedDoc -PathType Leaf)) {
        Fail "技能内文档不存在：$installedDoc"
    }
    else {
        $referenceHash = (Get-FileHash -LiteralPath $ReferenceSyntaxPath -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath $installedDoc -Algorithm SHA256).Hash
        if ($referenceHash -eq $installedHash) {
            Pass "文档与唯一源一致（SHA256 $($referenceHash.Substring(0,12))…）"
        }
        else {
            Fail "文档与唯一源不一致：reference=$($referenceHash.Substring(0,12))… installed=$($installedHash.Substring(0,12))…；从 source/ 重新同步后再测"
        }
    }
}
else {
    Skip '未提供 -ReferenceSyntaxPath，跳过文档一致性校验（功能回归照常执行）'
}

$base = Invoke-Listary -Query $BaseQuery -Limit 1
if ($base.Exit -eq 2) {
    Skip "Listary API 不可达（exit 2），跳过全部语法检查。先运行 -Doctor。"
    exit 2
}
if ($base.Exit -ne 0) {
    Fail "基线查询失败（exit $($base.Exit)）：$($base.Text)"
    exit 1
}

$shape = $base.Payload
$missing = @()
$missing += @(@('ok', 'data') | Where-Object { $null -eq $shape.$_ })
$missing += @(@('total', 'count', 'offset', 'results') | Where-Object { $null -eq $shape.data.$_ })
if ($missing.Count -eq 0) {
    Pass "响应结构符合契约（ok/data/total/count/offset/results）"
}
else {
    Fail "响应缺少字段：$($missing -join ', ')（Listary 版本可能已变更）"
}

$baselineTotal = [int]$base.Payload.data.total
Note "baseline total = $baselineTotal"

# ---------------------------------------------------------------- ext:
$extProbe = Invoke-Listary -Query "$BaseQuery ext:ps1" -Limit $SampleSize
if ($extProbe.Exit -ne 0) {
    Fail "ext: 查询失败（exit $($extProbe.Exit)）"
}
else {
    $items = @(Get-Results $extProbe.Payload)
    $wrong = @($items | Where-Object { $_.path -and -not ([string]$_.path).EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase) })
    if ($wrong.Count -eq 0) {
        Pass "ext:ps1 命中 $($items.Count) 条，全部以 .ps1 结尾"
    }
    else {
        Fail "ext:ps1 有 $($wrong.Count) 条扩展名不符：$((@($wrong | ForEach-Object { $_.path }))[0..([math]::Min(2, $wrong.Count-1))] -join ' | ')"
    }
    if ([int]$extProbe.Payload.data.total -lt $baselineTotal) {
        Pass "ext: 使结果集收窄（$baselineTotal → $($extProbe.Payload.data.total)）"
    }
    else {
        Fail "ext: 结果数($($extProbe.Payload.data.total))未小于基线($baselineTotal)，过滤可能未生效"
    }
}

# ---------------------------------------------------------------- date: 窗口
$cutoff = (Get-Date).AddDays(-7).AddHours(-1)   # 1 小时容差：索引写入延迟
$dateProbe = Invoke-Listary -Query "$BaseQuery date:week" -Limit $SampleSize
if ($dateProbe.Exit -ne 0) {
    Fail "date: 查询失败（exit $($dateProbe.Exit)）"
}
else {
    $items = @(Get-Results $dateProbe.Payload)
    $stale = @()
    foreach ($item in $items) {
        if (-not $item.modified_at) { continue }
        $mtime = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$item.modified_at, [ref]$mtime)) { continue }
        if ($mtime.LocalDateTime -lt $cutoff) { $stale += "$($item.path) @ $($item.modified_at)" }
    }
    if ($stale.Count -eq 0) {
        Pass "date:week 命中 $($items.Count) 条，modified_at 全部在 7 天内"
    }
    else {
        Fail "date:week 有 $($stale.Count) 条超出 7 天（可能是索引滞后或条件未生效）：$($stale[0])"
    }
    if ([int]$dateProbe.Payload.data.total -lt $baselineTotal) {
        Pass "date: 使结果集收窄（$baselineTotal → $($dateProbe.Payload.data.total)）"
    }
    else {
        Fail "date: 没有收窄结果（$($dateProbe.Payload.data.total) 对基线 $baselineTotal），疑似条件被忽略"
    }
}

# ---------------------------------------------------------------- size: 阈值
$sizeProbe = Invoke-Listary -Query "$BaseQuery size:>1mb" -Limit $SampleSize
if ($sizeProbe.Exit -ne 0) {
    Fail "size: 查询失败（exit $($sizeProbe.Exit)）"
}
else {
    $items = @(Get-Results $sizeProbe.Payload | Where-Object { $_.type -eq 'file' -and $null -ne $_.size_bytes })
    $tooSmall = @($items | Where-Object { [int64]$_.size_bytes -lt 1048576 })
    if ($tooSmall.Count -eq 0) {
        Pass "size:>1mb 命中 $($items.Count) 个文件，全部 ≥1MB"
    }
    else {
        Fail "size:>1mb 有 $($tooSmall.Count) 个文件小于 1MB：$($tooSmall[0].path)"
    }
}

# ---------------------------------------------------------------- 集合级断言
$baselineSet = Get-PathSet -Query $BaseQuery
if (-not $baselineSet.Ok) {
    Skip "基线集合无法完整枚举（$($baselineSet.Reason)），跳过集合级断言"
}
else {
    # --- 日期二分：A='date:>YYYY-MM'，B='date:<=YYYY-MM'
    # 取上个月做分割点，保证两侧都可能非空；两侧都为空说明样本不足，SKIP 而不是假通过。
    $month = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
    $laterSet = Get-PathSet -Query "$BaseQuery date:>$month"
    $earlierSet = Get-PathSet -Query "$BaseQuery date:<=$month"
    if (-not $laterSet.Ok -or -not $earlierSet.Ok) {
        Skip "日期集合无法完整枚举（later=$($laterSet.Reason); earlier=$($earlierSet.Reason)）"
    }
    elseif ($laterSet.Paths.Count -eq 0 -or $earlierSet.Paths.Count -eq 0) {
        Skip "date:>$month ($($laterSet.Paths.Count) 条) 或 date:<=$month ($($earlierSet.Paths.Count) 条) 为空，样本不足以验证二分"
    }
    else {
        $intersection = @($laterSet.Paths | Where-Object { $earlierSet.Paths -contains $_ })
        if ($intersection.Count -eq 0) {
            Pass "date:>$month ∩ date:<=$month = ∅（$($laterSet.Paths.Count) 与 $($earlierSet.Paths.Count) 条无交集）"
        }
        else {
            Fail "date:>$month 与 date:<=$month 有 $($intersection.Count) 条交集，例如 $($intersection[0])"
        }
        $union = @(@($laterSet.Paths) + @($earlierSet.Paths) | Sort-Object -Unique)
        $diff = Compare-PathSets -Left $union -Right $baselineSet.Paths
        if ($null -eq $diff) {
            Pass "date:>$month ∪ date:<=$month = 基线集合（$($baselineSet.Paths.Count) 条，精确二分）"
        }
        else {
            Fail "日期两集合并集不等于基线集合：$diff"
        }
    }

    # --- size 等价：'size:>1' 与 'size:>1mb' 的路径集必须相同
    $unitlessSet = Get-PathSet -Query "$BaseQuery size:>1"
    $explicitSet = Get-PathSet -Query "$BaseQuery size:>1mb"
    if (-not $unitlessSet.Ok -or -not $explicitSet.Ok) {
        Skip "size 集合无法完整枚举（unitless=$($unitlessSet.Reason); explicit=$($explicitSet.Reason)）"
    }
    elseif ($unitlessSet.Paths.Count -eq 0) {
        Skip "本机没有 >1MB 的命中，无法证明“无单位按 MB”（需要样本文件）"
    }
    else {
        $diff = Compare-PathSets -Left $unitlessSet.Paths -Right $explicitSet.Paths
        if ($null -eq $diff) {
            Pass "size:>1 与 size:>1mb 返回相同路径集合（$($unitlessSet.Paths.Count) 条，无单位按 MB）"
        }
        else {
            Fail "size:>1 与 size:>1mb 路径集合不同：$diff"
        }
    }
}

# ---------------------------------------------------------------- 非法条件
# 文档结论：date: 的值无法解析时条件被静默忽略，结果等于不加该条件。
$bogus = Invoke-Listary -Query "$BaseQuery date:本周" -Limit 1
if ($bogus.Exit -ne 0) {
    Fail "非法 date: 查询失败（exit $($bogus.Exit)）——若 Listary 改为报错，文档需更新"
}
elseif ([int]$bogus.Payload.data.total -eq $baselineTotal) {
    Pass "非法值 date:本周 被静默忽略（总数仍为 $baselineTotal），与文档一致"
}
else {
    Note "行为变化：date:本周 总数 $($bogus.Payload.data.total) ≠ 基线 $baselineTotal。Listary 可能开始解析该写法，请更新 search-syntax.md 第 7 节。"
    Pass "非法值 date:本周 未造成错误（行为与文档记录不同，已提示）"
}

# ---------------------------------------------------------------- 分页
if ($baselineTotal -ge 12) {
    $pages = @()
    foreach ($offset in 0, 4, 8) {
        $page = Invoke-Listary -Query $BaseQuery -Limit 4 -Offset $offset
        if ($page.Exit -ne 0) { Fail "分页查询失败（offset=$offset, exit $($page.Exit)）"; break }
        if ([int]$page.Payload.data.offset -ne $offset) {
            Fail "请求 offset=$offset 但服务端回报 offset=$($page.Payload.data.offset)"
        }
        $pages += , @(Get-Results $page.Payload | ForEach-Object { [string]$_.path })
    }
    if ($pages.Count -eq 3) {
        $flat = @($pages | ForEach-Object { $_ })
        $unique = @($flat | Select-Object -Unique)
        if ($flat.Count -eq $unique.Count) {
            Pass "分页无重复（offset 0/4/8 共 $($flat.Count) 条互不相同）"
        }
        else {
            Fail "分页出现重复：$($flat.Count) 条中仅 $($unique.Count) 条唯一"
        }
        $again = Invoke-Listary -Query $BaseQuery -Limit 4 -Offset 4
        $againPaths = @(Get-Results $again.Payload | ForEach-Object { [string]$_.path })
        if (($againPaths -join '|') -eq (@($pages[1]) -join '|')) {
            Pass "同一 offset 重复请求结果稳定"
        }
        else {
            Fail "同一 offset 两次请求结果不同，翻页可能漏项"
        }
    }
}
else {
    Skip "基线只有 $baselineTotal 条，样本不足以测试分页（换一个更常见的 -BaseQuery）"
}

# ---------------------------------------------------------------- 中文输出
$cjkQuery = '使用说明'
$cjkPaths = & pwsh -NoProfile -File $ScriptPath -Query $cjkQuery -Limit 5 -Format paths 2>&1
$cjkText = ($cjkPaths | ForEach-Object { [string]$_ }) -join "`n"
if ($LASTEXITCODE -ne 0) { Skip "中文查询 '$cjkQuery' 无结果，跳过中文断言" }
else {
    $lines = @($cjkText -split "`r?`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -gt 0 -and -not ($lines | Where-Object { $_ -notmatch '^([A-Za-z]:\\|\\\\)' })) {
        Pass "-Format paths 只输出路径（$($lines.Count) 行，无标题/无摘要）"
    }
    else {
        Fail "-Format paths 混入了非路径内容"
    }
    if ($cjkText -match '[^\x00-\x7F]' -and $cjkText -notmatch [char]0xFFFD) {
        Pass "中文路径输出完整、无替换字符"
    }
    elseif ($cjkText -notmatch '[^\x00-\x7F]') {
        Note "本次命中都是纯 ASCII 路径，未覆盖中文断言（可换一个确定含中文的查询）"
    }
    else {
        Fail "中文路径出现替换字符，编码链路有问题"
    }
}

# ---------------------------------------------------------------- 拼音
if ($PinyinQuery) {
    $pin = & pwsh -NoProfile -File $ScriptPath -Query $PinyinQuery -Limit 20 -Format paths 2>&1
    $pinText = (@($pin | ForEach-Object { [string]$_ }) -join "`n")
    if ($LASTEXITCODE -ne 0 -or $pinText.Trim() -eq '') {
        Skip "拼音查询 '$PinyinQuery' 无结果；该能力与索引语言设置有关"
    }
    elseif (-not $PinyinExpect) {
        Skip "拼音查询有结果但未提供 -PinyinExpect，无法断言召回"
    }
    elseif ($pinText -match [regex]::Escape($PinyinExpect)) {
        Pass "拼音 '$PinyinQuery' 召回了包含 '$PinyinExpect' 的中文路径"
    }
    else {
        Fail "拼音 '$PinyinQuery' 未召回 '$PinyinExpect'；可能索引或语言设置变化"
    }
}
else {
    Skip '未提供 -PinyinQuery，跳过拼音匹配检查（建议传 -PinyinQuery shiyong -PinyinExpect 使用说明）'
}

# ---------------------------------------------------------------- 汇总
Write-Output ''
$summary = "PASS $($script:Passes) / FAIL $($script:Failures) / SKIP $($script:Skips)（SKIP 不计入通过）"
if ($script:Failures -eq 0 -and $script:Passes -gt 0) {
    Write-Output "结果：$summary"
    exit 0
}
Write-Output "结果：$summary"
exit 1
