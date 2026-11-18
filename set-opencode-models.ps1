<#
.SYNOPSIS
    自动为 OpenCode 的 plan / build 两个内置 agent 选择最省钱的模型，并写入全局配置。

.DESCRIPTION
    本脚本完成三件事：
      1. 通过 opencode CLI 实时查询当前可用的所有模型及其最新价格（不硬编码价格）；
      2. 按规则挑选模型：
           - Build（实现）：在付费模型里选最便宜（默认排除 0 元 Free 模型，可用 -IncludeFree 放开）；
           - Plan （规划）：接入 Artificial Analysis 的 Intelligence Index，选智能分最高的可用模型；
      3. 把结果写入全局配置 opencode.json（更新顶层 model 及 agents.plan.model / agents.build.model，其余字段保留）。

    模型范围：仅取 opencode（免费）与 opencode-go（付费+免费）两个 provider，忽略 zai / zhipuai 等第三方。

.PARAMETER ListAll
    打印候选模型的价格表（以及有 AA key 时的智能分），按综合价排序，不写配置。

.PARAMETER DryRun
    只显示将要选择的模型和将要写入的内容，不真正修改配置文件。

.PARAMETER IncludeFree
    Build 允许选择 0 元 Free 模型（默认排除 Free，选付费里最便宜的）。

.PARAMETER CliPath
    手动指定 opencode CLI 可执行文件的完整路径。缺省时自动探测。

.PARAMETER AAKey
    Artificial Analysis 的 API key。缺省时读取环境变量 AA_API_KEY。

.EXAMPLE
    .\set-opencode-models.ps1 -DryRun
    预览选择结果，不写配置。

.EXAMPLE
    .\set-opencode-models.ps1
    选择并写入全局配置。

.EXAMPLE
    .\set-opencode-models.ps1 -ListAll
    打印候选模型价格/智能分全表。

.NOTES
    - Artificial Analysis 免费 API key 在 https://artificialanalysis.ai 注册获取，
      设置为环境变量 AA_API_KEY 后即可启用 Plan 的"按智能分选最强"。
    - 脚本写入的配置会即时生效，无需重启 OpenCode（若未生效可执行 /reload）。
#>

[CmdletBinding()]
param(
    [switch]$ListAll,
    [switch]$DryRun,
    [switch]$IncludeFree,
    [string]$CliPath,
    [string]$AAKey
)

$ErrorActionPreference = 'Stop'

# 输出编码设为 UTF-8，避免中文乱码
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$OutputEncoding = [System.Text.Encoding]::UTF8

# ===================== 常量配置 =====================
$Script:Providers     = @('opencode', 'opencode-go')     # 仅这两个 provider 参与选择
$Script:AA_BaseUrl    = 'https://artificialanalysis.ai/api/v2/language/models/free'
$Script:ConfigSchema  = 'https://opencode.ai/config.json'

# ===================== 工具函数 =====================

<#
    归一化模型名，用于跨数据源匹配：
    转小写并去掉 . - _ 空格 及括号说明（如 "(Max)"），
    使 "glm-5.3" 与 AA 的 "glm-5-3" 归一到同一个 key "glm53"。
#>
function Get-NormalizedKey {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $k = $Name.ToLowerInvariant()
    $k = $k -replace '\(.*?\)', ''      # 去掉 "(Max)" 之类
    $k = $k -replace '[.\-_ ]', ''      # 去掉分隔符
    return $k.Trim()
}

<# 探测 opencode CLI 可执行文件路径 #>
function Find-OpenCodeCli {
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path $Explicit) { return (Resolve-Path $Explicit).Path }
        throw "指定的 CliPath 不存在: $Explicit"
    }
    # 1) PATH 里的 opencode
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # 2) 常见安装位置
    $known = @(
        "$env:LOCALAPPDATA\Programs\@opencode-aidesktop\resources\opencode-cli.exe",
        "$env:LOCALAPPDATA\Programs\opencode\resources\opencode-cli.exe",
        "$env:USERPROFILE\.opencode\bin\opencode.exe",
        "$env:USERPROFILE\.local\bin\opencode.exe",
        "$env:LOCALAPPDATA\opencode\opencode.exe"
    )
    foreach ($p in $known) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    throw '未找到 opencode CLI。请用 -CliPath 参数指定完整路径。'
}

<# 通过 CLI 获取全局配置目录 #>
function Get-ConfigDir {
    param([string]$Cli)
    $dir = (& $Cli debug paths config 2>$null | Out-String).Trim()
    if (-not $dir) { throw '无法获取 opencode 配置目录 (debug paths config)。' }
    return $dir
}

