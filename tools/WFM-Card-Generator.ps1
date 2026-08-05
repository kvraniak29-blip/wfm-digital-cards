#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BrokerFolder,
    [switch]$Generate,
    [switch]$Publish,
    [switch]$Silent,
    [switch]$ValidationSelfTest,
    [switch]$BrokerLoadSelfTest,
    [switch]$GuiLoadSelfTest,
    [switch]$GuiGenerateSelfTest,
    [switch]$GuiPhotoPositionSelfTest,
    [switch]$PublishPlanSelfTest,
    [switch]$PublishWorktreeIsolationSelfTest,
    [switch]$PublicPreview404SelfTest,
    [string]$OverrideFile,
    [string]$ResultFile,
    [switch]$SkipImportTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LogsDir = Join-Path $ProjectRoot 'logs'
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
$LogFile = Join-Path $LogsDir ("WFM-Generator-{0}-{1}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
$script:PreviewServerProcess = $null
$script:LastBrokerInfo = $null
$script:LastOverrideFile = $null
$script:LastOutputFolder = Join-Path $ProjectRoot 'dist'
$script:IsLoadingBroker = $false
$script:GenerationProcess = $null
$script:GenerationTimer = $null
$script:GenerationResultFile = $null
$script:GenerationOverrideFile = $null
$script:CurrentPublishMode = $false
$script:GuiSelfTestSkipImportTests = $false

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Join-ProcessArguments {
    param([string[]]$Arguments)
    return ($Arguments | ForEach-Object {
        $value = [string]$_
        if ($value -notmatch '[\s"]') {
            $value
        } else {
            '"' + ($value.Replace('"', '\"')) + '"'
        }
    }) -join ' '
}

function Write-ResultFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Status,
        [string]$Slug,
        [bool]$Published = $false,
        [Parameter(Mandatory)][string]$Message,
        [string]$Detail = '',
        [string]$Phase = '',
        [string]$PublicUrl = '',
        [string]$PublishBranch = '',
        [string]$PrNumber = '',
        [string]$PrUrl = '',
        [string]$HeadSha = '',
        [string]$MergeSha = '',
        [string]$WorkflowRunUrl = ''
    )

    $result = [ordered]@{
        status = $Status
        slug = $Slug
        published = $Published
        message = $Message
        detail = $Detail
        phase = $Phase
        publicUrl = $PublicUrl
        publishBranch = $PublishBranch
        prNumber = $PrNumber
        prUrl = $PrUrl
        headSha = $HeadSha
        mergeSha = $MergeSha
        workflowRunUrl = $WorkflowRunUrl
        logFile = $LogFile
    }
    $json = ($result | ConvertTo-Json -Depth 5)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $json, $utf8NoBom)
}

function Get-FailureSummary {
    param([string]$Message)

    $text = [string]$Message
    $lines = @($text -split "\r?\n" | Where-Object { $_ -and $_.Trim() })
    $failLine = $lines | Where-Object { $_ -match '^FAIL\s+' } | Select-Object -First 1
    if ($failLine) { return $failLine.Trim() }

    $assertLine = $lines | Where-Object { $_ -match 'AssertionError|Expected values|actual|expected|ERR_ASSERTION|notEqual|strictEqual' } | Select-Object -First 1
    if ($assertLine) { return $assertLine.Trim() }

    $commandLine = $lines | Where-Object { $_ -match 'Príkaz zlyhal|Command failed' } | Select-Object -First 1
    if ($commandLine) { return $commandLine.Trim() }

    if ($lines.Count -gt 0) { return $lines[0].Trim() }
    return 'Neznáma chyba child procesu.'
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 420
    )
    $value = ([string]$Text).Trim()
    if ($value.Length -le $MaxLength) { return $value }
    return $value.Substring(0, $MaxLength - 3) + '...'
}

function Format-ResultFailureForGui {
    param($Result)

    $message = Limit-Text ([string]$Result.message) 260
    if ($Result.phase) { $message = "[$($Result.phase)] $message" }
    $log = if ($Result.logFile) { [string]$Result.logFile } else { $LogFile }
    $extra = if ($Result.prUrl) { "`nPR: $($Result.prUrl)" } else { '' }
    return "FAIL $message`nLog: $log$extra"
}

function Invoke-CommandInDirectory {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    Write-Log ("RUN [{0}] {1} {2}" -f $WorkingDirectory, $FilePath, ($Arguments -join " "))
    Push-Location $WorkingDirectory
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $rawOutput = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $exitCode) { $exitCode = 0 }
        $output = ($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($output) { Write-Log $output }
        if ($exitCode -ne 0) {
            throw "Príkaz zlyhal s kódom ${exitCode}: $FilePath $($Arguments -join ' ')`n$output"
        }
        return $output
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-ResultSlug {
    param(
        [string]$Folder,
        [string]$PreparedOverrideFile
    )
    if ($PreparedOverrideFile -and (Test-Path -LiteralPath $PreparedOverrideFile -PathType Leaf)) {
        try {
            $data = Get-Content -LiteralPath $PreparedOverrideFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($data.slug) { return [string]$data.slug }
        } catch {}
    }
    if ($Folder) {
        try {
            return [string](Get-BrokerInfo $Folder).broker.slug
        } catch {}
    }
    return ''
}

function Invoke-ProjectCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$Arguments = @()
    )

    Write-Log ("RUN {0} {1}" -f $FilePath, ($Arguments -join " "))
    Push-Location $ProjectRoot
    $previousErrorActionPreference = $ErrorActionPreference

    try {
        $ErrorActionPreference = 'Continue'
        $rawOutput = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($null -eq $exitCode) { $exitCode = 0 }

        $output = ($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($output) { Write-Log $output }

        if ($exitCode -ne 0) {
            throw "Príkaz zlyhal s kódom ${exitCode}: $FilePath $($Arguments -join ' ')`n$output"
        }

        return $output
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
}

function Get-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Node.js nie je dostupný v PATH." }
    return $cmd.Source
}

function Get-NpmExe {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cmd = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "npm nie je dostupné v PATH." }
    return $cmd.Source
}

function Get-CompanyConfig {
    $file = Join-Path $ProjectRoot 'config\company.json'
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-BrokerInfo {
    param([Parameter(Mandatory)][string]$Folder)
    $node = Get-NodeExe
    $json = Invoke-ProjectCommand $node @('scripts/inspect-broker-folder.mjs', '--folder', $Folder)
    $info = $json | ConvertFrom-Json
    $company = Get-CompanyConfig

    if (-not $info.broker.company) { $info.broker.company = $company.name }
    if (-not $info.broker.website) { $info.broker.website = $company.website }
    if (-not $info.broker.whatsapp -and $info.broker.phoneE164) {
        $info.broker.whatsapp = "https://wa.me/$($info.broker.phoneE164.Replace('+',''))"
    }
    if (-not $info.broker.social.facebook) { $info.broker.social.facebook = $company.facebook }
    if (-not $info.broker.social.instagram) { $info.broker.social.instagram = $company.instagram }
    if (-not $info.broker.photoPosition) { $info.broker.photoPosition = '50% 50%' }

    return $info
}

function Remove-OldLogs {
    $limit = (Get-Date).AddDays(-30)
    Get-ChildItem -LiteralPath $LogsDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $limit -and ($_.Name -like 'WFM-Generator-*.log' -or $_.Name -like 'broker-override-*.json') } |
        ForEach-Object {
            try {
                Remove-Item -LiteralPath $_.FullName -Force
                Write-Log "Odstránený starý dočasný súbor: $($_.FullName)"
            } catch {
                Write-Log "WARN Nepodarilo sa odstrániť starý súbor: $($_.FullName) - $($_.Exception.Message)"
            }
        }
}

function Write-BrokerOverride {
    param(
        [Parameter(Mandatory)]$Broker
    )
    $override = [ordered]@{
        active = $true
        slug = $Broker.slug
        firstName = $Broker.firstName
        lastName = $Broker.lastName
        displayName = $Broker.displayName
        title = $Broker.title
        company = $Broker.company
        phoneDisplay = $Broker.phoneDisplay
        phoneE164 = $Broker.phoneE164
        email = $Broker.email
        website = $Broker.website
        whatsapp = $Broker.whatsapp
        photoPosition = $Broker.photoPosition
        social = [ordered]@{
            facebook = $Broker.facebook
            instagram = $Broker.instagram
        }
    }
    $safe = ($Broker.slug -replace '[^a-zA-Z0-9-]', '-')
    if (-not $safe) { $safe = 'broker' }
    $file = Join-Path $LogsDir ("broker-override-{0}-{1}.json" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $json = ($override | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Log "Zapísaný dočasný broker override: $file"
    return $file
}

function Write-SourceBrokerJson {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)]$Broker
    )

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Priečinok makléra neexistuje: $Folder" }
    $file = Join-Path $Folder 'broker.json'
    $source = [ordered]@{
        active = $true
        slug = $Broker.slug
        firstName = $Broker.firstName
        lastName = $Broker.lastName
        displayName = $Broker.displayName
        title = $Broker.title
        company = $Broker.company
        phoneDisplay = $Broker.phoneDisplay
        phoneE164 = $Broker.phoneE164
        email = $Broker.email
        website = $Broker.website
        whatsapp = $Broker.whatsapp
        photoPosition = $Broker.photoPosition
        social = [ordered]@{
            facebook = $Broker.facebook
            instagram = $Broker.instagram
        }
    }
    $json = ($source | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Log "Uložený zdrojový broker.json: $file"
    return $file
}

