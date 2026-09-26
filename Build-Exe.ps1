$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$compiler = @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compiler) { throw 'The .NET Framework C# compiler was not found.' }

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$output = Join-Path $dist 'CommunityStartupManager.exe'
$arguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    "/out:$output",
    "/resource:$root\StartupManager.ps1,CommunityStartupManager.StartupManager.ps1",
    "/resource:$root\App.xaml,CommunityStartupManager.App.xaml",
    '/reference:System.Windows.Forms.dll',
    (Join-Path $root 'Launcher.cs')
)
& $compiler @arguments
if ($LASTEXITCODE -ne 0) { throw "C# compiler failed with exit code $LASTEXITCODE." }
Write-Output "Built: $output"
Write-Output "SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