<# 通过 CLI 获取当前可用模型列表 #>
function Get-OpenCodeModels {
    param([string]$Cli)
    $raw = (& $Cli api get /api/model 2>$null | Out-String)
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'opencode api get /api/model 返回为空。' }
    $j = $raw | ConvertFrom-Json
    if (-not $j -or -not $j.data) { throw 'opencode api 返回结构异常。' }
    return @($j.data)
}

<#
    获取 Artificial Analysis 的模型智能分与价格（免费层，翻页取全量）。
    返回 PSCustomObject 数组：slug / name / index / inputPrice / outputPrice
#>
function Get-AAData {
    param([string]$Key)
    $headers = @{ 'x-api-key' = $Key }
    $all = @()
    $page = 1
    $maxPage = 30   # 保险上限，避免死循环
    do {
        $url = "$Script:AA_BaseUrl`?page=$page"
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 60
        $json = $resp.Content | ConvertFrom-Json
        foreach ($m in @($json.data)) {
            $all += [pscustomobject]@{
                slug       = $m.slug
                name       = $m.name
                index      = $m.evaluations.artificial_analysis_intelligence_index
                inputPrice = $m.pricing.price_1m_input_tokens
                outputPrice = $m.pricing.price_1m_output_tokens
            }
        }
        $hasMore = [bool]$json.pagination.has_more
        $page++
    } while ($hasMore -and $page -le $maxPage)
    return $all
}

<# 写配置：更新顶层 model、agents.plan.model 与 agents.build.model，保留其余字段 #>
function Write-Config {
    param(
        [string]$ConfigDir,
        [string]$PlanRef,
        [string]$BuildRef,
        [string]$DefaultModel
    )
    $targets = @()
    foreach ($name in @('opencode.json', 'opencode.jsonc')) {
        $p = Join-Path $ConfigDir $name
        if (Test-Path $p) { $targets += $p }
    }
    if ($targets.Count -eq 0) { $targets += (Join-Path $ConfigDir 'opencode.json') }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($target in $targets) {
        $config = [ordered]@{}
        if (Test-Path $target) {
            $raw = Get-Content $target -Raw -Encoding UTF8
            if ($raw -and $raw.Trim().Length -gt 0) {
                try {
                    $existing = $raw | ConvertFrom-Json
                    foreach ($p in $existing.PSObject.Properties) { $config[$p.Name] = $p.Value }
                } catch {
                    Write-Warning "无法解析 $target（可能含 JSONC 注释），将重建该文件。"
                }
            }
        }
        if (-not $config.Contains('$schema')) { $config['$schema'] = $Script:ConfigSchema }

        # 合并 agents，仅更新 plan/build 的 model，保留其他字段
        $agents = [ordered]@{}
        if ($config.Contains('agents') -and $config['agents'] -ne $null) {
            foreach ($p in $config['agents'].PSObject.Properties) { $agents[$p.Name] = $p.Value }
        }
        foreach ($name in @('plan', 'build')) {
            $ref = if ($name -eq 'plan') { $PlanRef } else { $BuildRef }
            if ($agents.Contains($name) -and $agents[$name] -ne $null -and $agents[$name] -is [System.Management.Automation.PSCustomObject]) {
                $newAgent = [ordered]@{}
                foreach ($p in $agents[$name].PSObject.Properties) { $newAgent[$p.Name] = $p.Value }
                $newAgent['model'] = $ref
                $agents[$name] = $newAgent
            } else {
                $agents[$name] = [ordered]@{ model = $ref }
            }
        }
        $config['agents'] = $agents
        $config['model'] = $DefaultModel

        $json = $config | ConvertTo-Json -Depth 50
        [System.IO.File]::WriteAllText($target, $json, $utf8)
        Write-Host "[写入] $target"
    }
}