function Test-FieldValues {
    param(
        [Parameter(Mandatory)]$Broker
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($pair in @(
        @('firstName', 'Meno'),
        @('lastName', 'Priezvisko'),
        @('displayName', 'Zobrazované meno'),
        @('title', 'Pracovná pozícia'),
        @('company', 'Spoločnosť'),
        @('phoneE164', 'Telefón - medzinárodný formát'),
        @('email', 'E-mail'),
        @('website', 'Web'),
        @('whatsapp', 'WhatsApp'),
        @('slug', 'URL identifikátor'),
        @('photoPosition', 'Pozícia fotografie')
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$Broker.($pair[0]))) { [void]$errors.Add("$($pair[1]) je povinné pole.") }
    }

    if ($Broker.phoneE164 -and $Broker.phoneE164 -notmatch '^\+[1-9]\d{7,14}$') { [void]$errors.Add('Telefón musí byť vo formáte E.164, napríklad +421900111222.') }
    if ($Broker.email -and $Broker.email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { [void]$errors.Add('E-mail nemá platný formát.') }
    foreach ($pair in @(
        @('website', 'Web'),
        @('whatsapp', 'WhatsApp'),
        @('facebook', 'Facebook'),
        @('instagram', 'Instagram')
    )) {
        $value = [string]$Broker.($pair[0])
        if ($value -and $value -notmatch '^https://[^\s]+$') { [void]$errors.Add("$($pair[1]) musí byť HTTPS URL.") }
    }
    if ($Broker.whatsapp -and $Broker.phoneE164) {
        $expected = "https://wa.me/$($Broker.phoneE164.Replace('+',''))"
        if ($Broker.whatsapp -ne $expected) { [void]$errors.Add("WhatsApp URL musí zodpovedať telefónu: $expected") }
    }
    if ($Broker.slug -and $Broker.slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { [void]$errors.Add('URL identifikátor smie obsahovať malé písmená bez diakritiky, čísla a pomlčky.') }
    if ($Broker.photoPosition -and $Broker.photoPosition -notmatch '^(left|right|center|top|bottom|[0-9]{1,3}%)(\s+(left|right|center|top|bottom|[0-9]{1,3}%))?$') {
        [void]$errors.Add('Pozícia fotografie musí byť napríklad 50% 50%, center alebo top center.')
    }

    return $errors.ToArray()
}

function Get-ImageCopy {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Fotografia neexistuje: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 4) { throw "Fotografia je prázdna alebo nečitateľná: $Path" }
    $stream = [System.IO.MemoryStream]::new($bytes)
    $image = $null
    try {
        $image = [System.Drawing.Image]::FromStream($stream)
        return New-Object System.Drawing.Bitmap($image)
    } catch {
        throw "Fotografia sa nedá načítať: $Path - $($_.Exception.Message)"
    } finally {
        if ($image) { $image.Dispose() }
        $stream.Dispose()
    }
}

function Convert-FieldsToBroker {
    param([hashtable]$Fields)
    $broker = [ordered]@{}
    foreach ($key in $Fields.Keys) { $broker[$key] = $Fields[$key].Text.Trim() }
    return [pscustomobject]$broker
}

function Invoke-GenerateCore {
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter()][object]$Broker,
        [Parameter()][bool]$DoPublish = $false,
        [Parameter()][string]$PreparedOverrideFile,
        [Parameter()][bool]$SkipImportTests = $false
    )

    Remove-OldLogs
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Priečinok makléra neexistuje: $Folder" }
    if ($Broker) {
        $errors = @(Test-FieldValues $Broker)
        if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
        $script:LastOverrideFile = Write-BrokerOverride $Broker
    } elseif ($PreparedOverrideFile) {
        if (-not (Test-Path -LiteralPath $PreparedOverrideFile -PathType Leaf)) { throw "Override súbor neexistuje: $PreparedOverrideFile" }
        $script:LastOverrideFile = $PreparedOverrideFile
    } else {
        $script:LastOverrideFile = $null
    }

    $node = Get-NodeExe
    $npm = Get-NpmExe
    try {
        $importArgs = @('scripts/import-broker.mjs', '--folder', $Folder, '--yes-update')
        if ($script:LastOverrideFile) { $importArgs += @('--override', $script:LastOverrideFile) }
        if ($SkipImportTests) { $importArgs += '--skip-tests' }
        Invoke-ProjectCommand $node $importArgs | Out-Null
        Invoke-ProjectCommand $npm @('run', 'build:github-pages') | Out-Null

        if ($script:LastOverrideFile -and -not $PreparedOverrideFile -and (Test-Path -LiteralPath $script:LastOverrideFile)) {
            Remove-Item -LiteralPath $script:LastOverrideFile -Force
            Write-Log "Odstránený úspešný dočasný override: $script:LastOverrideFile"
            $script:LastOverrideFile = $null
        }

        if ($DoPublish) {
            $slug = Get-ResultSlug $Folder $script:LastOverrideFile
            $displayName = ''
            try { $displayName = [string](Get-BrokerFromCanonicalJson -RepoRoot $ProjectRoot -Slug $slug).displayName } catch {}
            if (-not $displayName -and $Broker -and $Broker.displayName) { $displayName = [string]$Broker.displayName }
            if (-not $displayName) { $displayName = $slug }
            return (Invoke-IsolatedPublish -Slug $slug -DisplayName $displayName)
        }
        return $false
    } catch {
        if ($script:LastOverrideFile) { Write-Log "Dočasný override ponechaný pre diagnostiku: $script:LastOverrideFile" }
        throw
    }
}

function Get-GitPorcelain {
    $out = Invoke-ProjectCommand 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain')
    if (-not $out) { return @() }
    return @($out -split "`r?`n" | Where-Object { $_.Trim() })
}

function Get-CurrentGitBranch {
    try {
        return (Invoke-ProjectCommand 'git.exe' @('branch', '--show-current')).Trim()
    } catch {
        return ''
    }
}

function Get-PublishAllowedPaths {
    param([Parameter(Mandatory)][string]$Slug)
    return @(
        "data/brokers/$Slug.json",
        "data/status/$Slug.json",
        "assets/brokers/$Slug/photo.jpg"
    )
}

function Get-PublicBrokerUrl {
    param([Parameter(Mandatory)][string]$Slug)
    return "https://kvraniak29-blip.github.io/wfm-digital-cards/$Slug/"
}

function Get-PublishPlan {
    param([Parameter(Mandatory)][string]$Slug)
    $paths = Get-PublishAllowedPaths $Slug
    foreach ($relative in $paths) {
        $file = Join-Path $ProjectRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Publikačný súbor neexistuje: $relative" }
    }
    return [pscustomobject]@{
        slug = $Slug
        publicUrl = Get-PublicBrokerUrl $Slug
        allowedPaths = $paths
    }
}

function Assert-PublishPathsOnly {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Slug
    )

    $allowed = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($path in (Get-PublishAllowedPaths $Slug)) { [void]$allowed.Add($path) }
    $status = Invoke-CommandInDirectory $RepoRoot 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '--untracked-files=all')
    $lines = @($status -split "`r?`n" | Where-Object { $_.Trim() })
    foreach ($line in $lines) {
        $relative = $line.Substring(3).Trim().Replace('\','/')
        if ($relative -match ' -> ') { $relative = ($relative -split ' -> ')[1] }
        if (-not $allowed.Contains($relative)) {
            throw "Publikačný worktree obsahuje nepovolenú cestu: $relative"
        }
    }
}

