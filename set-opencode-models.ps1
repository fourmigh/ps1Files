<#
.SYNOPSIS
    自动为 OpenCode 的 plan / build 两个内置 agent 选择最省钱的模型，并写入全局配置。

.DESCRIPTION
    本脚本完成四件事：
      1. 通过 opencode CLI 实时查询当前可用的所有模型及其最新价格（不硬编码价格）；
      2. 按规则挑选模型（先发最小请求探测实际可用性，剔除地区受限等不可用模型）：
           - Build（实现）：在付费模型里选最便宜（默认排除 0 元 Free 模型，可用 -IncludeFree 放开）；
           - Plan （规划）：接入 Artificial Analysis 的 Intelligence Index，选智能分最高的可用模型；
      3. 把结果写入全局配置 opencode.json（更新顶层 model 及 agents.plan.model / agents.build.model，其余字段保留）。
    说明：只影响"新会话"。已有会话的模型受 opencode 桌面应用的输入框快照与历史模型锁定，无法通过脚本批量修改；
          如需让某个老会话用新模型，请在该会话内用 /models 手动选一次。

    模型范围：仅取 opencode（免费）与 opencode-go（付费+免费）两个 provider，忽略 zai / zhipuai 等第三方。

.PARAMETER ListAll
    打印候选模型的价格表（以及有 AA key 时的智能分），按综合价排序，不写配置。

.PARAMETER DryRun
    只显示将要选择的模型和将要写入的内容，不真正修改配置文件。

.PARAMETER IncludeFree
    Build 允许选择 0 元 Free 模型（默认排除 Free，选付费里最便宜的）。

.PARAMETER RefreshAA
    忽略 AA 数据缓存，强制重新拉取（默认当天内命中缓存直接用）。

.PARAMETER RefreshAvail
    忽略模型可用性缓存，强制重新探测所有候选模型的实际可用性。

.PARAMETER NoPause
    结束后不等待回车直接退出（供命令行/自动化使用）。默认会停在"按回车键退出"，便于双击运行时查看结果。

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
    - 缓存文件存放在脚本目录（均为单文件、带日期、跨天自动覆盖，不会堆积）：
        aa-models-cache.json        AA 智能分/价格数据
        model-availability-cache.json 模型实际可用性探测结果
    - 脚本写入的配置会即时生效，无需重启 OpenCode（若未生效可执行 /reload）。
#>