# ===================== 主流程 =====================
try {
    # 0. 定位 CLI 与 AA key
    $cli = Find-OpenCodeCli -Explicit $CliPath
    $aaKey = if ($AAKey) { $AAKey } else { $env:AA_API_KEY }
    if (-not $aaKey) {
        Write-Warning '未设置 AA_API_KEY，Plan 将回退为"价格最高旗舰"。设置后可启用按 Intelligence Index 选最强。'
    }

    # 1. 配置目录
    $configDir = Get-ConfigDir -Cli $cli
    Write-Host "opencode CLI : $cli"
    Write-Host "配置目录     : $configDir"

    # 2. 拉取模型并过滤
    $allModels = Get-OpenCodeModels -Cli $cli
    $models = @($allModels | Where-Object {
        $_.enabled -ne $false -and $_.status -eq 'active' -and ($Script:Providers -contains $_.providerID)
    })
    if ($models.Count -eq 0) { throw '未找到可用的 opencode / opencode-go 模型。' }
    Write-Host "候选模型数   : $($models.Count)（仅 opencode / opencode-go）"

    # 3. 拉取 AA 智能分（若有 key）
    $aaMap = @{}
    $aaItems = @()
    if ($aaKey) {
        try {
            $aaItems = @(Get-AAData -Key $aaKey)
            foreach ($m in $aaItems) {
                $key = Get-NormalizedKey -Name $m.slug
                if ($key -and -not $aaMap.ContainsKey($key)) {
                    $aaMap[$key] = [pscustomobject]@{ index = $m.index; name = $m.name }
                }
            }
            Write-Host "AA 模型数据   : $($aaItems.Count) 条"
        } catch {
            Write-Warning "AA 接口调用失败（$($_.Exception.Message)），Plan 将回退为价格最高旗舰。"
            $aaMap = @{}
        }
    }

    # 4. 生成候选记录（含智能分）
    $rows = @()
    foreach ($m in $models) {
        $input  = [double]$m.cost[0].input
        $output = [double]$m.cost[0].output
        $total  = $input + $output
        $key    = Get-NormalizedKey -Name $m.id
        $index  = $null
        $aaName = ''
        if ($aaMap.ContainsKey($key)) { $index = $aaMap[$key].index; $aaName = $aaMap[$key].name }
        $rows += [pscustomobject]@{
            ref      = "$($m.providerID)/$($m.id)"
            provider = $m.providerID
            name     = $m.name
            input    = $input
            output   = $output
            total    = $total
            isFree   = ($input -eq 0 -and $output -eq 0)
            index    = $index
            aaName   = $aaName
        }
    }

    # 5. 选择 Build（排除 Free 按综合价取最小；-IncludeFree 则允许免费）
    $buildPool = @($rows | Where-Object { $IncludeFree -or (-not $_.isFree) })
    if ($buildPool.Count -eq 0) { throw '没有可用于 Build 的模型。' }
    $build = $buildPool | Sort-Object total, input | Select-Object -First 1

    # 6. 选择 Plan（按智能分最高；同型号多 provider 取价格最低；无匹配则回退价格最高）
    $plan = $null
    $planSource = ''
    $scored = @($rows | Where-Object { $null -ne $_.index })
    if ($scored.Count -gt 0) {
        $plan = $scored | Sort-Object @{ Expression = 'index'; Descending = $true }, total, input | Select-Object -First 1
        $planSource = "AA Intelligence Index = $($plan.index)（$($plan.aaName)）"
    }
    if (-not $plan) {
        $plan = $buildPool | Sort-Object total, input -Descending | Select-Object -First 1
        $planSource = '回退：未匹配到 AA 智能分，取价格最高旗舰'
    }

    # 7. -ListAll：打印全表后退出
    if ($ListAll) {
        Write-Host ''
        Write-Host '=== 候选模型（按综合价 input+output 升序）==='
        $rows | Sort-Object total, input |
            Select-Object ref, name, input, output, total, @{ n = 'AA智能分'; e = { if ($null -ne $_.index) { $_.index } else { '-' } } } |
            Format-Table -AutoSize | Out-String | Write-Host
        Write-Host "=== 选择结果 ==="
        Write-Host "Build : $($build.ref)  综合价 $($build.total) (in $($build.input) / out $($build.output))"
        Write-Host "Plan  : $($plan.ref)  来源: $planSource"
        return
    }

    # 8. 输出选择结果
    Write-Host ''
    Write-Host '=== 选择结果 ==='
    Write-Host "Build : $($build.ref)  综合价 $($build.total)  (in $($build.input) / out $($build.output))"
    if ($build.isFree) { Write-Host '        （免费模型）' }
    Write-Host "Plan  : $($plan.ref)"
    Write-Host "        来源: $planSource"
    Write-Host "默认  : $($build.ref)   （新会话默认模型，与 Build 一致）"

    # 9. 写入配置（或 DryRun）
    if ($DryRun) {
        Write-Host ''
        Write-Host '[DryRun] 未修改配置。将写入顶层 model、agents.plan.model 与 agents.build.model：'
        Write-Host "  model              = $($build.ref)   （新会话默认模型）"
        Write-Host "  agents.plan.model  = $($plan.ref)"
        Write-Host "  agents.build.model = $($build.ref)"
    } else {
        Write-Config -ConfigDir $configDir -PlanRef $plan.ref -BuildRef $build.ref -DefaultModel $build.ref
        Write-Host ''
        Write-Host '完成。配置已即时生效（若未生效，可在 OpenCode 中执行 /reload）。'
    }
}
catch {
    Write-Host ''
    Write-Error "脚本执行失败：$($_.Exception.Message)"
    exit 1
}