function Copy-PublishFilesToWorktree {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    foreach ($relative in (Get-PublishAllowedPaths $Slug)) {
        $source = Join-Path $ProjectRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destination = Join-Path $DestinationRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $destinationFolder = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function Get-BrokerFromCanonicalJson {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Slug
    )
    $file = Join-Path $RepoRoot "data\brokers\$Slug.json"
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Broker JSON neexistuje: $file" }
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-BuildContainsBroker {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$Slug
    )

    $broker = Get-BrokerFromCanonicalJson -RepoRoot $RepoRoot -Slug $Slug
    $htmlFile = Join-Path $RepoRoot "dist\$Slug\index.html"
    $photoFile = Join-Path $RepoRoot "dist\$Slug\photo.jpg"
    $vcfFile = Join-Path $RepoRoot "dist\$Slug\$Slug.vcf"
    $qrFile = Join-Path $RepoRoot "dist\$Slug\qr.png"
    foreach ($file in @($htmlFile, $photoFile, $vcfFile, $qrFile)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Build neobsahuje očakávaný súbor: $file" }
    }
    $html = Get-Content -LiteralPath $htmlFile -Raw -Encoding UTF8
    foreach ($value in @($broker.displayName, $broker.title, $broker.phoneE164, $broker.email, $broker.website)) {
        if ($value -and -not $html.Contains([string]$value)) { throw "HTML neobsahuje hodnotu: $value" }
    }
    $position = if ($broker.photoPosition) { [string]$broker.photoPosition } else { '50% 50%' }
    if (-not $html.Contains("object-position: $position;")) { throw "HTML nepoužíva photoPosition z JSON: $position" }
    $vcf = Get-Content -LiteralPath $vcfFile -Raw -Encoding UTF8
    if (-not $vcf.Contains('PHOTO;ENCODING=b;TYPE=JPEG:')) { throw 'VCF neobsahuje JPEG PHOTO.' }
    $photoBytes = [System.IO.File]::ReadAllBytes($photoFile)
    if ($photoBytes.Length -lt 2 -or $photoBytes[0] -ne 0xFF -or $photoBytes[1] -ne 0xD8) { throw 'Fotografia v builde nie je JPEG.' }
    $qrBytes = [System.IO.File]::ReadAllBytes($qrFile)
    if ($qrBytes.Length -lt 2 -or $qrBytes[0] -ne 0x89 -or $qrBytes[1] -ne 0x50) { throw 'QR v builde nie je PNG.' }
}

function Wait-GitHubChecks {
    param(
        [Parameter(Mandatory)][string]$PrNumber,
        [Parameter(Mandatory)][string]$HeadSha,
        [string[]]$Required = @('build', 'windows-generator-smoke'),
        [int]$Attempts = 90
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $json = Invoke-ProjectCommand 'gh.exe' @('pr', 'view', $PrNumber, '--json', 'headRefOid,statusCheckRollup,url')
        $view = $json | ConvertFrom-Json
        if ($view.headRefOid -ne $HeadSha) { throw "PR head SHA sa zmenil: $($view.headRefOid)" }
        $pending = @()
        foreach ($name in $Required) {
            $check = @($view.statusCheckRollup | Where-Object { $_.name -eq $name } | Select-Object -First 1)
            if (-not $check) { $pending += $name; continue }
            if ($check.conclusion -eq 'FAILURE' -or $check.conclusion -eq 'CANCELLED' -or $check.conclusion -eq 'TIMED_OUT') {
                throw "GitHub check zlyhal: $name $($check.conclusion) $($check.detailsUrl)"
            }
            if ($check.status -ne 'COMPLETED' -or $check.conclusion -ne 'SUCCESS') { $pending += $name }
        }
        if ($pending.Count -eq 0) { return $view }
        Start-Sleep -Seconds 10
    }
    throw 'GitHub checks nedokončili v časovom limite.'
}

function Wait-MainWorkflow {
    param(
        [Parameter(Mandatory)][string]$MergeSha,
        [int]$Attempts = 90
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        $listJson = Invoke-ProjectCommand 'gh.exe' @('run', 'list', '--branch', 'main', '--commit', $MergeSha, '--limit', '5', '--json', 'databaseId,status,conclusion,url')
        $run = @($listJson | ConvertFrom-Json | Select-Object -First 1)
        if ($run) {
            $viewJson = Invoke-ProjectCommand 'gh.exe' @('run', 'view', [string]$run.databaseId, '--json', 'status,conclusion,jobs,url')
            $view = $viewJson | ConvertFrom-Json
            if ($view.status -eq 'completed') {
                if ($view.conclusion -ne 'success') { throw "Main workflow zlyhal: $($view.conclusion) $($view.url)" }
                foreach ($name in @('build', 'windows-generator-smoke', 'deploy')) {
                    $job = @($view.jobs | Where-Object { $_.name -eq $name } | Select-Object -First 1)
                    if (-not $job -or $job.conclusion -ne 'success') { throw "Main workflow job nie je SUCCESS: $name" }
                }
                return $view
            }
        }
        Start-Sleep -Seconds 10
    }
    throw 'Main workflow nedokončil v časovom limite.'
}

function Test-PublicCard {
    param([Parameter(Mandatory)][string]$Slug)
    $url = Get-PublicBrokerUrl $Slug
    $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20
    if ($response.StatusCode -ne 200) { throw "Verejná vizitka nevrátila HTTP 200: $($response.StatusCode)" }
    foreach ($suffix in @('photo.jpg', "$Slug.vcf", 'qr.png')) {
        $asset = Invoke-WebRequest -UseBasicParsing -Uri ($url + $suffix) -TimeoutSec 20
        if ($asset.StatusCode -ne 200) { throw "Verejný súbor nevrátil HTTP 200: $suffix $($asset.StatusCode)" }
    }
}

function Test-PublicUrlAvailable {
    param([Parameter(Mandatory)][string]$Slug)
    $url = Get-PublicBrokerUrl $Slug
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url -TimeoutSec 10
        return [pscustomobject]@{ StatusCode = [int]$response.StatusCode; Url = $url }
    } catch {
        $statusCode = 0
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $statusCode = [int]$_.Exception.Response.StatusCode }
        return [pscustomobject]@{ StatusCode = $statusCode; Url = $url }
    }
}

function Get-PublicPreviewMessage {
    param(
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$Url
    )
    if ($StatusCode -eq 200) { return "PASS Verejná vizitka: $Url" }
    if ($StatusCode -eq 404) { return 'Vizitka zatiaľ nie je publikovaná.' }
    return "FAIL Verejná URL nevrátila HTTP 200. Status=$StatusCode"
}

