#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$BrokerFolder,
    [switch]$Generate,
    [switch]$Publish,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$LogsDir = Join-Path $ProjectRoot 'logs'
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
$LogFile = Join-Path $LogsDir ("WFM-Generator-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:PreviewServerProcess = $null
$script:LastBrokerInfo = $null
$script:LastOverrideFile = $null
$script:LastOutputFolder = Join-Path $ProjectRoot 'dist'

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
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

    try {
        $rawOutput = & $FilePath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }

        $output = ($rawOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($output) { Write-Log $output }

        if ($exitCode -ne 0) {
            throw "Príkaz zlyhal s kódom ${exitCode}: $FilePath $($Arguments -join ' ')`n$output"
        }

        return $output
    }
    finally {
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
    ($override | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Log "Zapísaný dočasný broker override: $file"
    return $file
}

function Test-FieldValues {
    param(
        [Parameter(Mandatory)]$Broker
    )

    $errors = New-Object System.Collections.Generic.List[string]
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
        if ([string]::IsNullOrWhiteSpace([string]$Broker.($pair[0]))) { $errors.Add("$($pair[1]) je povinné pole.") }
    }

    if ($Broker.phoneE164 -and $Broker.phoneE164 -notmatch '^\+[1-9]\d{7,14}$') { $errors.Add('Telefón musí byť vo formáte E.164, napríklad +421900111222.') }
    if ($Broker.email -and $Broker.email -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { $errors.Add('E-mail nemá platný formát.') }
    foreach ($pair in @(
        @('website', 'Web'),
        @('whatsapp', 'WhatsApp'),
        @('facebook', 'Facebook'),
        @('instagram', 'Instagram')
    )) {
        $value = [string]$Broker.($pair[0])
        if ($value -and $value -notmatch '^https://[^\s]+$') { $errors.Add("$($pair[1]) musí byť HTTPS URL.") }
    }
    if ($Broker.whatsapp -and $Broker.phoneE164) {
        $expected = "https://wa.me/$($Broker.phoneE164.Replace('+',''))"
        if ($Broker.whatsapp -ne $expected) { $errors.Add("WhatsApp URL musí zodpovedať telefónu: $expected") }
    }
    if ($Broker.slug -and $Broker.slug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { $errors.Add('URL identifikátor smie obsahovať malé písmená bez diakritiky, čísla a pomlčky.') }
    if ($Broker.photoPosition -and $Broker.photoPosition -notmatch '^(left|right|center|top|bottom|[0-9]{1,3}%)(\s+(left|right|center|top|bottom|[0-9]{1,3}%))?$') {
        $errors.Add('Pozícia fotografie musí byť napríklad 50% 50%, center alebo top center.')
    }

    return $errors
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
        [Parameter()][bool]$DoPublish = $false
    )

    Remove-OldLogs
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Priečinok makléra neexistuje: $Folder" }
    if ($Broker) {
        $errors = Test-FieldValues $Broker
        if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
        $script:LastOverrideFile = Write-BrokerOverride $Broker
    } else {
        $script:LastOverrideFile = $null
    }

    $node = Get-NodeExe
    $npm = Get-NpmExe
    try {
        $importArgs = @('scripts/import-broker.mjs', '--folder', $Folder, '--yes-update')
        if ($script:LastOverrideFile) { $importArgs += @('--override', $script:LastOverrideFile) }
        Invoke-ProjectCommand $node $importArgs | Out-Null
        Invoke-ProjectCommand $npm @('run', 'build:github-pages') | Out-Null

        if ($script:LastOverrideFile -and (Test-Path -LiteralPath $script:LastOverrideFile)) {
            Remove-Item -LiteralPath $script:LastOverrideFile -Force
            Write-Log "Odstránený úspešný dočasný override: $script:LastOverrideFile"
            $script:LastOverrideFile = $null
        }

        if ($DoPublish) { Invoke-Publish }
    } catch {
        if ($script:LastOverrideFile) { Write-Log "Dočasný override ponechaný pre diagnostiku: $script:LastOverrideFile" }
        throw
    }
}

function Get-GitPorcelain {
    $out = Invoke-ProjectCommand 'git.exe' @('status', '--porcelain')
    if (-not $out) { return @() }
    return @($out -split "`r?`n" | Where-Object { $_.Trim() })
}

function Test-PublishAllowed {
    $allowed = '^( M|M |A |AM|MM|\?\?) (data/brokers/|data/status/|assets/brokers/|assets/branding/|config/|src/|scripts/|tests/|tools/|README.md|package.json|package-lock.json|\.github/|\.gitignore|Spustit-WFM-Generator.cmd)'
    $foreign = New-Object System.Collections.Generic.List[string]
    foreach ($line in Get-GitPorcelain) {
        $normalized = $line.Replace('\','/')
        if ($normalized -notmatch $allowed) { $foreign.Add($line) }
    }
    if ($foreign.Count -gt 0) { throw "Publikovanie zastavené. Existujú cudzie necommitnuté zmeny:`n$($foreign -join "`n")" }
}

function Invoke-Publish {
    Test-PublishAllowed
    Invoke-ProjectCommand 'git.exe' @('add', 'data/brokers', 'data/status', 'assets/brokers', 'assets/branding', 'config', 'src', 'scripts', 'tests', 'tools', 'README.md', 'package.json', 'package-lock.json', '.github', '.gitignore', 'Spustit-WFM-Generator.cmd') | Out-Null
    $pending = Get-GitPorcelain
    if ($pending.Count -eq 0) {
        Write-Log 'Publikovanie: nie je čo commitovať.'
        return
    }
    Invoke-ProjectCommand 'git.exe' @('commit', '-m', 'Update WFM digital card') | Out-Null
    Invoke-ProjectCommand 'git.exe' @('push', 'origin', 'main') | Out-Null

    $head = (Invoke-ProjectCommand 'git.exe' @('rev-parse', 'HEAD')).Trim()
    $runJson = Invoke-ProjectCommand 'gh.exe' @('run', 'list', '--repo', 'kvraniak29-blip/wfm-digital-cards', '--workflow', 'Deploy GitHub Pages', '--commit', $head, '--limit', '1', '--json', 'databaseId,status,conclusion')
    $run = ($runJson | ConvertFrom-Json | Select-Object -First 1)
    if (-not $run) { throw 'GitHub Actions run po pushnutí nebol nájdený.' }
    Write-Log "GitHub Actions run ID: $($run.databaseId)"

    for ($i = 0; $i -lt 60; $i++) {
        $viewJson = Invoke-ProjectCommand 'gh.exe' @('run', 'view', [string]$run.databaseId, '--repo', 'kvraniak29-blip/wfm-digital-cards', '--json', 'status,conclusion')
        $view = $viewJson | ConvertFrom-Json
        Write-Log "GitHub Actions: $($view.status) $($view.conclusion)"
        if ($view.status -eq 'completed') {
            if ($view.conclusion -ne 'success') { throw "GitHub Actions zlyhal: $($view.conclusion)" }
            return
        }
        Start-Sleep -Seconds 10
    }
    throw 'GitHub Actions nedokončil v časovom limite.'
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

    $photoGroup = Add-Group $left 'Fotografia' 260
    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Width = 210; $picture.Height = 210; $picture.Left = 18; $picture.Top = 28
    $picture.SizeMode = 'Zoom'
    $picture.BorderStyle = 'FixedSingle'
    $photoGroup.Controls.Add($picture)
    $photoInfo = New-Object System.Windows.Forms.Label
    $photoInfo.Left = 245; $photoInfo.Top = 30; $photoInfo.Width = 270; $photoInfo.Height = 180
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

    $settingsGroup = Add-Group $right 'Nastavenie fotografie' 118
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
        $errors = Test-FieldValues $broker
        $ok = $errors.Count -eq 0 -and (Test-Path -LiteralPath $script:LastBrokerInfo.vcf) -and (Test-Path -LiteralPath $script:LastBrokerInfo.photo)
        $generateLocal.Enabled = $ok
        $generatePublish.Enabled = $ok
        $localPreview.Enabled = [bool]$broker.slug
        $publicPreview.Enabled = [bool]$broker.slug
        if (-not $ok -and $errors.Count -gt 0) { $status.Text = 'FAIL ' + ($errors[0]) }
    }

    foreach ($box in $fields.Values) {
        $box.Add_TextChanged({ Update-Validation })
    }

    function Load-BrokerIntoForm {
        param([string]$Folder)
        $status.Text = 'Načítavam makléra...'
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
        $picture.ImageLocation = $info.photo
        $stateLabel.Text = "PASS Vstup načítaný.`nVCF: $([System.IO.Path]::GetFileName($info.vcf))`nFotografia: $([System.IO.Path]::GetFileName($info.photo))"
        $photoInfo.Text = "Súbor: $([System.IO.Path]::GetFileName($info.photo))`nVýrez sa nemení. Obrázok sa zobrazuje bez deformácie."
        $slugLabel.Text = "Slug: $($info.broker.slug)"
        $publicUrlLabel.Text = "Verejná URL: https://kvraniak29-blip.github.io/wfm-digital-cards/$($info.broker.slug)/"
        $status.Text = 'PASS Načítané. Skontrolujte údaje alebo generujte.'
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
        $errors = Test-FieldValues $broker
        if ($errors.Count -gt 0) {
            $status.Text = 'FAIL ' + ($errors -join ' ')
            return
        }
        if ($DoPublish) {
            $message = "Maklér: $($broker.displayName)`nSlug: $($broker.slug)`nRepozitár: kvraniak29-blip/wfm-digital-cards`nCieľová vetva: main`n`nPokračovať v publikovaní?"
            $answer = [System.Windows.Forms.MessageBox]::Show($message, 'Potvrdenie publikovania', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }

        Set-UiBusy $true
        $status.Text = if ($DoPublish) { 'Generujem a publikujem...' } else { 'Generujem lokálne...' }
        $worker = New-Object System.ComponentModel.BackgroundWorker
        $worker.DoWork += {
            param($sender, $eventArgs)
            $payload = $eventArgs.Argument
            Invoke-GenerateCore $payload.Folder $payload.Broker $payload.Publish
        }
        $worker.RunWorkerCompleted += {
            param($sender, $eventArgs)
            Set-UiBusy $false
            if ($eventArgs.Error) {
                $status.Text = "FAIL $($eventArgs.Error.Message)"
                Write-Log $status.Text
            } else {
                $status.Text = 'PASS Generovanie dokončené.'
                $stateLabel.Text = "PASS Výstup je v priečinku dist.`nLokálny náhľad používajte cez HTTP server."
                Update-Validation
            }
        }
        $worker.RunWorkerAsync([pscustomobject]@{ Folder = $pathBox.Text; Broker = $broker; Publish = $DoPublish })
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
        $slug = $fields['slug'].Text.Trim()
        if ($slug) { Start-Process "https://kvraniak29-blip.github.io/wfm-digital-cards/$slug/" }
    })
    $openLog.Add_Click({ if (Test-Path -LiteralPath $LogFile) { Start-Process $LogFile } })
    $openOutput.Add_Click({ if (Test-Path -LiteralPath $script:LastOutputFolder) { Start-Process $script:LastOutputFolder } })
    $form.Add_FormClosing({
        if ($script:PreviewServerProcess -and -not $script:PreviewServerProcess.HasExited) {
            try { $script:PreviewServerProcess.Kill() } catch {}
        }
    })

    [void]$form.ShowDialog()
}

try {
    Write-Log "START ProjectRoot=$ProjectRoot PowerShell=$($PSVersionTable.PSVersion)"
    Remove-OldLogs
    if ($Generate) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný v automatickom režime." }
        Invoke-GenerateCore $BrokerFolder $null ([bool]$Publish)
        Write-Log 'PASS'
        if (-not $Silent) { Write-Host "PASS. Log: $LogFile" }
        exit 0
    }
    Start-Gui
    exit 0
} catch {
    Write-Log ("FAIL " + $_.Exception.Message)
    if (-not $Silent) {
        Write-Host ("FAIL " + $_.Exception.Message)
        Write-Host "Log: $LogFile"
        Read-Host "Stlačte Enter na ukončenie"
    }
    exit 1
}
