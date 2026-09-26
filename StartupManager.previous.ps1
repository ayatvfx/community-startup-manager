param(
    [switch]$SelfTest,
    [switch]$RestoreAll,
    [switch]$UiSmokeTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# This tool intentionally manages only the signed-in user's Run key and Startup folder.
# It never deletes an entry's original command or file: disabled items are backed up.
$script:RunSubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupFolder = [Environment]::GetFolderPath('Startup')
$script:Store = Join-Path $env:LOCALAPPDATA 'CommunityStartupManager'

function Get-RunKey([bool]$Writable = $false, [bool]$Create = $false) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Default
    )
    try {
        if ($Create) { return $base.CreateSubKey($script:RunSubkey) }
        return $base.OpenSubKey($script:RunSubkey, $Writable)
    } finally { $base.Dispose() }
}

function Initialize-Store {
    New-Item -ItemType Directory -Path (Join-Path $script:Store 'records') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $script:Store 'files') -Force | Out-Null
}

function Get-ActiveItems {
    $items = New-Object System.Collections.ArrayList
    $key = Get-RunKey
    if ($null -ne $key) {
        try {
            foreach ($name in $key.GetValueNames()) {
                $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                [void]$items.Add([pscustomobject]@{
                    State = 'Enabled'; Kind = 'Registry Run'; Name = $name
                    Detail = [string]$value; RecordPath = $null
                })
            }
        } finally { $key.Dispose() }
    }
    if (Test-Path -LiteralPath $script:StartupFolder) {
        foreach ($file in Get-ChildItem -LiteralPath $script:StartupFolder -File -Force) {
            [void]$items.Add([pscustomobject]@{
                State = 'Enabled'; Kind = 'Startup folder'; Name = $file.Name
                Detail = $file.FullName; RecordPath = $null
            })
        }
    }
    return @($items.ToArray())
}

function Get-DisabledItems {
    Initialize-Store
    $items = New-Object System.Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:Store 'records') -Filter '*.json' -File) {
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.Kind -notin @('Registry Run', 'Startup folder')) { continue }
            [void]$items.Add([pscustomobject]@{
                State = 'Disabled'; Kind = $record.Kind; Name = [string]$record.Name
                Detail = if ($record.Kind -eq 'Registry Run') { [string]$record.Value } else { [string]$record.OriginalPath }
                RecordPath = $file.FullName
            })
        } catch {
            Write-Warning "Skipped unreadable backup record: $($file.FullName)"
        }
    }
    return @($items.ToArray())
}

function Save-Record($record) {
    Initialize-Store
    $path = Join-Path (Join-Path $script:Store 'records') "$($record.Id).json"
    $temp = "$path.tmp"
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $path -ErrorAction Stop
    return $path
}

function Disable-Item($item) {
    if ($item.State -ne 'Enabled') { throw 'Select an enabled item.' }
    $id = [guid]::NewGuid().ToString('N')
    if ($item.Kind -eq 'Registry Run') {
        $key = Get-RunKey -Writable $true
        if ($null -eq $key) { throw 'The Run key no longer exists.' }
        try {
            if ($item.Name -notin $key.GetValueNames()) { throw 'The selected entry has changed. Refresh the list.' }
            $value = $key.GetValue($item.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = $key.GetValueKind($item.Name).ToString()
            if ($kind -notin @('String', 'ExpandString')) { throw 'This Run value is not a string and was left unchanged.' }
            $record = [pscustomobject]@{ Id=$id; Kind=$item.Kind; Name=$item.Name; Value=$value; ValueKind=$kind; OriginalPath=$null; SavedPath=$null }
            $path = Save-Record $record
            try { $key.DeleteValue($item.Name, $true) }
            catch { Remove-Item -LiteralPath $path -Force; throw }
        } finally { $key.Dispose() }
    } elseif ($item.Kind -eq 'Startup folder') {
        $source = Join-Path $script:StartupFolder $item.Name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'The selected file has changed. Refresh the list.' }
        $destination = Join-Path (Join-Path $script:Store 'files') "$id$([IO.Path]::GetExtension($item.Name))"
        $record = [pscustomobject]@{ Id=$id; Kind=$item.Kind; Name=$item.Name; Value=$null; ValueKind=$null; OriginalPath=$source; SavedPath=$destination }
        $path = Save-Record $record
        try { Move-Item -LiteralPath $source -Destination $destination -ErrorAction Stop }
        catch { Remove-Item -LiteralPath $path -Force; throw }
    } else { throw 'Unknown item type.' }
}