function Invoke-IsolatedPublish {
    param(
        [Parameter(Mandatory)][string]$Slug,
        [Parameter(Mandatory)][string]$DisplayName
    )

    $phase = 'PREFLIGHT'
    $worktree = $null
    $publishBranch = $null
    $prNumber = ''
    $prUrl = ''
    $headSha = ''
    $mergeSha = ''
    $workflowUrl = ''
    $beforeStatus = (Invoke-ProjectCommand 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1'))
    $beforeBranch = Get-CurrentGitBranch
    Write-Log "PUBLISH originalBranch=$beforeBranch"
    Write-Log "PUBLISH originalStatus=$beforeStatus"
    try {
        $plan = Get-PublishPlan $Slug
        foreach ($tool in @('git.exe', 'gh.exe', (Get-NodeExe), (Get-NpmExe))) {
            Get-Command $tool -ErrorAction Stop | Out-Null
        }

        $phase = 'WORKTREE'
        Invoke-ProjectCommand 'git.exe' @('fetch', 'origin', 'main') | Out-Null
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeSlug = $Slug -replace '[^a-zA-Z0-9-]', '-'
        $publishBranch = "publish/$safeSlug-$timestamp"
        $worktreeRoot = Join-Path $ProjectRoot 'work\publish-worktrees'
        New-Item -ItemType Directory -Path $worktreeRoot -Force | Out-Null
        $worktree = Join-Path $worktreeRoot "$safeSlug-$timestamp"
        Invoke-ProjectCommand 'git.exe' @('worktree', 'add', $worktree, 'origin/main') | Out-Null
        Invoke-CommandInDirectory $worktree 'git.exe' @('switch', '-c', $publishBranch) | Out-Null
        Copy-PublishFilesToWorktree -Slug $Slug -DestinationRoot $worktree
        Assert-PublishPathsOnly -RepoRoot $worktree -Slug $Slug

        $phase = 'VALIDATE'
        Invoke-CommandInDirectory $worktree (Get-NpmExe) @('ci') | Out-Null
        Invoke-CommandInDirectory $worktree (Get-NpmExe) @('run', 'validate') | Out-Null
        $phase = 'TEST'
        Invoke-CommandInDirectory $worktree (Get-NpmExe) @('test') | Out-Null
        $phase = 'BUILD'
        Invoke-CommandInDirectory $worktree (Get-NpmExe) @('run', 'build:github-pages') | Out-Null
        Test-BuildContainsBroker -RepoRoot $worktree -Slug $Slug

        $phase = 'COMMIT'
        Invoke-CommandInDirectory $worktree 'git.exe' @('add', '--', "data/brokers/$Slug.json", "data/status/$Slug.json", "assets/brokers/$Slug/photo.jpg") | Out-Null
        Assert-PublishPathsOnly -RepoRoot $worktree -Slug $Slug
        $pending = Invoke-CommandInDirectory $worktree 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1')
        if (-not $pending.Trim()) { throw 'Publikovanie nemá žiadne zmeny na commit.' }
        Invoke-CommandInDirectory $worktree 'git.exe' @('commit', '-m', "Publish $DisplayName digital card") | Out-Null
        $headSha = (Invoke-CommandInDirectory $worktree 'git.exe' @('rev-parse', 'HEAD')).Trim()

        $phase = 'PUSH'
        Invoke-CommandInDirectory $worktree 'git.exe' @('push', '-u', 'origin', $publishBranch) | Out-Null

        $phase = 'PR'
        $body = @(
            "Slug: $Slug",
            "Verejná URL: $($plan.publicUrl)",
            "photoPosition: $((Get-BrokerFromCanonicalJson -RepoRoot $worktree -Slug $Slug).photoPosition)",
            "validate/test/build: PASS",
            "Publikované cesty:",
            "- data/brokers/$Slug.json",
            "- data/status/$Slug.json",
            "- assets/brokers/$Slug/photo.jpg"
        ) -join [Environment]::NewLine
        $prOutput = Invoke-CommandInDirectory $worktree 'gh.exe' @('pr', 'create', '--base', 'main', '--head', $publishBranch, '--title', "Publish $DisplayName digital card", '--body', $body)
        $prUrl = ($prOutput -split "`r?`n" | Where-Object { $_ -match '^https://github.com/' } | Select-Object -First 1).Trim()
        if (-not $prUrl) { throw 'GitHub PR URL nebola vytvorená.' }
        $prNumber = [regex]::Match($prUrl, '/pull/(\d+)').Groups[1].Value

        $phase = 'CHECKS'
        Wait-GitHubChecks -PrNumber $prNumber -HeadSha $headSha | Out-Null

        $phase = 'MERGE'
        $viewJson = Invoke-CommandInDirectory $worktree 'gh.exe' @('pr', 'view', $prNumber, '--json', 'headRefOid')
        $view = $viewJson | ConvertFrom-Json
        if ($view.headRefOid -ne $headSha) { throw "PR head SHA sa pred merge zmenil: $($view.headRefOid)" }
        Invoke-CommandInDirectory $worktree 'gh.exe' @('pr', 'merge', $prNumber, '--merge') | Out-Null
        $mergedJson = Invoke-CommandInDirectory $worktree 'gh.exe' @('pr', 'view', $prNumber, '--json', 'mergeCommit,state,mergedAt,url')
        $merged = $mergedJson | ConvertFrom-Json
        if ($merged.state -ne 'MERGED' -or -not $merged.mergeCommit.oid) { throw 'PR nebol zlúčený.' }
        $mergeSha = [string]$merged.mergeCommit.oid

        $phase = 'DEPLOY'
        $workflow = Wait-MainWorkflow -MergeSha $mergeSha
        $workflowUrl = [string]$workflow.url

        $phase = 'VERIFY'
        Test-PublicCard -Slug $Slug

        return [pscustomobject]@{
            status = 'PASS'
            published = $true
            message = 'Vizitka bola úspešne publikovaná.'
            slug = $Slug
            publicUrl = $plan.publicUrl
            publishBranch = $publishBranch
            prNumber = $prNumber
            prUrl = $prUrl
            headSha = $headSha
            mergeSha = $mergeSha
            workflowRunUrl = $workflowUrl
        }
    } catch {
        $detail = [string]$_.Exception.Message
        throw "[PUBLISH_PHASE=$phase] $detail"
    } finally {
        if ($worktree -and (Test-Path -LiteralPath $worktree)) {
            try { Invoke-ProjectCommand 'git.exe' @('worktree', 'remove', '--force', $worktree) | Out-Null } catch { Write-Log "WARN worktree remove zlyhal: $($_.Exception.Message)" }
        }
        if ($publishBranch) {
            try { Invoke-ProjectCommand 'git.exe' @('branch', '-D', $publishBranch) | Out-Null } catch {}
        }
        $afterStatus = (Invoke-ProjectCommand 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1'))
        if ($afterStatus -ne $beforeStatus) {
            Write-Log "WARN Stav pôvodného repozitára sa zmenil počas publish kroku."
            Write-Log "BEFORE: $beforeStatus"
            Write-Log "AFTER: $afterStatus"
        }
    }
}

function Test-PortOpen {
    param([int]$Port)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(300)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Invoke-HttpWait {
    param([string]$Url)
    for ($i = 0; $i -lt 40; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) { return }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
    throw "Lokálny HTTP server neodpovedá: $Url"
}

function Start-LocalPreview {
    param([string]$Slug)
    $manifest = Join-Path $ProjectRoot 'dist\manifest.json'
    if (-not (Test-Path -LiteralPath $manifest)) {
        Invoke-ProjectCommand (Get-NpmExe) @('run', 'build:github-pages') | Out-Null
    }

    if (-not (Test-PortOpen 4173)) {
        $node = Get-NodeExe
        $script = Join-Path $ProjectRoot 'scripts\serve.mjs'
        $script:PreviewServerProcess = Start-Process -FilePath $node -ArgumentList @($script) -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru
    }

    Invoke-HttpWait 'http://127.0.0.1:4173/wfm-digital-cards/'
    $target = 'http://127.0.0.1:4173/wfm-digital-cards/'
    if ($Slug) { $target = "http://127.0.0.1:4173/wfm-digital-cards/$Slug/" }
    Invoke-HttpWait $target
    Start-Process $target
    return $target
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WFM Reality - generátor digitálnych vizitiek'
    $form.MinimumSize = New-Object System.Drawing.Size(1040, 760)
    $form.Size = New-Object System.Drawing.Size(1180, 820)
    $form.StartPosition = 'CenterScreen'
    $form.AutoScroll = $true

    $toolTip = New-Object System.Windows.Forms.ToolTip
    $rootLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $rootLayout.Dock = 'Fill'
    $rootLayout.ColumnCount = 2
    $rootLayout.RowCount = 1
    [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 42)))
    [void]$rootLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 58)))
    $form.Controls.Add($rootLayout)

    $left = New-Object System.Windows.Forms.TableLayoutPanel
    $left.Dock = 'Fill'
    $left.RowCount = 5
    $left.ColumnCount = 1
    $left.Padding = New-Object System.Windows.Forms.Padding(12)
    $left.AutoScroll = $true
    [void]$rootLayout.Controls.Add($left, 0, 0)

    $right = New-Object System.Windows.Forms.TableLayoutPanel
    $right.Dock = 'Fill'
    $right.RowCount = 5
    $right.ColumnCount = 1
    $right.Padding = New-Object System.Windows.Forms.Padding(12)
    $right.AutoScroll = $true
    [void]$rootLayout.Controls.Add($right, 1, 0)

    function Add-Group {
        param($Parent, [string]$Text, [int]$Height)
        $group = New-Object System.Windows.Forms.GroupBox
        $group.Text = $Text
        $group.Dock = 'Top'
        $group.Height = $Height
        $group.Padding = New-Object System.Windows.Forms.Padding(12)
        [void]$Parent.Controls.Add($group)
        return $group
    }

    $folderGroup = Add-Group $left 'Výber priečinka' 120
    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Anchor = 'Left,Top,Right'
    $pathBox.Left = 14; $pathBox.Top = 28; $pathBox.Width = 330
    $folderGroup.Controls.Add($pathBox)
    $choose = New-Object System.Windows.Forms.Button
    $choose.Text = 'Vybrať priečinok makléra'
    $choose.Anchor = 'Top,Right'
    $choose.Left = 355; $choose.Top = 26; $choose.Width = 170
    $folderGroup.Controls.Add($choose)
    $reload = New-Object System.Windows.Forms.Button
    $reload.Text = 'Načítať a skontrolovať'
    $reload.Left = 14; $reload.Top = 62; $reload.Width = 170
    $folderGroup.Controls.Add($reload)

    $stateGroup = Add-Group $left 'Stav vstupných súborov' 145
    $stateLabel = New-Object System.Windows.Forms.Label
    $stateLabel.Dock = 'Fill'
    $stateLabel.Text = 'Vyberte priečinok s presne jedným VCF súborom a jednou fotografiou.'
    $stateLabel.AutoSize = $false
    $stateGroup.Controls.Add($stateLabel)

    $photoGroup = Add-Group $left 'Fotografia' 300
    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Width = 210; $picture.Height = 210; $picture.Left = 18; $picture.Top = 28
    $picture.SizeMode = 'Zoom'
    $picture.BorderStyle = 'FixedSingle'
    $photoGroup.Controls.Add($picture)
    $photoPreview = New-Object System.Windows.Forms.Panel
    $photoPreview.Left = 245; $photoPreview.Top = 30; $photoPreview.Width = 124; $photoPreview.Height = 124
    $photoPreview.BackColor = [System.Drawing.Color]::FromArgb(8, 35, 59)
    $toolTip.SetToolTip($photoPreview, 'Živý kruhový náhľad výrezu použitého na webovej vizitke.')
    $photoGroup.Controls.Add($photoPreview)
    $photoInfo = New-Object System.Windows.Forms.Label
    $photoInfo.Left = 385; $photoInfo.Top = 30; $photoInfo.Width = 180; $photoInfo.Height = 220
    $photoGroup.Controls.Add($photoInfo)

    $urlGroup = Add-Group $left 'URL a výstup' 170
    $slugLabel = New-Object System.Windows.Forms.Label
    $slugLabel.Left = 14; $slugLabel.Top = 30; $slugLabel.Width = 500; $slugLabel.Height = 28
    $urlGroup.Controls.Add($slugLabel)
    $publicUrlLabel = New-Object System.Windows.Forms.Label
    $publicUrlLabel.Left = 14; $publicUrlLabel.Top = 62; $publicUrlLabel.Width = 500; $publicUrlLabel.Height = 48
    $urlGroup.Controls.Add($publicUrlLabel)
    $localPreview = New-Object System.Windows.Forms.Button
    $localPreview.Text = 'Otvoriť lokálny náhľad'
    $localPreview.Left = 14; $localPreview.Top = 115; $localPreview.Width = 170
    $localPreview.Enabled = $false
    $urlGroup.Controls.Add($localPreview)
    $publicPreview = New-Object System.Windows.Forms.Button
    $publicPreview.Text = 'Otvoriť verejnú vizitku'
    $publicPreview.Left = 200; $publicPreview.Top = 115; $publicPreview.Width = 170
    $publicPreview.Enabled = $false
    $urlGroup.Controls.Add($publicPreview)

    $fields = [ordered]@{}
    $fieldMeta = @(
        @('firstName', 'Meno *', 'Krstné meno makléra.'),
        @('lastName', 'Priezvisko *', 'Priezvisko makléra.'),
        @('displayName', 'Zobrazované meno *', 'Meno zobrazené na vizitke.'),
        @('title', 'Pracovná pozícia *', 'Napríklad Realitný maklér.'),
        @('company', 'Spoločnosť *', 'Firemný názov.'),
        @('phoneDisplay', 'Telefón - zobrazenie', 'Čitateľný zápis telefónu.'),
        @('phoneE164', 'Telefón - medzinárodný formát *', 'Formát +421904882685.'),
        @('email', 'E-mail *', 'Pracovný e-mail.'),
        @('website', 'Web *', 'HTTPS adresa webu.'),
        @('whatsapp', 'WhatsApp *', 'HTTPS adresa wa.me podľa telefónu.')
    )
    $contactGroup = Add-Group $right 'Kontaktné údaje' 395
    $top = 28
    foreach ($meta in $fieldMeta) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $meta[1]
        $label.Left = 14; $label.Top = $top + 4; $label.Width = 210
        $contactGroup.Controls.Add($label)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Left = 230; $box.Top = $top; $box.Width = 440; $box.Anchor = 'Left,Top,Right'
        $contactGroup.Controls.Add($box)
        $toolTip.SetToolTip($box, $meta[2])
        $fields[$meta[0]] = $box
        $top += 34
    }

    $socialGroup = Add-Group $right 'Sociálne siete' 118
    foreach ($meta in @(
        @('facebook', 'Facebook', 'Oficiálny firemný Facebook.'),
        @('instagram', 'Instagram', 'Oficiálny firemný Instagram.')
    )) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $meta[1]
        $label.Left = 14; $label.Top = 28 + (($fields.Count - 10) * 34); $label.Width = 120
        $socialGroup.Controls.Add($label)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Left = 135; $box.Top = $label.Top - 4; $box.Width = 535; $box.Anchor = 'Left,Top,Right'
        $socialGroup.Controls.Add($box)
        $toolTip.SetToolTip($box, $meta[2])
        $fields[$meta[0]] = $box
    }

    $settingsGroup = Add-Group $right 'Nastavenie fotografie' 220
    foreach ($meta in @(
        @('slug', 'URL identifikátor *', 'Časť adresy bez diakritiky, napríklad jakub-svec.'),
        @('photoPosition', 'Pozícia fotografie *', 'CSS pozícia výrezu, napríklad 50% 50%.')
    )) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $meta[1]
        $label.Left = 14; $label.Top = 28 + (($fields.Count - 12) * 34); $label.Width = 165
        $settingsGroup.Controls.Add($label)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Left = 185; $box.Top = $label.Top - 4; $box.Width = 485; $box.Anchor = 'Left,Top,Right'
        $settingsGroup.Controls.Add($box)
        $toolTip.SetToolTip($box, $meta[2])
        $fields[$meta[0]] = $box
    }

    $photoXLabel = New-Object System.Windows.Forms.Label
    $photoXLabel.Text = 'Horizontálne: 50%'
    $photoXLabel.Left = 14; $photoXLabel.Top = 100; $photoXLabel.Width = 165
    $settingsGroup.Controls.Add($photoXLabel)
    $photoXTrack = New-Object System.Windows.Forms.TrackBar
    $photoXTrack.Left = 185; $photoXTrack.Top = 92; $photoXTrack.Width = 485; $photoXTrack.Minimum = 0; $photoXTrack.Maximum = 100; $photoXTrack.TickFrequency = 10; $photoXTrack.Value = 50
    $toolTip.SetToolTip($photoXTrack, 'Posun výrezu fotografie doľava alebo doprava.')
    $settingsGroup.Controls.Add($photoXTrack)

    $photoYLabel = New-Object System.Windows.Forms.Label
    $photoYLabel.Text = 'Vertikálne: 50%'
    $photoYLabel.Left = 14; $photoYLabel.Top = 155; $photoYLabel.Width = 165
    $settingsGroup.Controls.Add($photoYLabel)
    $photoYTrack = New-Object System.Windows.Forms.TrackBar
    $photoYTrack.Left = 185; $photoYTrack.Top = 147; $photoYTrack.Width = 485; $photoYTrack.Minimum = 0; $photoYTrack.Maximum = 100; $photoYTrack.TickFrequency = 10; $photoYTrack.Value = 50
    $toolTip.SetToolTip($photoYTrack, 'Posun výrezu fotografie hore alebo dole.')
    $settingsGroup.Controls.Add($photoYTrack)

    $publishGroup = Add-Group $right 'Publikovanie' 170
    $generateLocal = New-Object System.Windows.Forms.Button
    $generateLocal.Text = 'Vygenerovať lokálne'
    $generateLocal.Left = 14; $generateLocal.Top = 28; $generateLocal.Width = 170
    $generateLocal.Enabled = $false
    $publishGroup.Controls.Add($generateLocal)
    $generatePublish = New-Object System.Windows.Forms.Button
    $generatePublish.Text = 'Vygenerovať a publikovať'
    $generatePublish.Left = 200; $generatePublish.Top = 28; $generatePublish.Width = 190
    $generatePublish.Enabled = $false
    $publishGroup.Controls.Add($generatePublish)
    $openLog = New-Object System.Windows.Forms.Button
    $openLog.Text = 'Otvoriť log'
    $openLog.Left = 405; $openLog.Top = 28; $openLog.Width = 110
    $publishGroup.Controls.Add($openLog)
    $openOutput = New-Object System.Windows.Forms.Button
    $openOutput.Text = 'Otvoriť priečinok výstupu'
    $openOutput.Left = 530; $openOutput.Top = 28; $openOutput.Width = 160
    $publishGroup.Controls.Add($openOutput)
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Left = 14; $progress.Top = 72; $progress.Width = 675; $progress.Style = 'Continuous'
    $publishGroup.Controls.Add($progress)
    $status = New-Object System.Windows.Forms.Label
    $status.Left = 14; $status.Top = 105; $status.Width = 675; $status.Height = 50
    $status.Text = "Pripravené. Log: $LogFile"
    $publishGroup.Controls.Add($status)

    function Convert-PhotoPositionToPercent {
        param([string]$Value)
        $x = 50
        $y = 50
        $parts = @(([string]$Value).Trim() -split '\s+' | Where-Object { $_ })
        if ($parts.Count -ge 1 -and $parts[0] -match '^([0-9]{1,3})%$') { $x = [Math]::Min(100, [Math]::Max(0, [int]$Matches[1])) }
        if ($parts.Count -ge 2 -and $parts[1] -match '^([0-9]{1,3})%$') { $y = [Math]::Min(100, [Math]::Max(0, [int]$Matches[1])) }
        return [pscustomobject]@{ X = $x; Y = $y }
    }

    function Set-PhotoPositionControls {
        param([string]$Value)
        $position = Convert-PhotoPositionToPercent $Value
        $photoXTrack.Value = $position.X
        $photoYTrack.Value = $position.Y
        $photoXLabel.Text = "Horizontálne: $($position.X)%"
        $photoYLabel.Text = "Vertikálne: $($position.Y)%"
        $photoPreview.Invalidate()
    }

    function Update-PhotoPositionFromSliders {
        $fields['photoPosition'].Text = "$($photoXTrack.Value)% $($photoYTrack.Value)%"
        Set-PhotoPositionControls $fields['photoPosition'].Text
    }

    function Paint-CircularPhotoPreview {
        param($Sender, $EventArgs)
        $graphics = $EventArgs.Graphics
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear($photoPreview.BackColor)
        $image = $picture.Image
        if (-not $image) { return }

        $diameter = [Math]::Min($Sender.ClientSize.Width, $Sender.ClientSize.Height) - 4
        if ($diameter -le 0) { return }
        $target = New-Object System.Drawing.Rectangle 2, 2, $diameter, $diameter
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $path.AddEllipse($target)
        $oldClip = $graphics.Clip
        $graphics.SetClip($path)

        $scale = [Math]::Max($diameter / $image.Width, $diameter / $image.Height)
        $drawWidth = $image.Width * $scale
        $drawHeight = $image.Height * $scale
        $position = Convert-PhotoPositionToPercent $fields['photoPosition'].Text
        $offsetX = $target.Left + (($diameter - $drawWidth) * ($position.X / 100.0))
        $offsetY = $target.Top + (($diameter - $drawHeight) * ($position.Y / 100.0))
        $destination = [System.Drawing.RectangleF]::new([single]$offsetX, [single]$offsetY, [single]$drawWidth, [single]$drawHeight)
        $graphics.DrawImage($image, $destination)
        $graphics.Clip = $oldClip
        $path.Dispose()

        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(53, 214, 199), 3)
        $graphics.DrawEllipse($pen, $target)
        $pen.Dispose()
    }

    $photoPreview.Add_Paint({ param($sender, $eventArgs) Paint-CircularPhotoPreview $sender $eventArgs })
    $photoXTrack.Add_Scroll({ Update-PhotoPositionFromSliders })
    $photoYTrack.Add_Scroll({ Update-PhotoPositionFromSliders })

    function Set-UiBusy {
        param([bool]$Busy)
        foreach ($control in @($choose, $reload, $generateLocal, $generatePublish, $localPreview, $publicPreview)) { $control.Enabled = (-not $Busy) }
        if (-not $script:LastBrokerInfo) {
            $generateLocal.Enabled = $false; $generatePublish.Enabled = $false; $localPreview.Enabled = $false; $publicPreview.Enabled = $false
        }
        if ($Busy) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; $progress.Style = 'Marquee' }
        else { $form.Cursor = [System.Windows.Forms.Cursors]::Default; $progress.Style = 'Continuous'; $progress.Value = 0 }
    }

    function Update-Validation {
        foreach ($box in $fields.Values) { $box.BackColor = [System.Drawing.SystemColors]::Window }
        if (-not $script:LastBrokerInfo) {
            $generateLocal.Enabled = $false
            $generatePublish.Enabled = $false
            return
        }
        $broker = Convert-FieldsToBroker $fields
        $errors = @(Test-FieldValues $broker)
        $ok = $errors.Count -eq 0 -and (Test-Path -LiteralPath $script:LastBrokerInfo.vcf) -and (Test-Path -LiteralPath $script:LastBrokerInfo.photo)
        $generateLocal.Enabled = $ok
        $generatePublish.Enabled = $ok
        $localPreview.Enabled = [bool]$broker.slug
        $publicPreview.Enabled = [bool]$broker.slug
        if (-not $ok -and $errors.Count -gt 0) { $status.Text = 'FAIL ' + ($errors[0]) }
    }

    foreach ($box in $fields.Values) {
        $box.Add_TextChanged({
            param($sender, $eventArgs)
            if (-not $script:IsLoadingBroker) {
                if ($sender -eq $fields['photoPosition']) {
                    Set-PhotoPositionControls $fields['photoPosition'].Text
                }
                Update-Validation
            }
        })
    }

    function Load-BrokerIntoForm {
        param([string]$Folder)
        $status.Text = 'Načítavam makléra...'
        $script:IsLoadingBroker = $true
        try {
            $info = Get-BrokerInfo $Folder
            $script:LastBrokerInfo = $info
            $pathBox.Text = $info.folder
            $fields['firstName'].Text = [string]$info.broker.firstName
            $fields['lastName'].Text = [string]$info.broker.lastName
            $fields['displayName'].Text = [string]$info.broker.displayName
            $fields['title'].Text = [string]$info.broker.title
            $fields['company'].Text = [string]$info.broker.company
            $fields['phoneDisplay'].Text = [string]$info.broker.phoneDisplay
            $fields['phoneE164'].Text = [string]$info.broker.phoneE164
            $fields['email'].Text = [string]$info.broker.email
            $fields['website'].Text = [string]$info.broker.website
            $fields['whatsapp'].Text = [string]$info.broker.whatsapp
            $fields['facebook'].Text = [string]$info.broker.social.facebook
            $fields['instagram'].Text = [string]$info.broker.social.instagram
            $fields['slug'].Text = [string]$info.broker.slug
            $fields['photoPosition'].Text = [string]$info.broker.photoPosition
            Set-PhotoPositionControls $fields['photoPosition'].Text

            $image = Get-ImageCopy $info.photo
            if ($picture.Image) {
                $picture.Image.Dispose()
                $picture.Image = $null
            }
            $picture.Image = $image
            $photoPreview.Invalidate()
            $stateLabel.Text = "PASS Vstup načítaný.`nVCF: $([System.IO.Path]::GetFileName($info.vcf))`nFotografia: $([System.IO.Path]::GetFileName($info.photo))"
            $photoInfo.Text = "Súbor: $([System.IO.Path]::GetFileName($info.photo))`nRozmery: $($image.Width)x$($image.Height)`nVýrez: $($fields['photoPosition'].Text)`nKruhový náhľad používa rovnaké centrovanie ako web."
            $slugLabel.Text = "Slug: $($info.broker.slug)"
            $publicUrlLabel.Text = "Verejná URL: https://kvraniak29-blip.github.io/wfm-digital-cards/$($info.broker.slug)/"
            $status.Text = 'PASS Načítané. Skontrolujte údaje alebo generujte.'
        }
        finally {
            $script:IsLoadingBroker = $false
        }
        Update-Validation
    }

    $choose.Add_Click({
        try {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = 'Vyberte priečinok jedného makléra'
            $initial = $ProjectRoot
            if ($pathBox.Text -and (Test-Path -LiteralPath $pathBox.Text -PathType Container)) { $initial = $pathBox.Text }
            $dialog.SelectedPath = $initial
            if ($dialog.ShowDialog() -eq 'OK') { Load-BrokerIntoForm $dialog.SelectedPath }
        } catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
            Update-Validation
        }
    })

    $reload.Add_Click({
        try { Load-BrokerIntoForm $pathBox.Text }
        catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
            Update-Validation
        }
    })

    function Start-GenerateWorker {
        param([bool]$DoPublish)
        if (-not $script:LastBrokerInfo) { return }
        $broker = Convert-FieldsToBroker $fields
        $errors = @(Test-FieldValues $broker)
        if ($errors.Count -gt 0) {
            $status.Text = 'FAIL ' + ($errors -join ' ')
            return
        }
        if ($DoPublish) {
            $message = "Maklér: $($broker.displayName)`nSlug: $($broker.slug)`nRepozitár: kvraniak29-blip/wfm-digital-cards`n`nPublikovanie prebehne bezpečne cez izolovanú vetvu z origin/main.`n`nPokračovať v publikovaní?"
            $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Potvrdenie publikovania', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }

        try {
            Write-SourceBrokerJson -Folder $pathBox.Text -Broker $broker | Out-Null
            $script:GenerationOverrideFile = Write-BrokerOverride $broker
            $script:GenerationResultFile = Join-Path $LogsDir ("generation-result-{0}-{1}.json" -f $broker.slug, (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
            $powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
            $scriptFile = Join-Path $ProjectRoot 'tools\WFM-Card-Generator.ps1'
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $scriptFile,
                '-BrokerFolder', $pathBox.Text,
                '-OverrideFile', $script:GenerationOverrideFile,
                '-ResultFile', $script:GenerationResultFile,
                '-Generate',
                '-Silent'
            )
            if ($DoPublish) { $arguments += '-Publish' }
            if ($script:GuiSelfTestSkipImportTests) { $arguments += '-SkipImportTests' }

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $powerShell
            $psi.Arguments = Join-ProcessArguments $arguments
            $psi.WorkingDirectory = $ProjectRoot
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $psi

            $timer = New-Object System.Windows.Forms.Timer
            $timer.Interval = 250
            $timer.add_Tick({
                if (-not $script:GenerationProcess) { return }
                if (-not $script:GenerationProcess.HasExited) { return }

                $script:GenerationTimer.Stop()
                Set-UiBusy $false
                try {
                    $exitCode = $script:GenerationProcess.ExitCode
                    $result = $null
                    if ($script:GenerationResultFile -and (Test-Path -LiteralPath $script:GenerationResultFile -PathType Leaf)) {
                        $result = Get-Content -LiteralPath $script:GenerationResultFile -Raw -Encoding UTF8 | ConvertFrom-Json
                    }

                    if (-not $result) {
                        $status.Text = "FAIL Generovanie skončilo bez ResultFile. ExitCode=$exitCode`nLog: $LogFile"
                        Write-Log $status.Text
                        return
                    }

                    if ($exitCode -ne 0 -or $result.status -ne 'PASS') {
                        $status.Text = Format-ResultFailureForGui $result
                        Write-Log $status.Text
                        return
                    }

                    $status.Text = "PASS $($result.message)"
                    if ($result.published -and $result.publicUrl) {
                        $stateLabel.Text = "PASS Vizitka bola publikovaná.`nURL: $($result.publicUrl)"
                    } else {
                        $stateLabel.Text = 'PASS Výstup bol úspešne vytvorený.'
                    }
                    if ($script:GenerationOverrideFile -and (Test-Path -LiteralPath $script:GenerationOverrideFile)) {
                        Remove-Item -LiteralPath $script:GenerationOverrideFile -Force
                    }
                    if ($script:GenerationResultFile -and (Test-Path -LiteralPath $script:GenerationResultFile)) {
                        Remove-Item -LiteralPath $script:GenerationResultFile -Force
                    }
                    Update-Validation
                } catch {
                    $status.Text = "FAIL $($_.Exception.Message)"
                    Write-Log $status.Text
                    Update-Validation
                } finally {
                    if ($script:GenerationProcess) {
                        $script:GenerationProcess.Dispose()
                        $script:GenerationProcess = $null
                    }
                    if ($script:GenerationTimer) {
                        $script:GenerationTimer.Dispose()
                        $script:GenerationTimer = $null
                    }
                    $script:GenerationOverrideFile = $null
                    $script:GenerationResultFile = $null
                    $script:CurrentPublishMode = $false
                }
            })

            $script:GenerationProcess = $process
            $script:GenerationTimer = $timer
            $script:CurrentPublishMode = $DoPublish
            $status.Text = if ($DoPublish) { 'Generujem a publikujem cez izolovaný worktree...' } else { 'Generujem lokálne...' }
            Set-UiBusy $true
            if (-not $process.Start()) { throw 'Generovanie sa nepodarilo spustiť.' }
            $timer.Start()
        } catch {
            Set-UiBusy $false
            if ($script:GenerationProcess) {
                $script:GenerationProcess.Dispose()
                $script:GenerationProcess = $null
            }
            if ($script:GenerationTimer) {
                $script:GenerationTimer.Dispose()
                $script:GenerationTimer = $null
            }
            $script:CurrentPublishMode = $false
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
            Update-Validation
        }
    }

    $generateLocal.Add_Click({ Start-GenerateWorker $false })
    $generatePublish.Add_Click({ Start-GenerateWorker $true })
    $localPreview.Add_Click({
        try {
            $url = Start-LocalPreview $fields['slug'].Text
            $status.Text = "PASS Lokálny náhľad: $url"
        } catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
        }
    })
    $publicPreview.Add_Click({
        try {
            $slug = $fields['slug'].Text.Trim()
            if (-not $slug) { return }
            $check = Test-PublicUrlAvailable -Slug $slug
            if ($check.StatusCode -eq 200) {
                Start-Process $check.Url
                $status.Text = Get-PublicPreviewMessage -StatusCode $check.StatusCode -Url $check.Url
            } else {
                $status.Text = Get-PublicPreviewMessage -StatusCode $check.StatusCode -Url $check.Url
            }
        } catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
        }
    })
    $openLog.Add_Click({ if (Test-Path -LiteralPath $LogFile) { Start-Process $LogFile } })
    $openOutput.Add_Click({ if (Test-Path -LiteralPath $script:LastOutputFolder) { Start-Process $script:LastOutputFolder } })
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:GenerationProcess -and -not $script:GenerationProcess.HasExited) {
            $answer = [System.Windows.Forms.MessageBox]::Show('Generovanie ešte beží. Chcete ukončiť proces generovania?', 'Generovanie beží', 'YesNo', 'Warning')
            if ($answer -eq 'Yes') {
                try { $script:GenerationProcess.Kill() } catch {}
            } else {
                $eventArgs.Cancel = $true
                return
            }
        }
        if ($script:PreviewServerProcess -and -not $script:PreviewServerProcess.HasExited) {
            try { $script:PreviewServerProcess.Kill() } catch {}
        }
    })

    if ($GuiLoadSelfTest) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný pre -GuiLoadSelfTest." }
        Load-BrokerIntoForm $BrokerFolder
        if (-not $picture.Image) { throw 'GUI self-test: fotografia nie je načítaná v PictureBox.Image.' }
        if ($picture.Image.Width -le 0 -or $picture.Image.Height -le 0) { throw "GUI self-test: fotografia má neplatné rozmery $($picture.Image.Width)x$($picture.Image.Height)." }
        if (-not $generateLocal.Enabled) { throw 'GUI self-test: tlačidlo Vygenerovať lokálne nie je aktívne.' }
        $sourcePhoto = $script:LastBrokerInfo.photo
        $lockStream = [System.IO.File]::Open((Resolve-Path $sourcePhoto).Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $lockStream.Dispose()
        Write-Log "PASS GuiLoadSelfTest slug=$($fields['slug'].Text) photo=$($picture.Image.Width)x$($picture.Image.Height) generateLocalEnabled=$($generateLocal.Enabled)"
        if (-not $Silent) { Write-Host "PASS GuiLoadSelfTest slug=$($fields['slug'].Text) photo=$($picture.Image.Width)x$($picture.Image.Height) generateLocalEnabled=$($generateLocal.Enabled)" }
        if ($picture.Image) {
            $picture.Image.Dispose()
            $picture.Image = $null
        }
        $form.Dispose()
        return
    }

    if ($GuiGenerateSelfTest) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný pre -GuiGenerateSelfTest." }
        $script:GuiSelfTestSkipImportTests = $true
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Load-BrokerIntoForm $BrokerFolder
        if (-not $picture.Image) { throw 'GUI generate self-test: fotografia nie je načítaná.' }
        if (-not $generateLocal.Enabled) { throw 'GUI generate self-test: tlačidlo Vygenerovať lokálne nie je aktívne pred klikom.' }
        $generateLocal.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $deadline = (Get-Date).AddSeconds(90)
        while ($script:GenerationProcess -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:GenerationProcess) { throw 'GUI generate self-test: generovanie neskončilo v časovom limite.' }
        if ($status.Text -ne 'PASS Lokálne generovanie bolo dokončené.') { throw "GUI generate self-test: neočakávaný stav: $($status.Text)" }
        if ($progress.Style -ne 'Continuous') { throw "GUI generate self-test: progress bar zostal v stave $($progress.Style)." }
        if (-not $generateLocal.Enabled) { throw 'GUI generate self-test: tlačidlo Vygenerovať lokálne nie je po dokončení aktívne.' }
        Write-Log "PASS GuiGenerateSelfTest slug=$($fields['slug'].Text) status=$($status.Text)"
        if (-not $Silent) { Write-Host "PASS GuiGenerateSelfTest slug=$($fields['slug'].Text) status=$($status.Text)" }
        if ($picture.Image) {
            $picture.Image.Dispose()
            $picture.Image = $null
        }
        $form.Dispose()
        return
    }

    if ($GuiPhotoPositionSelfTest) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný pre -GuiPhotoPositionSelfTest." }
        $script:GuiSelfTestSkipImportTests = $true
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        Load-BrokerIntoForm $BrokerFolder
        if (-not $picture.Image) { throw 'GUI photo-position self-test: fotografia nie je načítaná.' }
        if (-not $photoPreview.Visible) { throw 'GUI photo-position self-test: kruhový náhľad nie je viditeľný.' }

        $photoXTrack.Value = 50
        $photoYTrack.Value = 38
        Update-PhotoPositionFromSliders
        [System.Windows.Forms.Application]::DoEvents()
        if ($fields['photoPosition'].Text -ne '50% 38%') { throw "GUI photo-position self-test: očakávaná pozícia 50% 38%, aktuálne $($fields['photoPosition'].Text)" }
        if ($photoXLabel.Text -ne 'Horizontálne: 50%') { throw "GUI photo-position self-test: neočakávaný X label $($photoXLabel.Text)" }
        if ($photoYLabel.Text -ne 'Vertikálne: 38%') { throw "GUI photo-position self-test: neočakávaný Y label $($photoYLabel.Text)" }

        $generateLocal.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $deadline = (Get-Date).AddSeconds(90)
        while ($script:GenerationProcess -and (Get-Date) -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:GenerationProcess) { throw 'GUI photo-position self-test: generovanie neskončilo v časovom limite.' }
        if ($status.Text -ne 'PASS Lokálne generovanie bolo dokončené.') { throw "GUI photo-position self-test: neočakávaný stav: $($status.Text)" }

        $sourceBroker = Get-Content -LiteralPath (Join-Path $BrokerFolder 'broker.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($sourceBroker.photoPosition -ne '50% 38%') { throw "GUI photo-position self-test: zdrojový broker.json má $($sourceBroker.photoPosition)" }
        $canonical = Get-Content -LiteralPath (Join-Path $ProjectRoot "data\brokers\$($sourceBroker.slug).json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($canonical.photoPosition -ne '50% 38%') { throw "GUI photo-position self-test: kanonický JSON má $($canonical.photoPosition)" }

        Load-BrokerIntoForm $BrokerFolder
        if ($fields['photoPosition'].Text -ne '50% 38%') { throw "GUI photo-position self-test: reload vrátil $($fields['photoPosition'].Text)" }
        if ($photoYTrack.Value -ne 38) { throw "GUI photo-position self-test: reload slider Y vrátil $($photoYTrack.Value)" }
        Write-Log "PASS GuiPhotoPositionSelfTest slug=$($fields['slug'].Text) photoPosition=$($fields['photoPosition'].Text)"
        if (-not $Silent) { Write-Host "PASS GuiPhotoPositionSelfTest slug=$($fields['slug'].Text) photoPosition=$($fields['photoPosition'].Text)" }
        if ($picture.Image) {
            $picture.Image.Dispose()
            $picture.Image = $null
        }
        $form.Dispose()
        return
    }

    [void]$form.ShowDialog()
}

