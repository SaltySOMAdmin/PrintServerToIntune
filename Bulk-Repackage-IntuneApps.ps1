
<#
.SYNOPSIS
Bulk packages Intune apps using IntuneWinAppUtil.exe for all subfolders that contain Install.ps1,
writing Install.intunewin to the same folder and overwriting if present.

.PARAMETER ToolPath
Full path to IntuneWinAppUtil.exe

.PARAMETER SourceRoot
Root folder that contains app folders (each with Install.ps1)

.PARAMETER Force
If the existing .intunewin file is read-only or locked, attempts to remove and overwrite anyway.

.EXAMPLE
.\Repackage-IntuneApps-Overwrite.ps1
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$ToolPath = 'C:\Users\mkyser\University of Maryland School of Medicine\Surgery IS Team - Files - Files\Intune\Printers\IntuneWinAppUtil.exe',

    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]$SourceRoot = 'C:\Users\mkyser\University of Maryland School of Medicine\Surgery IS Team - Files - Files\Intune\Printers\Locations',

    [switch]$Force
)

function Write-Section($text) { Write-Host "`n==== $text ====" -ForegroundColor Cyan }
function Write-Info($text)    { Write-Host "[INFO] $text" -ForegroundColor Gray }
function Write-Ok($text)      { Write-Host "[ OK ] $text" -ForegroundColor Green }
function Write-Err($text)     { Write-Host "[ERR ] $text" -ForegroundColor Red }

# 0) Validate inputs
if (-not (Test-Path -LiteralPath $ToolPath)) { throw "IntuneWinAppUtil not found: $ToolPath" }
if (-not (Test-Path -LiteralPath $SourceRoot)) { throw "Source root not found: $SourceRoot" }

# 1) Discover all app directories containing Install.ps1
Write-Section "Scanning for apps under: $SourceRoot"
$apps = Get-ChildItem -Path $SourceRoot -Directory -Recurse -Force |
    Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'Install.ps1')
    } |
    Sort-Object FullName

if (-not $apps) {
    Write-Err "No app directories with Install.ps1 were found under $SourceRoot."
    return
}

Write-Info ("Found {0} app folder(s)." -f $apps.Count)

# 2) Package each app in place
$results = New-Object System.Collections.Generic.List[object]

foreach ($app in $apps) {
    $appPath      = $app.FullName
    $installer    = 'Install.ps1'
    $installerPath= Join-Path $appPath $installer
    # IntuneWinAppUtil names the output after the setup file by default:
    $expectedOut  = Join-Path $appPath ([IO.Path]::ChangeExtension($installer, '.intunewin'))
    $logFile      = Join-Path $appPath ("Install_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))

    Write-Section "Packaging: $(Split-Path $appPath -Leaf)"
    Write-Info "App Folder : $appPath"
    Write-Info "Installer  : $installerPath"
    Write-Info "Output     : $expectedOut"
    Write-Info "Log        : $logFile"

    # Ensure any existing file is removed so we truly overwrite
    if (Test-Path -LiteralPath $expectedOut) {
        try {
            $fi = Get-Item -LiteralPath $expectedOut -Force
            if ($fi.Attributes -band [IO.FileAttributes]::ReadOnly) {
                if ($Force) {
                    # Clear read-only and delete
                    $fi.Attributes = ($fi.Attributes -bxor [IO.FileAttributes]::ReadOnly)
                }
            }
            Remove-Item -LiteralPath $expectedOut -Force -ErrorAction Stop
            Write-Info "Removed existing file: $expectedOut"
        } catch {
            if (-not $Force) {
                Write-Err "Existing file could not be removed (use -Force). $_"
                $results.Add([pscustomobject]@{
                    App     = $app.FullName
                    Status  = 'Failed (existing file locked)'
                    Output  = $expectedOut
                    Log     = $logFile
                }) | Out-Null
                continue
            } else {
                Write-Err "Attempting to overwrite despite error removing existing file: $_"
            }
        }
    }

    # Build args for IntuneWinAppUtil
    # -c: source folder, -s: setup file, -o: output folder (app folder), -q: quiet
    $args = @(
        '-c', ('"{0}"' -f $appPath),
        '-s', ('"{0}"' -f $installer),
        '-o', ('"{0}"' -f $appPath),
        '-q'
    ) -join ' '

    if ($PSCmdlet.ShouldProcess($appPath, "Run IntuneWinAppUtil to create Install.intunewin")) {
        # Start-Process to capture output and exit code
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $ToolPath
        $psi.Arguments              = $args
        $psi.WorkingDirectory       = Split-Path -Path $ToolPath -Parent
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi

        $null = $proc.Start()
        $stdOut = $proc.StandardOutput.ReadToEnd()
        $stdErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        # Write a log alongside the app
        "[{0}] IntuneWinAppUtil.exe {1}`r`n--- STDOUT ---`r`n{2}`r`n--- STDERR ---`r`n{3}" -f (Get-Date), $args, $stdOut, $stdErr |
            Out-File -FilePath $logFile -Encoding UTF8

        if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $expectedOut)) {
            Write-Ok "Packaged -> $expectedOut"
            $status = 'Success'
        } else {
            Write-Err "Failed with exit code $($proc.ExitCode). See log: $logFile"
            $status = 'Failed'
        }

        $results.Add([pscustomobject]@{
            App     = $app.FullName
            Status  = $status
            Output  = $expectedOut
            Log     = $logFile
        }) | Out-Null
    }
}

Write-Section "Summary"
$results | Format-Table -AutoSize
Write-Host "`nDone." -ForegroundColor Cyan