function Enable-Item($item) {
    if ($item.State -ne 'Disabled') { throw 'Select a disabled item.' }
    $record = Get-Content -LiteralPath $item.RecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.Kind -eq 'Registry Run') {
        $key = Get-RunKey -Create $true
        try {
            if ($record.Name -in $key.GetValueNames()) { throw 'An entry with this name already exists. No changes were made.' }
            $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], [string]$record.ValueKind)
            $key.SetValue([string]$record.Name, $record.Value, $kind)
            Remove-Item -LiteralPath $item.RecordPath -Force
        } finally { $key.Dispose() }
    } elseif ($record.Kind -eq 'Startup folder') {
        if (Test-Path -LiteralPath $record.OriginalPath) { throw 'A file with this name already exists. No changes were made.' }
        if (-not (Test-Path -LiteralPath $record.SavedPath -PathType Leaf)) { throw 'The saved file is missing. No changes were made.' }
        Move-Item -LiteralPath $record.SavedPath -Destination $record.OriginalPath -ErrorAction Stop
        Remove-Item -LiteralPath $item.RecordPath -Force
    } else { throw 'Unknown backup record type.' }
}

function Invoke-SelfTest {
    $oldRun = $script:RunSubkey; $oldStartup = $script:StartupFolder; $oldStore = $script:Store
    $id = [guid]::NewGuid().ToString('N')
    $script:RunSubkey = "Software\CommunityStartupManagerSelfTest\$id\Run"
    $script:StartupFolder = Join-Path $env:TEMP "CSM-$id-startup"
    $script:Store = Join-Path $env:TEMP "CSM-$id-store"
    try {
        New-Item -ItemType Directory -Path $script:StartupFolder -Force | Out-Null
        $key = Get-RunKey -Create $true
        try { $key.SetValue('Sample App', '"C:\Sample\app.exe" --demo', [Microsoft.Win32.RegistryValueKind]::String) }
        finally { $key.Dispose() }
        $sampleFile = Join-Path $script:StartupFolder 'Sample Shortcut.lnk'
        Set-Content -LiteralPath $sampleFile -Value 'test fixture' -Encoding UTF8
        $active = @(Get-ActiveItems)
        if ($active.Count -ne 2) { throw "Expected 2 active fixtures; got $($active.Count)." }
        foreach ($item in $active) { Disable-Item $item }
        if (@(Get-ActiveItems).Count -ne 0 -or @(Get-DisabledItems).Count -ne 2) { throw 'Disable verification failed.' }
        Write-Output 'PASS disable: 0 active, 2 backed-up'
        foreach ($item in @(Get-DisabledItems)) { Enable-Item $item }
        if (@(Get-ActiveItems).Count -ne 2 -or @(Get-DisabledItems).Count -ne 0) { throw 'Enable verification failed.' }
        $key = Get-RunKey
        try {
            if ($key.GetValue('Sample App') -ne '"C:\Sample\app.exe" --demo') { throw 'Registry value mismatch after restore.' }
        } finally { $key.Dispose() }
        if ((Get-Content -LiteralPath $sampleFile -Raw).Trim() -ne 'test fixture') { throw 'Startup file mismatch after restore.' }
        Write-Output 'PASS restore: 2 active, 0 backed-up; registry value and file content match'
    } finally {
        $root = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser, [Microsoft.Win32.RegistryView]::Default)
        try { $root.DeleteSubKeyTree("Software\CommunityStartupManagerSelfTest\$id", $false) } finally { $root.Dispose() }
        Remove-Item -LiteralPath $script:StartupFolder -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:Store -Recurse -Force -ErrorAction SilentlyContinue
        $script:RunSubkey = $oldRun; $script:StartupFolder = $oldStartup; $script:Store = $oldStore
    }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ($RestoreAll) {
    $failed = 0
    foreach ($item in @(Get-DisabledItems)) {
        try { Enable-Item $item; Write-Output "Restored: $($item.Name)" }
        catch { $failed++; Write-Error "Could not restore $($item.Name): $_" -ErrorAction Continue }
    }
    if ($failed) { exit 1 }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Community Startup Manager'
$form.Size = New-Object System.Drawing.Size(900, 530)
$form.MinimumSize = New-Object System.Drawing.Size(700, 420)
$form.StartPosition = 'CenterScreen'

$description = New-Object System.Windows.Forms.Label
$description.Text = 'Manage startup items for your Windows account. Disabled items are saved so you can restore them.'
$description.AutoSize = $false
$description.Dock = 'Top'
$description.Height = 45
$description.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 0)
$form.Controls.Add($description)