function Invoke-ValidationSelfTest {
    $validBroker = [pscustomobject]@{
        firstName = 'Kristián'
        lastName = 'Vraniak'
        displayName = 'Kristián Vraniak'
        title = 'Realitný maklér'
        company = 'WFM Reality'
        phoneDisplay = '+421 948 104 075'
        phoneE164 = '+421948104075'
        email = 'kristian.vraniak@wfmreality.sk'
        website = 'https://www.wfmreality.sk/'
        whatsapp = 'https://wa.me/421948104075'
        facebook = 'https://www.facebook.com/WFMReality/'
        instagram = 'https://www.instagram.com/wfmreality.sk/'
        slug = 'kristian-vraniak'
        photoPosition = '50% 42%'
    }
    $validErrors = @(Test-FieldValues $validBroker)
    if ($null -eq $validErrors) { throw 'Validácia platného makléra vrátila $null.' }
    if ($validErrors.Count -ne 0) { throw "Platný maklér má chyby: $($validErrors -join '; ')" }

    $invalidBroker = [pscustomobject]@{
        firstName = ''
        lastName = ''
        displayName = ''
        title = ''
        company = ''
        phoneDisplay = ''
        phoneE164 = '0900'
        email = 'neplatny-email'
        website = 'http://example.com'
        whatsapp = 'https://wa.me/000'
        facebook = 'http://facebook.example'
        instagram = 'not-url'
        slug = 'Neplatný Slug'
        photoPosition = 'bad value now'
    }
    $invalidErrors = @(Test-FieldValues $invalidBroker)
    if ($null -eq $invalidErrors) { throw 'Validácia neplatného makléra vrátila $null.' }
    if ($invalidErrors.Count -le 0) { throw 'Neplatný maklér nevrátil žiadne chyby.' }

    Write-Log "PASS ValidationSelfTest validCount=$($validErrors.Count) invalidCount=$($invalidErrors.Count)"
    if (-not $Silent) { Write-Host "PASS ValidationSelfTest validCount=$($validErrors.Count) invalidCount=$($invalidErrors.Count)" }
}

