# set-opencode-models

自动为 OpenCode 的 **plan**（规划）和 **build**（实现）两个内置 agent 选择最省钱的模型，并写入全局配置。

> 本仓库把该脚本的全部文件集中在 `opencode-models/` 文件夹内，根目录只保留这份说明。

## 目录结构

```
ps1Files/
├── README.md                  # 本说明
└── opencode-models/           # 脚本及相关文件
    ├── set-opencode-models.ps1
    ├── run.cmd
    ├── .gitignore
    ├── aa-models-cache.json
    └── model-availability-cache.json
```

- **先剔除不可用，再选**：模型目录里的 `enabled/active` 不代表真能调用（存在地区受限、已废弃等"列表有、实际用不了"的情况），脚本会先发一个最小请求逐个探测，剔除不可用的，再在剩下的里面选。
- **Build（实现）**：在付费模型里选**最便宜**的可用模型（默认排除 0 元 Free 模型）。
- **Plan（规划）**：接入 [Artificial Analysis](https://artificialanalysis.ai) 的 **Intelligence Index**，选**智能分最高**的可用模型。
- **模型价格**每次运行实时查询（来自 OpenCode 自身的模型目录，**不缓存**）；**智能分**（AA）与**可用性探测**结果按天缓存复用，跑一次拿到的是当时的最新数据。
- 写入三项：顶层 `model`（新会话默认模型，取最省钱的 Build 模型）、`agents.plan.model`、`agents.build.model`，其余配置原样保留。
- **只影响新会话**：已有会话的模型被 opencode 桌面应用的输入框快照与历史模型锁定，无法批量修改；如需让某个老会话用新模型，在该会话内用 `/models` 手动选一次即可。

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

以下命令在**仓库根目录**执行（也可先 `cd opencode-models`，再用 `.\set-opencode-models.ps1`）：

```powershell
# 预览选择结果（含探测剔除过程），不写配置
.\opencode-models\set-opencode-models.ps1 -DryRun

# 正式选择：写配置（影响新会话）
.\opencode-models\set-opencode-models.ps1

# 打印候选模型的价格 / 智能分全表（不做可用性探测，速度快）
.\opencode-models\set-opencode-models.ps1 -ListAll

# 强制重新拉 AA 数据 / 重新探测可用性（默认当天内走缓存）
.\opencode-models\set-opencode-models.ps1 -RefreshAA -RefreshAvail
```

> 双击运行请用 **`opencode-models\run.cmd`**：它会调用同目录脚本并在结束后停留窗口，方便查看最终选择了哪些模型。脚本本身默认也会在"按回车键退出"处等待；命令行/自动化场景可加 `-NoPause` 跳过。

### 参数

| 参数 | 说明 |
| --- | --- |
| `-ListAll` | 打印候选模型价格（+智能分）全表，不写配置、不探测可用性 |
| `-DryRun` | 只显示将选哪个、将写什么，不落盘（会做可用性探测） |
| `-IncludeFree` | Build 允许选择 0 元 Free 模型（默认排除 Free） |
| `-RefreshAA` | 忽略 AA 数据缓存，强制重新拉取 |
| `-RefreshAvail` | 忽略可用性缓存，强制重新探测候选模型 |
| `-NoPause` | 结束后不等待回车直接退出（供命令行/自动化用） |
| `-CliPath <路径>` | 手动指定 opencode CLI 完整路径 |
| `-AAKey <key>` | 直接传 AA key（优先于环境变量） |

## 写入位置

写入 **全局配置目录**下的 `opencode.json`（目录通过 `opencode debug paths config` 自动定位，本机为 `F:\OpenCode\config\opencode`）。若同目录存在 `opencode.jsonc`，会一并同步更新，保证两者一致。

改动即时生效，无需重启；若未生效，在 OpenCode 里执行 `/reload`。

## 选择规则细节

- **价格来源与口径**：通过 `opencode api get /api/model` 实时读取 OpenCode 自身的模型目录（底层来自 [models.dev](https://models.dev)，**每次运行实时查、不缓存**），取每个模型的 `cost[0]`（基础档），综合价 = `input + output`（单位 USD / 百万 token）。AA 接口返回的数据虽也含价格，但选最便宜时**只用 opencode 自己的标价**（即你在 opencode-go 里实际的计费标准）。
- **可用性探测（三态）**：选模型前用 `opencode run --model <ref> --archived "Reply with OK"` 探测（`--archived` 让探测会话不进列表），结果分五种：
  - `ok` 可用；
  - `region` 地区受限 / `deprecated` 已废弃 → **剔除**；
  - `limit` 额度用完（周/日/月限额、配额、限流）→ **立即停止探测**；
  - `unknown` 网络等临时失败 → 不剔除，作为兜底候选。
- **Build**：排除 Free（`input=0 且 output=0`）后，按综合价升序，取**第一个 `ok`**；没有 `ok` 但有 `unknown` 时，用最便宜的 `unknown` 兜底。
- **Plan**：把模型名归一化（小写、去 `.`/`-`/空格）后匹配 AA 的 `slug`，按 `artificial_analysis_intelligence_index` 降序取**第一个 `ok`**；无 `ok` 时用 `unknown` 兜底，再无则沿用 Build。
- **额度用完（周/日/月限额）**：探测一旦遇到 `limit`，**立即停止**（额度是账户全局的，一个模型限额即全部限额），**不重新选型、不改配置**，只提示"额度已用完，恢复后重跑"，避免把"额度问题"误判成"模型不可用"。
- **默认模型（顶层 `model`）**：等于 Build 选出的最省钱可用模型，决定新会话默认用哪个。
- **免费模型**（`opencode/*` 等）在 AA 中通常无记录，因此不会参与 Plan 的"最强"竞争，符合预期。

## 缓存

两个缓存文件都存放在**脚本目录**（`opencode-models\`），均为**单文件、带日期、跨天自动覆盖**，**不会堆积、无需手动删除**：

| 文件 | 内容 |
| --- | --- |
| `aa-models-cache.json` | AA 智能分数据（Plan 选最强用，**不含价格**） |
| `model-availability-cache.json` | 各模型实际可用性的探测结果 |

- 同一天内重复运行：直接命中缓存，不重复调接口、不重复探测。
- 跨天自动失效并覆盖旧文件；文件损坏时自动重新拉取。
- **AA 接口连不上**：若已有历史缓存（哪怕过期），会**改用过期缓存**（智能分变动不大）；连过期缓存都没有才回退 Plan。
- 想当天强制刷新：加 `-RefreshAA` / `-RefreshAvail`。
- 可用性探测每次发一个极小的模型请求，消耗极少 token；只有未命中缓存的候选才需要探测。

## 注意事项

- 脚本用 UTF-8（带 BOM）保存，Windows PowerShell 5.1 下中文输出正常。
- API key 只从环境变量或命令行读取，**不写入脚本、不进入仓库**。
- 两个缓存文件与数据库备份已在 `opencode-models\.gitignore` 中忽略，不会被误提交。
- 若配置文件为 JSONC（含注释），脚本解析失败时会重建该文件（仅保留 `$schema`、`model` 与 `agents`），请留意。