$list = New-Object System.Windows.Forms.ListView
$list.View = 'Details'; $list.FullRowSelect = $true; $list.MultiSelect = $false; $list.GridLines = $true
$list.Dock = 'Fill'
[void]$list.Columns.Add('Status', 90)
[void]$list.Columns.Add('Source', 120)
[void]$list.Columns.Add('Name', 200)
[void]$list.Columns.Add('Command or file path', 450)
$form.Controls.Add($list)

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Bottom'; $panel.Height = 50; $panel.Padding = New-Object System.Windows.Forms.Padding(8)
$form.Controls.Add($panel)

$disableButton = New-Object System.Windows.Forms.Button
$disableButton.Text = 'Disable selected'; $disableButton.Width = 135
$enableButton = New-Object System.Windows.Forms.Button
$enableButton.Text = 'Enable selected'; $enableButton.Width = 135
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'; $refreshButton.Width = 90
$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = 'Open backups'; $backupButton.Width = 115
@($disableButton, $enableButton, $refreshButton, $backupButton) | ForEach-Object { [void]$panel.Controls.Add($_) }

function Refresh-List {
    $list.Items.Clear()
    foreach ($entry in @((Get-ActiveItems) + (Get-DisabledItems) | Sort-Object Name, State)) {
        $row = New-Object System.Windows.Forms.ListViewItem([string]$entry.State)
        [void]$row.SubItems.Add([string]$entry.Kind)
        [void]$row.SubItems.Add([string]$entry.Name)
        [void]$row.SubItems.Add([string]$entry.Detail)
        $row.Tag = $entry
        [void]$list.Items.Add($row)
    }
}

$disableButton.Add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    try { Disable-Item $list.SelectedItems[0].Tag; Refresh-List }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Disable failed', 'OK', 'Error') | Out-Null }
})
$enableButton.Add_Click({
    if ($list.SelectedItems.Count -eq 0) { return }
    try { Enable-Item $list.SelectedItems[0].Tag; Refresh-List }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Enable failed', 'OK', 'Error') | Out-Null }
})
$refreshButton.Add_Click({ try { Refresh-List } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message) | Out-Null } })
$backupButton.Add_Click({ Initialize-Store; Start-Process explorer.exe -ArgumentList ('"' + $script:Store + '"') })
$list.Add_SelectedIndexChanged({
    $selected = if ($list.SelectedItems.Count) { $list.SelectedItems[0].Tag } else { $null }
    $disableButton.Enabled = ($null -ne $selected -and $selected.State -eq 'Enabled')
    $enableButton.Enabled = ($null -ne $selected -and $selected.State -eq 'Disabled')
})
$disableButton.Enabled = $false; $enableButton.Enabled = $false
Refresh-List
if ($UiSmokeTest) { Write-Output "PASS UI: window initialized; $($list.Items.Count) rows loaded"; exit 0 }
[void]$form.ShowDialog()