function Invoke-BrokerLoadSelfTest {
    param([Parameter(Mandatory)][string]$Folder)

    Add-Type -AssemblyName System.Drawing
    $info = Get-BrokerInfo $Folder
    $broker = [pscustomobject]@{
        firstName = [string]$info.broker.firstName
        lastName = [string]$info.broker.lastName
        displayName = [string]$info.broker.displayName
        title = [string]$info.broker.title
        company = [string]$info.broker.company
        phoneDisplay = [string]$info.broker.phoneDisplay
        phoneE164 = [string]$info.broker.phoneE164
        email = [string]$info.broker.email
        website = [string]$info.broker.website
        whatsapp = [string]$info.broker.whatsapp
        facebook = [string]$info.broker.social.facebook
        instagram = [string]$info.broker.social.instagram
        slug = [string]$info.broker.slug
        photoPosition = [string]$info.broker.photoPosition
    }
    $errors = @(Test-FieldValues $broker)
    if ($errors.Count -gt 0) { throw "Načítaný maklér má validačné chyby: $($errors -join '; ')" }

    $image = Get-ImageCopy $info.photo
    try {
        if ($image.Width -le 0 -or $image.Height -le 0) { throw "Fotografia má neplatné rozmery: $($image.Width)x$($image.Height)" }
        Write-Log "PASS BrokerLoadSelfTest slug=$($broker.slug) photo=$($image.Width)x$($image.Height)"
        if (-not $Silent) { Write-Host "PASS BrokerLoadSelfTest slug=$($broker.slug) photo=$($image.Width)x$($image.Height)" }
    } finally {
        $image.Dispose()
    }
}