[CmdletBinding()]
param(
    [switch]$ListAll,
    [switch]$DryRun,
    [switch]$IncludeFree,
    [switch]$RefreshAA,
    [switch]$RefreshAvail,
    [switch]$NoPause,
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
$Script:AACachePath   = Join-Path $PSScriptRoot 'aa-models-cache.json'          # AA 数据缓存
$Script:AvailCachePath = Join-Path $PSScriptRoot 'model-availability-cache.json' # 可用性缓存
$Script:AvailMap      = @{}   # 模型可用性内存映射（ref -> bool）

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
    缓存/回退策略：
      1. 当天缓存命中 -> 直接用；
      2. 否则调接口，成功则写当天缓存；
      3. 接口失败但有历史缓存 -> 使用过期缓存（智能分变动不大）；
      4. 接口失败且无任何缓存 -> 抛出错误（由上层回退）。
    返回 PSCustomObject 数组：slug / name / index / inputPrice / outputPrice
#>
function Get-AAData {
    param([string]$Key, [string]$CachePath, [switch]$Refresh)
    $today = Get-Date -Format 'yyyy-MM-dd'

    # 1) 当天缓存
    if (-not $Refresh -and (Test-Path $CachePath)) {
        try {
            $cache = (Get-Content $CachePath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($cache.date -eq $today -and $cache.data -and @($cache.data).Count -gt 0) {
                Write-Host "AA 缓存命中（$today），跳过接口调用"
                return @($cache.data | ForEach-Object {
                    [pscustomobject]@{ slug = $_.slug; name = $_.name; index = $_.index; inputPrice = $_.inputPrice; outputPrice = $_.outputPrice }
                })
            }
        } catch { }
    }

    # 2) 调接口
    try {
        $headers = @{ 'x-api-key' = $Key }
        $all = @()
        $page = 1
        $maxPage = 30
        do {
            $url = "$Script:AA_BaseUrl`?page=$page"
            $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 30
            $json = $resp.Content | ConvertFrom-Json
            foreach ($m in @($json.data)) {
                $all += [pscustomobject]@{
                    slug = $m.slug; name = $m.name
                    index = $m.evaluations.artificial_analysis_intelligence_index
                    inputPrice = $m.pricing.price_1m_input_tokens; outputPrice = $m.pricing.price_1m_output_tokens
                }
            }
            $hasMore = [bool]$json.pagination.has_more
            $page++
        } while ($hasMore -and $page -le $maxPage)

        try {
            $obj = [ordered]@{ date = $today; data = $all }
            [System.IO.File]::WriteAllText($CachePath, ($obj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
            Write-Host "AA 数据已缓存（$today）"
        } catch { Write-Warning "写 AA 缓存失败：$($_.Exception.Message)" }
        return $all
    } catch {
        # 3) 接口失败 -> 使用过期缓存
        if (Test-Path $CachePath) {
            try {
                $cache = (Get-Content $CachePath -Raw -Encoding UTF8) | ConvertFrom-Json
                if ($cache.data -and @($cache.data).Count -gt 0) {
                    Write-Warning "AA 接口不可用，改用过期缓存（日期 $($cache.date)）"
                    return @($cache.data | ForEach-Object {
                        [pscustomobject]@{ slug = $_.slug; name = $_.name; index = $_.index; inputPrice = $_.inputPrice; outputPrice = $_.outputPrice }
                    })
                }
            } catch { }
        }
        # 4) 无任何缓存 -> 抛出
        throw "AA 接口调用失败且无可用缓存：$($_.Exception.Message)"
    }
}

<#
    探测模型实际状态，返回字符串：
      ok         正常可用
      region     地区受限（not available in your country）
      deprecated 已废弃 / 不再支持
      limit      额度用完（周/日/月限额、配额、限流）
      unknown    网络或其它临时失败（不判为不可用）
    用 --archived 让探测会话不进会话列表。
#>
function Test-ModelStatus {
    param([string]$Cli, [string]$ModelRef)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Cli
    $psi.Arguments = 'run --model "' + $ModelRef + '" --archived --title "probe" "Reply with OK"'
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    $combined = "$stdout`n$stderr"

    if ($p.ExitCode -eq 0) {
        if ($combined -match 'not available in your country') { return 'region' }
        if ($combined -match '(?i)deprecated') { return 'deprecated' }
        return 'ok'
    }
    # 非 0：区分模型级不可用 / 额度 / 其它临时失败
    if ($combined -match 'not available in your country') { return 'region' }
    if ($combined -match '(?i)(deprecated|no longer available|not supported)') { return 'deprecated' }
    if ($combined -match '(?i)(usage limit|limit reached|quota|rate limit|too many requests|extra usage|daily.*limit|weekly.*limit|monthly.*limit)') { return 'limit' }
    return 'unknown'
}

<# 读取可用性缓存（同一天才有效），返回 ref -> bool 的映射 #>
function Get-AvailabilityMap {
    param([string]$CachePath)
    $today = Get-Date -Format 'yyyy-MM-dd'
    $map = @{}
    if (Test-Path $CachePath) {
        try {
            $cache = (Get-Content $CachePath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($cache.date -eq $today -and $cache.availability) {
                foreach ($p in $cache.availability.PSObject.Properties) { $map[$p.Name] = [string]$p.Value }
            }
        } catch { }
    }
    return $map
}

<# 保存可用性缓存（单文件按天覆盖） #>
function Save-AvailabilityMap {
    param([string]$CachePath, [hashtable]$Map)
    $today = Get-Date -Format 'yyyy-MM-dd'
    try {
        $avail = [ordered]@{}
        foreach ($k in ($Map.Keys | Sort-Object)) { $avail[$k] = $Map[$k] }
        $obj = [ordered]@{ date = $today; availability = $avail }
        $json = $obj | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($CachePath, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        Write-Warning "写可用性缓存失败：$($_.Exception.Message)"
    }
}

<# 带缓存的状态判断：命中内存缓存则直接用，否则实际探测并记录（状态字符串） #>
function Test-ModelStatusCached {
    param([string]$Cli, [string]$ModelRef)
    if ($Script:AvailMap.ContainsKey($ModelRef)) { return $Script:AvailMap[$ModelRef] }
    $status = Test-ModelStatus -Cli $Cli -ModelRef $ModelRef
    $Script:AvailMap[$ModelRef] = $status
    return $status
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


<# 结束前暂停，便于双击运行时查看最终结果；-NoPause 可跳过 #>
function Wait-Exit {
    if ($NoPause) { return }
    Write-Host ''
    Write-Host '按回车键退出...'
    $null = Read-Host
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
            $aaItems = @(Get-AAData -Key $aaKey -CachePath $Script:AACachePath -Refresh:$RefreshAA)
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
            modelId  = $m.id
            name     = $m.name
            input    = $input
            output   = $output
            total    = $total
            isFree   = ($input -eq 0 -and $output -eq 0)
            index    = $index
            aaName   = $aaName
        }
    }

    # 5. -ListAll：只打印全表（不做可用性探测，避免大量请求），退出
    if ($ListAll) {
        Write-Host ''
        Write-Host '=== 候选模型（按综合价 input+output 升序；实际可用性在正式选择时探测）==='
        $rows | Sort-Object total, input |
            Select-Object ref, name, input, output, total, @{ n = 'AA智能分'; e = { if ($null -ne $_.index) { $_.index } else { '-' } } } |
            Format-Table -AutoSize | Out-String | Write-Host
        Wait-Exit
        return
    }

    # 6. 加载可用性缓存（未指定 -RefreshAvail 时，复用当天的探测结果）
    if (-not $RefreshAvail) {
        $Script:AvailMap = Get-AvailabilityMap -CachePath $Script:AvailCachePath
        if ($Script:AvailMap.Count -gt 0) { Write-Host "可用性缓存   : $($Script:AvailMap.Count) 条（当日）" }
    }

    # 7. 选择 Build：排除 Free，按综合价升序逐个探测（三态）；遇"额度用完"立即停止
    $buildPool = @($rows | Where-Object { $IncludeFree -or (-not $_.isFree) } | Sort-Object total, input)
    if ($buildPool.Count -eq 0) { throw '没有可用于 Build 的模型。' }
    $build = $null
    $unknownFallback = $null
    $limitHit = $false
    foreach ($cand in $buildPool) {
        $status = Test-ModelStatusCached -Cli $cli -ModelRef $cand.ref
        if ($status -eq 'ok') { $build = $cand; break }
        if ($status -eq 'limit') { $limitHit = $true; break }   # 额度是账户全局的，立即停止
        if ($status -in @('region', 'deprecated')) {
            Write-Host "    [剔除] $($cand.ref) 不可用（$status）"
            continue
        }
        # unknown：限额外的临时失败（网络等），记为兜底，继续尝试更贵的
        if (-not $unknownFallback) { $unknownFallback = $cand }
        Write-Host "    [临时] $($cand.ref) 探测失败，暂列为兜底"
    }

    if ($limitHit) {
        Write-Host ''
        Write-Host '=== 检测到额度用完 ==='
        Write-Host 'OpenCode Go 周/日/月限额已用完，所有模型暂时都无法调用。'
        Write-Host '无需重新选型（都用不了），保持现有配置不变；额度恢复后重跑本脚本即可。'
        if ($Script:AvailMap.Count -gt 0) { Save-AvailabilityMap -CachePath $Script:AvailCachePath -Map $Script:AvailMap }
        Wait-Exit
        return
    }

    $buildFromFallback = $false
    if (-not $build) {
        if ($unknownFallback) { $build = $unknownFallback; $buildFromFallback = $true }
    }
    if (-not $build) { throw '所有候选 Build 模型均不可用（地区受限/已废弃）。' }

    # 8. 选择 Plan：按智能分降序逐个探测（三态）
    $plan = $null
    $planSource = ''
    $planUnknown = $null
    $scored = @($rows | Where-Object { $null -ne $_.index } | Sort-Object @{ Expression = 'index'; Descending = $true }, total, input)
    foreach ($cand in $scored) {
        $status = Test-ModelStatusCached -Cli $cli -ModelRef $cand.ref
        if ($status -eq 'ok') {
            $plan = $cand
            $planSource = "AA Intelligence Index = $($cand.index)（$($cand.aaName)）"
            break
        }
        if ($status -eq 'limit') { break }   # 额度用完，下面回退
        if ($status -in @('region', 'deprecated')) {
            Write-Host "    [剔除] $($cand.ref) 不可用（$status）（Plan）"
            continue
        }
        if (-not $planUnknown) { $planUnknown = $cand }
    }
    if (-not $plan -and $planUnknown) {
        $plan = $planUnknown
        $planSource = "AA Intelligence Index = $($plan.index)（$($plan.aaName)，临时兜底）"
    }
    if (-not $plan) {
        $plan = $build
        $planSource = '回退：所有带智能分模型均不可用/额度受限，沿用 Build 模型'
    }

    # 保存本次可用性探测结果（单文件按天覆盖）
    if ($Script:AvailMap.Count -gt 0) {
        Save-AvailabilityMap -CachePath $Script:AvailCachePath -Map $Script:AvailMap
    }

    # 8. 输出选择结果
    Write-Host ''
    Write-Host '=== 选择结果 ==='
    Write-Host "Build : $($build.ref)  综合价 $($build.total)  (in $($build.input) / out $($build.output))"
    if ($build.isFree) { Write-Host '        （免费模型）' }
    if ($buildFromFallback) { Write-Host '        （注：该模型为临时探测失败兜底，额度恢复后即可用）' }
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
    Wait-Exit
}
catch {
    Write-Host ''
    Write-Host "脚本执行失败：$($_.Exception.Message)" -ForegroundColor Red
    Wait-Exit
    exit 1
}
