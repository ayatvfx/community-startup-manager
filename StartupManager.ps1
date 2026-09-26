param(
    [switch]$SelfTest,
    [switch]$RestoreAll,
    [switch]$UiSmokeTest,
    [string]$UiScreenshotPath
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
            if ($file.Name -ieq 'desktop.ini' -or ($file.Attributes -band [IO.FileAttributes]::System)) { continue }
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

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Brush([string]$hex) {
    return [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex)
}

$xamlPath = Join-Path $PSScriptRoot 'App.xaml'
$reader = [System.Xml.XmlReader]::Create($xamlPath)
try { $window = [System.Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Dispose() }

$search = $window.FindName('SearchBox')
$searchHint = $window.FindName('SearchHint')
$itemList = $window.FindName('ItemList')
$allButton = $window.FindName('AllButton')
$enabledFilterButton = $window.FindName('EnabledButton')
$disabledFilterButton = $window.FindName('DisabledButton')
$refreshButton = $window.FindName('RefreshButton')
$backupButton = $window.FindName('BackupButton')
$disableButton = $window.FindName('DisableButton')
$enableButton = $window.FindName('EnableButton')
$totalCount = $window.FindName('TotalCount')
$enabledCount = $window.FindName('EnabledCount')
$disabledCount = $window.FindName('DisabledCount')
$detailTitle = $window.FindName('DetailTitle')
$detailText = $window.FindName('DetailText')
$statusText = $window.FindName('StatusText')
$script:allItems = @()
$script:filterMode = 'All'

function New-Text([string]$value, [double]$size, [string]$color, [bool]$bold = $false) {
    $block = [System.Windows.Controls.TextBlock]::new()
    $block.Text = $value
    $block.FontSize = $size
    $block.Foreground = Brush $color
    if ($bold) { $block.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $block.TextTrimming = 'CharacterEllipsis'
    return $block
}

function New-ItemCard($entry) {
    $item = [System.Windows.Controls.ListBoxItem]::new()
    $item.Tag = $entry

    $card = [System.Windows.Controls.Border]::new()
    $card.Background = Brush '#FFFFFF'
    $card.BorderBrush = Brush '#E5E5EA'
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(11)
    $card.Padding = [System.Windows.Thickness]::new(14, 10, 14, 10)
    $card.MinHeight = 62

    $grid = [System.Windows.Controls.Grid]::new()
    foreach ($width in @(18, 205, '*', 62)) {
        $column = [System.Windows.Controls.ColumnDefinition]::new()
        if ($width -eq '*') { $column.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star) }
        else { $column.Width = [System.Windows.GridLength]::new([double]$width) }
        [void]$grid.ColumnDefinitions.Add($column)
    }

    $dot = [System.Windows.Shapes.Ellipse]::new()
    $dot.Width = 8; $dot.Height = 8
    $dot.Fill = if ($entry.State -eq 'Enabled') { Brush '#26A269' } else { Brush '#C9985C' }
    $dot.VerticalAlignment = 'Center'
    $dot.HorizontalAlignment = 'Left'
    [System.Windows.Controls.Grid]::SetColumn($dot, 0)
    [void]$grid.Children.Add($dot)

    $nameStack = [System.Windows.Controls.StackPanel]::new()
    $nameStack.VerticalAlignment = 'Center'
    $name = New-Text ([string]$entry.Name) 14 '#1D1D1F' $true
    $name.ToolTip = [string]$entry.Name
    $source = New-Text ([string]$entry.Kind) 11 '#8E8E93'
    $source.Margin = [System.Windows.Thickness]::new(0, 3, 0, 0)
    [void]$nameStack.Children.Add($name)
    [void]$nameStack.Children.Add($source)
    [System.Windows.Controls.Grid]::SetColumn($nameStack, 1)
    [void]$grid.Children.Add($nameStack)

    $detail = New-Text ([string]$entry.Detail) 12 '#6E6E73'
    $detail.ToolTip = [string]$entry.Detail
    $detail.VerticalAlignment = 'Center'
    $detail.Margin = [System.Windows.Thickness]::new(7, 0, 15, 0)
    [System.Windows.Controls.Grid]::SetColumn($detail, 2)
    [void]$grid.Children.Add($detail)

    $badge = [System.Windows.Controls.Border]::new()
    $badge.CornerRadius = [System.Windows.CornerRadius]::new(9)
    $badge.Padding = [System.Windows.Thickness]::new(7, 5, 7, 5)
    $badge.VerticalAlignment = 'Center'
    if ($entry.State -eq 'Enabled') {
        $badge.Background = Brush '#E5F4EC'
        $badge.Child = New-Text 'On' 11 '#16825D' $true
    } else {
        $badge.Background = Brush '#F8EEE3'
        $badge.Child = New-Text 'Off' 11 '#A56A30' $true
    }
    $badge.HorizontalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($badge, 3)
    [void]$grid.Children.Add($badge)

    $card.Child = $grid
    $item.Content = $card
    return $item
}

function Get-SelectedItem {
    if ($null -eq $itemList.SelectedItem) { return $null }
    return $itemList.SelectedItem.Tag
}

function Update-Selection {
    $selected = Get-SelectedItem
    $disableButton.IsEnabled = ($null -ne $selected -and $selected.State -eq 'Enabled')
    $enableButton.IsEnabled = ($null -ne $selected -and $selected.State -eq 'Disabled')
    foreach ($row in $itemList.Items) {
        $row.Content.BorderBrush = if ($row.IsSelected) { Brush '#007AFF' } else { Brush '#E5E5EA' }
        $row.Content.BorderThickness = if ($row.IsSelected) { [System.Windows.Thickness]::new(2) } else { [System.Windows.Thickness]::new(1) }
    }
    if ($null -eq $selected) {
        $detailTitle.Text = 'Select an app to see its details'
        $detailText.Text = 'Items turned off here are backed up and can be restored.'
    } else {
        $detailTitle.Text = "$($selected.Name)  -  $($selected.State)"
        $detailText.Text = "$($selected.Kind)  |  $($selected.Detail)"
    }
}

function Update-FilterButtons {
    foreach ($pair in @(@($allButton, 'All'), @($enabledFilterButton, 'Enabled'), @($disabledFilterButton, 'Disabled'))) {
        $button = $pair[0]
        $button.Background = if ($script:filterMode -eq $pair[1]) { Brush '#FFFFFF' } else { Brush '#E9E9ED' }
        $button.Foreground = if ($script:filterMode -eq $pair[1]) { Brush '#1D1D1F' } else { Brush '#6E6E73' }
    }
}

function Refresh-List {
    $query = $search.Text.Trim()
    $itemList.Items.Clear()
    foreach ($entry in @($script:allItems | Sort-Object Name, State)) {
        if ($script:filterMode -eq 'Enabled' -and $entry.State -ne 'Enabled') { continue }
        if ($script:filterMode -eq 'Disabled' -and $entry.State -ne 'Disabled') { continue }
        if ($query -and $entry.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
            $entry.Detail.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        [void]$itemList.Items.Add((New-ItemCard $entry))
    }
    Update-Selection
    $statusText.Text = "Showing $($itemList.Items.Count) of $($script:allItems.Count) items"
}

function Load-Items {
    $script:allItems = @((Get-ActiveItems) + (Get-DisabledItems))
    $totalCount.Text = [string]$script:allItems.Count
    $enabledCount.Text = [string]@($script:allItems | Where-Object State -eq 'Enabled').Count
    $disabledCount.Text = [string]@($script:allItems | Where-Object State -eq 'Disabled').Count
    Refresh-List
}

$itemList.Add_SelectionChanged({ Update-Selection })
$search.Add_TextChanged({
    $searchHint.Visibility = if ($search.Text.Length) { 'Collapsed' } else { 'Visible' }
    Refresh-List
})
$allButton.Add_Click({ $script:filterMode = 'All'; Update-FilterButtons; Refresh-List })
$enabledFilterButton.Add_Click({ $script:filterMode = 'Enabled'; Update-FilterButtons; Refresh-List })
$disabledFilterButton.Add_Click({ $script:filterMode = 'Disabled'; Update-FilterButtons; Refresh-List })
$refreshButton.Add_Click({
    try { Load-Items } catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Refresh failed') | Out-Null }
})
$backupButton.Add_Click({ Initialize-Store; Start-Process explorer.exe -ArgumentList ('"' + $script:Store + '"') })
$disableButton.Add_Click({
    $selected = Get-SelectedItem
    if ($null -eq $selected) { return }
    try { Disable-Item $selected; Load-Items; $statusText.Text = "Turned off: $($selected.Name)" }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Turn off failed') | Out-Null }
})
$enableButton.Add_Click({
    $selected = Get-SelectedItem
    if ($null -eq $selected) { return }
    try { Enable-Item $selected; Load-Items; $statusText.Text = "Turned on: $($selected.Name)" }
    catch { [System.Windows.MessageBox]::Show($_.Exception.Message, 'Turn on failed') | Out-Null }
})

Update-FilterButtons
Load-Items
if ($UiSmokeTest) {
    if ($null -eq $itemList -or $null -eq $search -or $null -eq $allButton) { throw 'UI controls did not initialize.' }
    $baseline = $itemList.Items.Count
    $search.Text = '__not_a_real_startup_item__'
    if ($itemList.Items.Count -ne 0 -or $searchHint.Visibility -ne 'Collapsed') { throw 'Search filter failed.' }
    $search.Text = ''
    if ($itemList.Items.Count -ne $baseline -or $searchHint.Visibility -ne 'Visible') { throw 'Search reset failed.' }
    $script:filterMode = 'Enabled'; Update-FilterButtons; Refresh-List
    if ($itemList.Items.Count -ne [int]$enabledCount.Text) { throw 'Enabled filter failed.' }
    $script:filterMode = 'Disabled'; Update-FilterButtons; Refresh-List
    if ($itemList.Items.Count -ne [int]$disabledCount.Text) { throw 'Disabled filter failed.' }
    $script:filterMode = 'All'; Update-FilterButtons; Refresh-List
    Write-Output "PASS UI: rounded dashboard initialized; $($itemList.Items.Count) rows; search and filters ready"
    exit 0
}
if ($UiScreenshotPath) {
    $script:allItems = @(
        [pscustomobject]@{ State='Enabled'; Kind='Registry Run'; Name='Notes'; Detail='C:\Apps\Notes\Notes.exe'; RecordPath=$null },
        [pscustomobject]@{ State='Enabled'; Kind='Startup folder'; Name='Calendar'; Detail='C:\Startup\Calendar.lnk'; RecordPath=$null },
        [pscustomobject]@{ State='Disabled'; Kind='Registry Run'; Name='Music Player'; Detail='C:\Apps\Music\Player.exe'; RecordPath='demo' },
        [pscustomobject]@{ State='Disabled'; Kind='Startup folder'; Name='Cloud Sync'; Detail='C:\Startup\Cloud Sync.lnk'; RecordPath='demo' }
    )
    $totalCount.Text = '4'; $enabledCount.Text = '2'; $disabledCount.Text = '2'
    Refresh-List
    $window.Show()
    $window.UpdateLayout()
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    $root = $window.Content
    $contentWidth = [int]$root.ActualWidth
    $contentHeight = [int]$root.ActualHeight
    $width = $contentWidth + 60
    $height = $contentHeight + 40
    $image = [System.Windows.Media.Imaging.RenderTargetBitmap]::new($width, $height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $visual = [System.Windows.Media.DrawingVisual]::new()
    $drawing = $visual.RenderOpen()
    $drawing.DrawRectangle((Brush '#F5F5F7'), $null, [System.Windows.Rect]::new(0, 0, $width, $height))
    $drawing.DrawRectangle([System.Windows.Media.VisualBrush]::new($root), $null, [System.Windows.Rect]::new(30, 22, $contentWidth, $contentHeight))
    $drawing.Close()
    $image.Render($visual)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    [void]$encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($image))
    $stream = [IO.File]::Create($UiScreenshotPath)
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    $window.Close()
    Write-Output "PASS screenshot: $UiScreenshotPath"
    exit 0
}
[void]$window.ShowDialog()