function Invoke-PublishPlanSelfTest {
    $plan = Get-PublishPlan 'stanislav-penxa'
    $expected = @(
        'data/brokers/stanislav-penxa.json',
        'data/status/stanislav-penxa.json',
        'assets/brokers/stanislav-penxa/photo.jpg'
    )
    if ($plan.allowedPaths.Count -ne 3) { throw "Publish plan má neočakávaný počet ciest: $($plan.allowedPaths.Count)" }
    foreach ($path in $expected) {
        if ($plan.allowedPaths -notcontains $path) { throw "Publish plan neobsahuje očakávanú cestu: $path" }
    }
    foreach ($path in $plan.allowedPaths) {
        if ($path -match 'dist/|logs/|work/|node_modules|Makléri') { throw "Publish plan obsahuje nepovolenú cestu: $path" }
    }
    Write-Log "PASS PublishPlanSelfTest slug=$($plan.slug) paths=$($plan.allowedPaths -join ',')"
    if (-not $Silent) { Write-Host "PASS PublishPlanSelfTest slug=$($plan.slug)" }
}

function Invoke-PublicPreview404SelfTest {
    $message = Get-PublicPreviewMessage -StatusCode 404 -Url 'https://example.invalid/wfm-test/'
    if ($message -ne 'Vizitka zatiaľ nie je publikovaná.') { throw "Neoèakávaná 404 správa: $message" }
    $ok = Get-PublicPreviewMessage -StatusCode 200 -Url 'https://example.invalid/wfm-test/'
    if ($ok -notmatch '^PASS Verejná vizitka:') { throw "Neoèakávaná 200 správa: $ok" }
    Write-Log 'PASS PublicPreview404SelfTest'
    if (-not $Silent) { Write-Host 'PASS PublicPreview404SelfTest' }
}

