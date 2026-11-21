# Listary 7 本地 HTTP API：契约、脚本约定与故障诊断

> 适用范围：以 **Listary 7.1.0.47 Beta** 和原作者的本机观察为基线。HTTP API 功能可在 [Listary V7 官方说明](https://www.listary.com/v7) 中确认；下面的具体字段、错误码、限制与配置键依据原作者检查的**内置 API 文档及本机实测**整理，不保证未来版本完全一致。升级 Listary 后先运行 `-Doctor`。
>
> **Cross-version compatibility: NOT VERIFIED** —— 全部实测来自单机单版本（Windows 11 / Listary 7.1.0.47 / 端口 41234）。查询语法文档的唯一源是本仓库的 [`search-syntax.md`](search-syntax.md)；从归档包安装的副本可能与仓库版本不同，以仓库为准。升级 Listary 后可用 `tests/syntax-regression.ps1 -ReferenceSyntaxPath <仓库内 search-syntax.md>` 校验副本是否一致。

## 一、HTTP 接口（只读搜索）

```http
POST http://127.0.0.1:<port>/api/v1/search
Content-Type: application/json; charset=utf-8
```

原作者在该版本观察到：仅监听 IPv4 loopback，`Host` 需为 `localhost`/`127.0.0.1`（端口须匹配）；没有 API key；不支持 CORS 预检、chunked 请求和 keep-alive。不要将这些行为当作所有版本的永久保证。

请求 JSON：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `query` | string | 是 | 非空；按名称和路径匹配，可用 `*.ps1` 等 glob，也支持 `ext:`/`date:`/`size:`/路径/排除等高级语法（见 [`search-syntax.md`](search-syntax.md)） |
| `limit` | integer | 否 | 1–100；服务端原生默认值 10，**脚本默认 20** |
| `offset` | integer | 否 | 从 0 开始的分页偏移 |
| `search_in` | string[] | 否 | 限定绝对目录；不是内容检索 |
| `types` | string[] | 否 | `file`、`folder` |
| `extensions` | string[] | 否 | 如 `md`、`pdf`；脚本接受 `.md` 并规范化 |

示例响应（**结构示例，不代表实测结果**）：

```json
{
  "ok": true,
  "data": {
    "query": "invoice",
    "total": 42,
    "offset": 0,
    "limit": 10,
    "count": 1,
    "results": [
      {
        "path": "D:\\Work\\invoice.pdf",
        "name": "invoice.pdf",
        "type": "file",
        "size_bytes": 120034,
        "modified_at": "2026-06-18T10:20:00+08:00",
        "score": 9821
      }
    ]
  },
  "error": null,
  "message": null,
  "ts": 1780000000000
}
```

`total` 是命中总数，`count` 是本页条数；`score` 是内部排序权重，**不是可解释的相似度百分比**，不同查询的分数不可比较。索引可能过期：找到路径后仍需核实文件存在、文件版本正确。

原作者记录的错误：

| HTTP | `error` | 含义 |
|---|---|---|
| 400 | `REQUEST_VALIDATION_FAILED` | 请求/JSON/参数不符合契约 |
| 403 | `FORBIDDEN` | Host 校验失败 |
| 404 | `RESOURCE_NOT_FOUND` | 接口路径不存在 |
| 405 | `METHOD_NOT_ALLOWED` | 方法不支持（如 GET） |
| 413 | `REQUEST_TOO_LARGE` | 请求体过大 |
| 415 | `UNSUPPORTED_MEDIA_TYPE` | 非 JSON Content-Type |
| 429 | `TOO_MANY_REQUESTS` | 并发上限 |
| 500 | `INTERNAL_ERROR` | 服务端内部错误 |
| 503 | `SEARCH_UNAVAILABLE` | 搜索引擎不可用或停止中 |

原作者观察到的上限：请求头 16 KiB、请求体 256 KiB、并发请求最多 8 个；单页最多 100 项。没有文件内容检索、正则搜索，也没有服务器端排序或聚合。

**但查询字符串本身支持高级过滤器**（2026-11-21 在 Listary 7.1.0.47 / Windows 11 上实测）：`ext:`（含 `;`/`,` 多值 OR）、`date:`（相对/年月日/区间/比较符）、`size:`（`kb/mb/gb/tb`，无单位按 MB）、路径片段与盘符（`windows\ note`、`A:\ photo`）、`-` 排除、`"连续短语"`、内置类型过滤（`folder:`/`file:`/`doc:`/`pic:`/`video:`/`audio:`）、以及**中文拼音与首字母匹配**（`shiyong` 可命中 `使用说明.md`）。这些是**服务端过滤**，比拿回结果再本地筛更省请求。完整语法、组合规则、不支持项与实测记录见 [`search-syntax.md`](search-syntax.md)。

注意两个坑：`date:`/`size:` 的**值**写错时条件会被静默忽略（返回结果等于没加该条件，不报错）；`ext:` 写成不存在的扩展名（如 `ext:word`）则合法地返回 0 条。两者都要抽样核对结果，不能因为 HTTP 200 就宣称筛选成功。

## 二、封装脚本 `scripts/listary.ps1`

### 功能与输出

```powershell
pwsh -NoProfile -File $S -Query '备份' -Types folder -Limit 10 -Format compact
pwsh -NoProfile -File $S -Query '*.md' -SearchIn 'D:\Projects' -Format paths
pwsh -NoProfile -File $S -Query 'config' -Format json
pwsh -NoProfile -File $S -Doctor
```

| 模式 | 用途与格式 |
|---|---|
| `table` | 默认；人工查看，逐行输出类型、字节大小和**完整路径**（不依赖 PowerShell 的表格截断） |
| `compact` | Agent 推荐；首行 `total=<N> returned=<N> offset=<N> next_offset=<N 或 ->`，后续每行完整路径 |
| `paths` | **只有路径**，方便管道；无标题、无总数、无分页标记 |
| `json` | 成功时直接输出服务端原始 JSON；可能很长，按需使用 |

`-Query` 必填（诊断/变更模式除外），`-Limit` 默认 20。`-SearchIn` 要求绝对路径，目录可以暂时未挂载（脚本不会隐式创建目录）。`-Extensions` 可为 `md`/`.pdf`，不要传 `*.md`（glob 应写在 `-Query` 中）。

**端点解析优先级（仅用于搜索和 `-Doctor`）：**

1. 命令行 `-Endpoint`。
2. 环境变量 `LISTARY_HTTP_ENDPOINT`。
3. 命令行 `-Port`。
4. 环境变量 `LISTARY_HTTP_PORT`。
5. `%APPDATA%\Listary\UserProfile\Settings\Preferences.json` 中的 `Settings."General.HttpApi.Port"`。
6. 封装脚本兜底端口 `41234`（是本工具的兜底策略，**不是 Listary 永久保证的默认端口**）。

为了防止 Agent 意外向外部服务发送本机搜索词，`-Endpoint` 和对应环境变量**只接受** `http://127.0.0.1:<port>/api/v1/search` 或 `localhost` 等价写法。脚本统一向 IPv4 `127.0.0.1` 发送请求，并关闭代理。检查环境变量是否覆盖了设定端口，不能只看配置文件。

退出码：`0` 成功（包括总数 0）；`1` 参数错误；`2` TCP/HTTP 请求无法连接；`3` HTTP 错误、API 报错或异常 JSON；`4` 本机配置、备份或重启失败。使用 `pwsh -NoProfile -File` **子进程调用**，避免 PowerShell `exit N` 结束上层交互会话。

### 不同格式的 Token 成本

`compact` 只打印摘要和路径，通常比大量格式化列更简洁；`paths` 更短，但不能判断是否还有后续页。**搜索加速不等于相同比例的 Token 节省**：减少重复猜路径、工具调用、无关结果，才是真正可能省 Token 的部分。建议实际记录端到端用时、调用次数、输入与输出 token，而不是单看 API 毫秒数。

## 三、诊断与开关（可能有副作用）

`-Doctor` 只读：输出 Listary.exe 路径、运行进程、设置路径、配置开关和端口、实际使用的 endpoint、端口可达性，并发起一个 `limit=1` 的 HTTP 搜索探针。**仅端口处于 LISTEN 状态不算 API 健康**：必须收到符合 Listary 契约的成功响应。

在**用户明确允许修改设置和重启 Listary**后，才调用：

```powershell
pwsh -NoProfile -File $S -Enable  -Apply -Port 41234
pwsh -NoProfile -File $S -Disable -Apply
```

`-Apply` 是优化版新增的**强制安全开关**：单独 `-Enable`/`-Disable` 不做任何更改、退出 1。`-Disable` 不支持 `-Port`，始终依据保存的端口判断，避免误以为错误端口关闭就是成功。

开关流程：先检查是否已处于期望状态以避免无意义重启；否则停止 Listary 主程序（优先尝试正常退出、必要时强制结束）、读取现存配置、保存带时间戳和随机后缀的备份、同目录临时文件写入并替换配置、重新拉起 `Listary.exe --startup`、轮询验证状态。修改失败后**尝试**用备份恢复并重新启动；自动回滚也可能失败，需要查看报错，不能把它当作绝对保证。不会修改索引服务，也不会改 ACL。

Listary 配置：`%APPDATA%\Listary\UserProfile\Settings\Preferences.json`，`Settings` 对象内的扁平键：

| 键 | 作用 |
|---|---|
| `General.HttpApi.Enabled` | `true` / `false`；缺省视作未开启 |
| `General.HttpApi.Port` | API 端口；开启时如有必要写入用户指定端口，关闭时保留原设置 |

注意：PowerShell 重新序列化 JSON 可能改变**格式、空白和属性排版**，所以备份文件始终保留原始字节。脚本不会在配置缺失或解析失败时创建空白配置。Listary 尚未提供一个在此脚本中验证过的无重启热加载方式。

**隐私与系统安全：** 此 HTTP API 没有身份鉴别。只绑定 loopback 可降低来自局域网的直接访问，却不能隔离本机其他程序。除非用户主动接受这个权衡，否则不应开启。更换端口不是鉴权。此工具永远不需要为了搜索而提升工作区权限、修改 ACL、重新取得文件所有权。

## 四、实测快照与局限

原作者于 2026-11-20 在特定 Windows 主机、特定索引规模上记录：首次约 110–113 ms、后续约 4–36 ms；A: 143 万、C: 140 万、G: 95 万、B: 59 万，合计约 438 万条目；自写目录枚举约 27,000 文件/秒，四盘全扫约 3 分钟。**这是“查询已有索引”与“临时遍历文件”的比较，不是与其他已建索引工具的公平横评。** 以上数字不是速度 SLA，也不是 Token 节省率。

Listary 只能返回已纳入索引的内容；网络路径、离线磁盘、索引排除目录、刚发生的文件变更，都可能让搜索为空或命中陈旧路径。零命中时不要宣称文件一定不存在。

## 五、本机验收清单

优先运行 `tests/TEST_PLAN.md` 中的**只读检查**。在没有明确授权的情况下，不要进行开关测试。只读检查至少覆盖：中文、空结果、分页、路径过滤、`-Format paths` 无标题、`compact` 下一页标记、无效参数、API 关闭后的 `-Doctor` 和非 Listary 服务占用端口的情况。

**语法回归**用 `tests/syntax-regression.ps1` 自动执行（只读，不依赖人工判读）：它会把 `date:`/`size:`/`ext:` 的命中结果逐条与真实文件元信息核对，验证中文/拼音检索、分页无重复、中文路径完整性，并检查“无效条件被静默忽略”的行为是否仍与文档一致。API 不可达时退出 2 并跳过，不会误报失败。

```powershell
pwsh -NoProfile -File "$env:USERPROFILE\.dsh\skills\listary-file-search\tests\syntax-regression.ps1"
```
