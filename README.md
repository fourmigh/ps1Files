# set-opencode-models

自动为 OpenCode 的 **plan**（规划）和 **build**（实现）两个内置 agent 选择最省钱的模型，并写入全局配置。

- **Build（实现）**：在付费模型里选**最便宜**的（默认排除 0 元 Free 模型）。
- **Plan（规划）**：接入 [Artificial Analysis](https://artificialanalysis.ai) 的 **Intelligence Index**，选**智能分最高**的可用模型。
- 价格全部**运行时实时查询**，不硬编码，跑一次拿到的是当时的最新价格。
- 写入三项：顶层 `model`（新会话默认模型，取最省钱的 Build 模型）、`agents.plan.model`、`agents.build.model`，其余配置原样保留。

## 模型范围

仅取以下两个 provider，忽略 zai / zhipuai 等第三方：

| Provider | 说明 |
| --- | --- |
| `opencode` | OpenCode 官方免费模型 |
| `opencode-go` | OpenCode Go（付费 + 免费） |

## 前置条件

1. **opencode CLI** 可用（脚本会自动探测；找不到时用 `-CliPath` 指定）。
2. **Artificial Analysis API key**（免费）—— 用于 Plan 按智能分选最强。
   - 到 <https://artificialanalysis.ai> 免费注册，在 API key 管理页创建一个 key（Free 层即可，100 次/天，脚本跑一次只用 2~3 次）。
   - 设置为环境变量：
     ```powershell
     # 当前会话
     $env:AA_API_KEY = "你的key"
     # 永久（当前用户）
     [Environment]::SetEnvironmentVariable("AA_API_KEY", "你的key", "User")
     ```

> 不设置 `AA_API_KEY` 也能跑，但 Plan 会回退为"价格最高旗舰"。

## 用法

```powershell
# 预览选择结果，不写配置
.\set-opencode-models.ps1 -DryRun

# 正式选择并写入全局配置
.\set-opencode-models.ps1

# 打印候选模型的价格 / 智能分全表
.\set-opencode-models.ps1 -ListAll
```

### 参数

| 参数 | 说明 |
| --- | --- |
| `-ListAll` | 打印候选模型价格（+智能分）全表，不写配置 |
| `-DryRun` | 只显示将选哪个、将写什么，不落盘 |
| `-IncludeFree` | Build 允许选择 0 元 Free 模型（默认排除 Free） |
| `-CliPath <路径>` | 手动指定 opencode CLI 完整路径 |
| `-AAKey <key>` | 直接传 AA key（优先于环境变量） |

## 写入位置

写入 **全局配置目录**下的 `opencode.json`（目录通过 `opencode debug paths config` 自动定位，本机为 `F:\OpenCode\config\opencode`）。若同目录存在 `opencode.jsonc`，会一并同步更新，保证两者一致。

改动即时生效，无需重启；若未生效，在 OpenCode 里执行 `/reload`。

## 选择规则细节

- **价格口径**：`cost[0]`（基础档），综合价 = `input + output`（单位 USD / 百万 token）。
- **默认模型（顶层 `model`）**：等于 Build 选出的最省钱模型，决定新会话默认用哪个。
- **Build**：排除 Free（`input=0 且 output=0`）后，按综合价升序取最小。
- **Plan**：把模型名归一化（小写、去 `.`/`-`/空格）后匹配 AA 的 `slug`，取 `artificial_analysis_intelligence_index` 最高者；同型号多 provider 时取价格最低的；匹配不到 AA 的模型跳过，全匹配不到则回退价格最高旗舰。
- **免费模型**（`opencode/*` 等）在 AA 中通常无记录，因此不会参与 Plan 的"最强"竞争，符合预期。

## 注意事项

- 脚本用 UTF-8（带 BOM）保存，Windows PowerShell 5.1 下中文输出正常。
- API key 只从环境变量或命令行读取，**不写入脚本、不进入仓库**。
- 若配置文件为 JSONC（含注释），脚本解析失败时会重建该文件（仅保留 `$schema`、`model` 与 `agents`），请留意。