function Invoke-PublishWorktreeIsolationSelfTest {
    $slug = 'wfm-test-publish-isolation'
    $base = Join-Path $ProjectRoot ("work\tests\publish-isolation-{0}" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
    $remote = Join-Path $base 'remote.git'
    $repo = Join-Path $base 'repo'
    $wt = Join-Path $base 'publish-worktree'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    try {
        Invoke-CommandInDirectory $base 'git.exe' @('init', '--bare', $remote) | Out-Null
        Invoke-CommandInDirectory $base 'git.exe' @('init', $repo) | Out-Null
        Invoke-CommandInDirectory $repo 'git.exe' @('config', 'user.email', 'test@example.com') | Out-Null
        Invoke-CommandInDirectory $repo 'git.exe' @('config', 'user.name', 'WFM Test') | Out-Null
        Set-Content -LiteralPath (Join-Path $repo 'README.md') -Value "test repo" -Encoding UTF8
        Invoke-CommandInDirectory $repo 'git.exe' @('add', 'README.md') | Out-Null
        Invoke-CommandInDirectory $repo 'git.exe' @('commit', '-m', 'Initial') | Out-Null
        Invoke-CommandInDirectory $repo 'git.exe' @('branch', '-M', 'main') | Out-Null
        Invoke-CommandInDirectory $repo 'git.exe' @('remote', 'add', 'origin', $remote) | Out-Null

        $allowed = @(
            "data\brokers\$slug.json",
            "data\status\$slug.json",
            "assets\brokers\$slug\photo.jpg"
        )
        foreach ($relative in $allowed) {
            $file = Join-Path $repo $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
            if ($relative -like '*.jpg') {
                [System.IO.File]::WriteAllBytes($file, [byte[]](0xFF,0xD8,0xFF,0xD9))
            } else {
                Set-Content -LiteralPath $file -Value "{}" -Encoding UTF8
            }
        }
        Set-Content -LiteralPath (Join-Path $repo 'unrelated.txt') -Value 'staged user file' -Encoding UTF8
        Invoke-CommandInDirectory $repo 'git.exe' @('add', 'unrelated.txt') | Out-Null
        $before = Invoke-CommandInDirectory $repo 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1')

        Invoke-CommandInDirectory $repo 'git.exe' @('worktree', 'add', '--detach', $wt, 'HEAD') | Out-Null
        Invoke-CommandInDirectory $wt 'git.exe' @('switch', '-c', "publish/$slug-test") | Out-Null
        foreach ($relative in $allowed) {
            $source = Join-Path $repo $relative
            $destination = Join-Path $wt $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
        Assert-PublishPathsOnly -RepoRoot $wt -Slug $slug
        Invoke-CommandInDirectory $wt 'git.exe' @('add', '--', "data/brokers/$slug.json", "data/status/$slug.json", "assets/brokers/$slug/photo.jpg") | Out-Null
        Invoke-CommandInDirectory $wt 'git.exe' @('config', 'user.email', 'test@example.com') | Out-Null
        Invoke-CommandInDirectory $wt 'git.exe' @('config', 'user.name', 'WFM Test') | Out-Null
        Invoke-CommandInDirectory $wt 'git.exe' @('commit', '-m', "Publish Test digital card") | Out-Null
        $committed = Invoke-CommandInDirectory $wt 'git.exe' @('show', '--name-only', '--pretty=format:', 'HEAD')
        foreach ($relative in @("data/brokers/$slug.json", "data/status/$slug.json", "assets/brokers/$slug/photo.jpg")) {
            if ($committed -notmatch [regex]::Escape($relative)) { throw "Commit neobsahuje očakávanú cestu: $relative" }
        }
        if ($committed -match 'unrelated|dist/|logs/|work/|node_modules') { throw "Commit obsahuje nepovolenú cestu: $committed" }
        $after = Invoke-CommandInDirectory $repo 'git.exe' @('-c', 'core.quotepath=false', 'status', '--porcelain=v1')
        if ($before -ne $after) { throw "Pôvodný index sa zmenil.`nBEFORE=$before`nAFTER=$after" }
        Write-Log 'PASS PublishWorktreeIsolationSelfTest'
        if (-not $Silent) { Write-Host 'PASS PublishWorktreeIsolationSelfTest' }
    }
    finally {
        if (Test-Path -LiteralPath $wt) {
            try { Invoke-CommandInDirectory $repo 'git.exe' @('worktree', 'remove', '--force', $wt) | Out-Null } catch {}
        }
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    }
}

try {
    Write-Log "START ProjectRoot=$ProjectRoot PowerShell=$($PSVersionTable.PSVersion)"
    Remove-OldLogs
    if ($ValidationSelfTest) {
        Invoke-ValidationSelfTest
        Write-Log 'PASS'
        exit 0
    }
    if ($BrokerLoadSelfTest) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný pre -BrokerLoadSelfTest." }
        Invoke-BrokerLoadSelfTest $BrokerFolder
        Write-Log 'PASS'
        exit 0
    }
    if ($GuiLoadSelfTest) {
        Start-Gui
        Write-Log 'PASS'
        exit 0
    }
    if ($GuiGenerateSelfTest) {
        Start-Gui
        Write-Log 'PASS'
        exit 0
    }
    if ($GuiPhotoPositionSelfTest) {
        Start-Gui
        Write-Log 'PASS'
        exit 0
    }
    if ($PublishPlanSelfTest) {
        Invoke-PublishPlanSelfTest
        Write-Log 'PASS'
        exit 0
    }
    if ($PublishWorktreeIsolationSelfTest) {
        Invoke-PublishWorktreeIsolationSelfTest
        Write-Log 'PASS'
        exit 0
    }
    if ($PublicPreview404SelfTest) {
        Invoke-PublicPreview404SelfTest
        Write-Log 'PASS'
        exit 0
    }
    if ($Generate) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný v automatickom režime." }
        $published = Invoke-GenerateCore -Folder $BrokerFolder -Broker $null -DoPublish ([bool]$Publish) -PreparedOverrideFile $OverrideFile -SkipImportTests ([bool]$SkipImportTests)
        if ($ResultFile) {
            $isPublished = [bool]$published
            $message = if ($isPublished) { [string]$published.message } else { 'Lokálne generovanie bolo dokončené.' }
            Write-ResultFile `
                -Path $ResultFile `
                -Status 'PASS' `
                -Slug (Get-ResultSlug $BrokerFolder $OverrideFile) `
                -Published $isPublished `
                -Message $message `
                -PublicUrl $(if ($isPublished) { [string]$published.publicUrl } else { '' }) `
                -PublishBranch $(if ($isPublished) { [string]$published.publishBranch } else { '' }) `
                -PrNumber $(if ($isPublished) { [string]$published.prNumber } else { '' }) `
                -PrUrl $(if ($isPublished) { [string]$published.prUrl } else { '' }) `
                -HeadSha $(if ($isPublished) { [string]$published.headSha } else { '' }) `
                -MergeSha $(if ($isPublished) { [string]$published.mergeSha } else { '' }) `
                -WorkflowRunUrl $(if ($isPublished) { [string]$published.workflowRunUrl } else { '' })
        }
        Write-Log 'PASS'
        if (-not $Silent) { Write-Host "PASS. Log: $LogFile" }
        exit 0
    }
    Start-Gui
    exit 0
} catch {
    Write-Log ("FAIL " + $_.Exception.Message)
    if ($ResultFile) {
        try {
            $detail = [string]$_.Exception.Message
            $phase = ''
            $match = [regex]::Match($detail, '^\[PUBLISH_PHASE=([A-Z]+)\]\s*(.*)$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
            if ($match.Success) {
                $phase = $match.Groups[1].Value
                $detail = $match.Groups[2].Value
            }
            $summary = Get-FailureSummary $detail
            Write-ResultFile -Path $ResultFile -Status 'FAIL' -Slug (Get-ResultSlug $BrokerFolder $OverrideFile) -Published $false -Message $summary -Detail $detail -Phase $phase
        } catch {
            Write-Log ("FAIL ResultFile zápis zlyhal: " + $_.Exception.Message)
        }
    }
    if (-not $Silent) {
        Write-Host ("FAIL " + $_.Exception.Message)
        Write-Host "Log: $LogFile"
        Read-Host "Stlačte Enter na ukončenie"
    }
    exit 1
}
