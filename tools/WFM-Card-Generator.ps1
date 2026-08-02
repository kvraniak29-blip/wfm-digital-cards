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

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$LogsDir = Join-Path $ProjectRoot 'logs'
New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
$LogFile = Join-Path $LogsDir ("WFM-Generator-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$script:LastOverrideFile = $null

function Write-Log {
    param([string]$Message)
    $line = "{0} {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-ProjectCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    Write-Log ("RUN {0} {1}" -f $FilePath, ($Arguments -join ' '))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    $psi.WorkingDirectory = $ProjectRoot
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($stdout) { Write-Log $stdout.Trim() }
    if ($stderr) { Write-Log $stderr.Trim() }
    if ($p.ExitCode -ne 0) { throw "Príkaz zlyhal ($($p.ExitCode)): $FilePath $($Arguments -join ' ')" }
    return $stdout
}

function Get-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "Node.js nie je dostupný v PATH." }
    return $cmd.Source
}

function Get-BrokerInfo {
    param([string]$Folder)
    $node = Get-NodeExe
    $json = Invoke-ProjectCommand $node @('scripts/inspect-broker-folder.mjs', '--folder', $Folder)
    return $json | ConvertFrom-Json
}

function Write-BrokerOverride {
    param($Broker, [string]$Folder)
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
    $file = Join-Path $LogsDir ("broker-override-{0}-{1}.json" -f $safe, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    ($override | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $file -Encoding UTF8
    Write-Log "Zapísaný dočasný broker override: $file"
    return $file
}

function Invoke-Generate {
    param([string]$Folder, [bool]$DoPublish)
    $node = Get-NodeExe
    $importArgs = @('scripts/import-broker.mjs', '--folder', $Folder, '--yes-update')
    if ($script:LastOverrideFile) { $importArgs += @('--override', $script:LastOverrideFile) }
    Invoke-ProjectCommand $node $importArgs | Out-Null
    Invoke-ProjectCommand 'npm.cmd' @('run', 'build:github-pages') | Out-Null
    if ($DoPublish) {
        $status = Invoke-ProjectCommand 'git.exe' @('status', '--porcelain')
        $foreign = @()
        foreach ($line in ($status -split "`r?`n")) {
            if (-not $line.Trim()) { continue }
            $path = $line.Substring(3).Replace('\','/')
            if ($path -notmatch '^(data/brokers/|data/status/|assets/brokers/|assets/branding/|config/|src/|scripts/|tests/|tools/|README.md|package.json|package-lock.json|\.github/|\.gitignore|Spustit-WFM-Generator.cmd)') {
                $foreign += $line
            }
        }
        if ($foreign.Count -gt 0) { throw "Publikovanie zastavené. Existujú cudzie necommitnuté zmeny:`n$($foreign -join "`n")" }
        Invoke-ProjectCommand 'git.exe' @('add', 'data/brokers', 'data/status', 'assets/brokers', 'assets/branding', 'config', 'src', 'scripts', 'tests', 'tools', 'README.md', 'package.json', 'package-lock.json', '.github', '.gitignore', 'Spustit-WFM-Generator.cmd') | Out-Null
        $pending = Invoke-ProjectCommand 'git.exe' @('status', '--porcelain')
        if ($pending.Trim()) {
            $name = (Get-BrokerInfo $Folder).broker.displayName
            Invoke-ProjectCommand 'git.exe' @('commit', '-m', "Add or update digital card: $name") | Out-Null
            Invoke-ProjectCommand 'git.exe' @('push', 'origin', 'main') | Out-Null
            $run = Invoke-ProjectCommand 'gh.exe' @('run', 'list', '--repo', 'kvraniak29-blip/wfm-digital-cards', '--limit', '1')
            Write-Log $run
        }
    }
}

function Start-Gui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'WFM Card Generator'
    $form.Width = 900
    $form.Height = 760
    $form.StartPosition = 'CenterScreen'

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Left = 16; $pathBox.Top = 16; $pathBox.Width = 610
    $form.Controls.Add($pathBox)

    $choose = New-Object System.Windows.Forms.Button
    $choose.Text = 'Vybrať priečinok makléra'
    $choose.Left = 640; $choose.Top = 14; $choose.Width = 210
    $form.Controls.Add($choose)

    $load = New-Object System.Windows.Forms.Button
    $load.Text = 'Načítať a skontrolovať'
    $load.Left = 16; $load.Top = 48; $load.Width = 200
    $form.Controls.Add($load)

    $picture = New-Object System.Windows.Forms.PictureBox
    $picture.Left = 650; $picture.Top = 90; $picture.Width = 190; $picture.Height = 190
    $picture.SizeMode = 'Zoom'
    $form.Controls.Add($picture)

    $fields = [ordered]@{}
    $labels = @('firstName','lastName','displayName','title','company','phoneDisplay','phoneE164','email','website','whatsapp','facebook','instagram','slug','photoPosition')
    $top = 92
    foreach ($name in $labels) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $name
        $label.Left = 16; $label.Top = $top + 4; $label.Width = 120
        $form.Controls.Add($label)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Left = 145; $box.Top = $top; $box.Width = 470
        $form.Controls.Add($box)
        $fields[$name] = $box
        $top += 32
    }

    $publishBox = New-Object System.Windows.Forms.CheckBox
    $publishBox.Text = 'Po úspechu publikovať na GitHub Pages'
    $publishBox.Left = 16; $publishBox.Top = 560; $publishBox.Width = 310
    $form.Controls.Add($publishBox)

    $generateButton = New-Object System.Windows.Forms.Button
    $generateButton.Text = 'Generovať vizitku'
    $generateButton.Left = 16; $generateButton.Top = 594; $generateButton.Width = 180
    $form.Controls.Add($generateButton)

    $localButton = New-Object System.Windows.Forms.Button
    $localButton.Text = 'Otvoriť lokálny náhľad'
    $localButton.Left = 210; $localButton.Top = 594; $localButton.Width = 170
    $form.Controls.Add($localButton)

    $publicButton = New-Object System.Windows.Forms.Button
    $publicButton.Text = 'Otvoriť verejnú vizitku'
    $publicButton.Left = 395; $publicButton.Top = 594; $publicButton.Width = 180
    $form.Controls.Add($publicButton)

    $status = New-Object System.Windows.Forms.Label
    $status.Left = 16; $status.Top = 635; $status.Width = 820; $status.Height = 55
    $status.Text = "Pripravené. Vyberte priečinok makléra. Log: $LogFile"
    $form.Controls.Add($status)

    $choose.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq 'OK') { $pathBox.Text = $dialog.SelectedPath }
    })

    $load.Add_Click({
        try {
            $info = Get-BrokerInfo $pathBox.Text
            foreach ($name in $labels) {
                if ($name -eq 'facebook') { $fields[$name].Text = [string]$info.broker.social.facebook }
                elseif ($name -eq 'instagram') { $fields[$name].Text = [string]$info.broker.social.instagram }
                else { $fields[$name].Text = [string]$info.broker.$name }
            }
            $picture.ImageLocation = $info.photo
            $status.Text = 'PASS Načítané. Môžete upraviť údaje a generovať.'
        } catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
        }
    })

    $generateButton.Add_Click({
        try {
            $broker = [pscustomobject]@{}
            foreach ($name in $labels) { Add-Member -InputObject $broker -NotePropertyName $name -NotePropertyValue $fields[$name].Text }
            $script:LastOverrideFile = Write-BrokerOverride $broker $pathBox.Text
            Invoke-Generate $pathBox.Text $publishBox.Checked
            $status.Text = 'PASS Import bol úspešný. Zdrojový priečinok môžete ponechať, presunúť do archívu alebo odstrániť. Projekt používa internú kópiu.'
        } catch {
            $status.Text = "FAIL $($_.Exception.Message)"
            Write-Log $status.Text
        }
    })

    $localButton.Add_Click({ Start-Process (Join-Path $ProjectRoot 'dist\index.html') })
    $publicButton.Add_Click({
        $slug = $fields['slug'].Text
        if ($slug) { Start-Process "https://kvraniak29-blip.github.io/wfm-digital-cards/$slug/" }
    })

    [void]$form.ShowDialog()
}

try {
    Write-Log "START ProjectRoot=$ProjectRoot"
    if ($Generate) {
        if (-not $BrokerFolder) { throw "-BrokerFolder je povinný v automatickom režime." }
        $script:LastOverrideFile = $null
        Invoke-Generate $BrokerFolder ([bool]$Publish)
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
