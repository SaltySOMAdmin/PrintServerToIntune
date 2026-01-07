#Log Dir
$LogDir = ".\Logs"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogPath = Join-Path $LogDir "SkippedPrinters.csv"

# Show installed printers and let an admin pick one or many
$SelectedPrinters = Get-Printer | Out-GridView -Title 'Select Printers to Migrate to Intune' -PassThru
Select-Object Name,DriverName,PortName,ComputerName,ShareName |

#Create Directory Structure
New-Item -Path .\Drivers -ItemType Directory

if (-not $SelectedPrinters) {
  Write-Host "No printers selected." -ForegroundColor Yellow
  return
}

ForEach ($selectedprinter in $selectedprinters) {
If ($selectedprinter.ShareName) {
$PrinterName = $selectedprinter.ShareName
}
else {
$PrinterName = $selectedPrinter.Name
}
$PortName = $selectedPrinter.PortName
$PrinterIP = (Get-PrinterPort -Name $PortName).PrinterHostAddress
$DriverName = $selectedprinter.DriverName
# Path to save user printer preferences
$PrefsFile = ".\ExportedPrinters\$PrinterName\user_prefs.dat"


#Grab the 64-bit driver if there are multiple listed and check for INF path. Skip if no INF path. 
$Driver = Get-PrinterDriver -Name $DriverName | Where-Object PrinterEnvironment -eq 'Windows x64' | Select-Object -First 1

#Skip if no driver:
if (!$Driver) {
$logskipped = [pscustomobject]@{
    PrinterName         = $PrinterName
    DriverName          = $DriverName
    PortName            = $PortName
    PrinterIP           = $PrinterIP
    PrinterEnvironment  = $Driver.PrinterEnvironment
    InfPath             = $Driver.InfPath
    Reason              = "No driver object present"
 }
$logskipped | Export-Csv -Path $LogPath -Append -NoTypeInformation
Write-Host "Skipping '$printername' - There's no driver object found. See log for additional details." -ForegroundColor Red
continue
}

#Skip Driver export if an integrated Windows/Microsoft driver (IPP or similar)
if ($Driver.Manufacturer -eq 'Microsoft') {
$logskipped = [pscustomobject]@{
    PrinterName        = $PrinterName
    DriverName         = $DriverName
    PortName           = $PortName
    PrinterIP          = $PrinterIP
    PrinterEnvironment = $Driver.PrinterEnvironment
    InfPath            = $Driver.InfPath
    Reason             = "Microsoft driver - will be provided by OS/Windows Update"
 }
 
$logskipped | Export-Csv -Path $LogPath -Append -NoTypeInformation
Write-Host "Skipping driver export for '$PrinterName' - Microsoft class driver (no export needed)" -ForegroundColor Yellow
continue
}

#Skip drivers with no exportable INF
 if (!$Driver.InfPath) {
$logskipped = [pscustomobject]@{
    PrinterName         = $PrinterName
    DriverName          = $DriverName
    PortName            = $PortName
    PrinterIP           = $PrinterIP
    PrinterEnvironment  = $Driver.PrinterEnvironment
    InfPath             = $Driver.InfPath
    Reason              = "INF Path Empty. Cannot export with this script"
 }
$logskipped | Export-Csv -Path $LogPath -Append -NoTypeInformation
Write-Host "Skipping driver export for '$PrinterName' - Microsoft class driver (no export needed)" -ForegroundColor Yellow
continue
}

$DriverPath = $Driver.InfPath | Split-Path
$DriverINF  = $Driver.InfPath | Split-Path -Leaf

#Copy Driver Files to directory for packaging
If (Test-Path .\Drivers\$Drivername) {
Write-Host "Driver directory already exist"
}
Else {
$DriverDir = New-Item -Path .\ExportedPrinters\$PrinterName\driver -ItemType Directory
Copy-Item -Path "$DriverPath\*" -Destination $DriverDir -Recurse

# Export current user's printer preferences (if any)
Write-Host "Exporting printer preferences for $PrinterName" -ForegroundColor Cyan

$proc = Start-Process -FilePath "rundll32.exe" `
    -ArgumentList "printui.dll,PrintUIEntry /Sr /n `"$PrinterName`" /a `"$PrefsFile`" d u g" `
    -Wait -PassThru -NoNewWindow

if (Test-Path $PrefsFile) {
    Write-Host "Preferences exported successfully" -ForegroundColor Green
}
else {
    Write-Warning "Could not export preferences for $PrinterName (driver does not support it or access denied)"
}


#Generate Install script for the printer
$PkgDir      = ".\ExportedPrinters\$PrinterName"
$InstallPath = Join-Path $PkgDir 'Install.ps1'
New-Item -ItemType Directory -Path $PkgDir -Force | Out-Null   # in case folder wasn't created yet

$install = @"
# Auto-generated installer for: $PrinterName

`$DriverINF   = '$DriverINF'
`$DriverName  = '$DriverName'
`$PortName    = '$PortName'
`$PrinterIP   = '$PrinterIP'
`$PrinterName = '$PrinterName'

pnputil.exe /add-driver ".\Driver\`$DriverINF" /install
Add-PrinterDriver -Name `$drivername -ErrorAction SilentlyContinue

`$checkPortExists = Get-Printerport -Name `$portname -ErrorAction SilentlyContinue

if (-not `$checkPortExists) 
{
Add-PrinterPort -name `$portName -PrinterHostAddress `$PrinterIP
}

`$printDriverExists = Get-PrinterDriver -name `$DriverName -ErrorAction SilentlyContinue

if (`$printDriverExists)
{
Add-Printer -Name `$PrinterName -PortName `$portName -DriverName `$DriverName
}
else
{
Write-Warning "Printer Driver not installed"
}

# Restore printer preferences if present
`$PrefsFile = ".\user_prefs.dat"
if (Test-Path `$PrefsFile) {
    Write-Host "Restoring printer preferences..."
    rundll32 printui.dll,PrintUIEntry /Ss /n "`$PrinterName" /a "`$PrefsFile" d u g
}
else {
    Write-Host "No preferences file found to restore."
}

SLEEP 30
"@

Set-Content -Path $InstallPath -Value $install -Encoding UTF8 -Force
Write-Host "Created: $InstallPath" -ForegroundColor Green
}

#Generate Detection Script
$detectionPath = Join-Path $pkgDir 'detection.ps1'
$detectionScript = @"
`$PrinterName = "$PrinterName"

`$printerinstalled = Get-Printer -Name "`$PrinterName" -ErrorAction SilentlyContinue
if (`$printerinstalled) {
    Write-Output "Printer exists"
    exit 0
}
else {
    Write-Output "Printer not installed"
    exit 1
}
"@

Set-Content -Path $detectionPath -Value $detectionScript -Encoding UTF8 -Force
Write-Host "Created: $detectionPath" -ForegroundColor Cyan

#Generate Uninstall Script
$uninstallPath = Join-Path $pkgDir 'uninstall.ps1'
$uninstallScript = @"
`$PrinterName = "$PrinterName"
`Remove-Printer -Name "`$PrinterName" 
"@

Set-Content -Path $uninstallPath -Value $uninstallScript -Encoding UTF8 -Force
Write-Host "Created: $uninstallPath" -ForegroundColor Cyan

#Build a manifest file with printer details
$manifest = @{
    PrinterName        = $PrinterName
    DriverName         = $DriverName
    DriverINF          = $DriverINF
    PortName           = $PortName
    PrinterIP          = $PrinterIP
    DriverSourcePath   = $DriverPath
    ExportedOnLocal  = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss zzz")
}

#Save as manifest.json next to install.ps1
$manifestPath = Join-Path $pkgDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Created manifest: $manifestPath" -ForegroundColor Cyan
}

<#
#Grab the IntuneWinAppUtil
$dest = Join-Path (Get-Location) "IntuneWinAppUtil.exe"
$url  = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe"

Write-Host "Downloading IntuneWinAppUtil.exe from GitHub..."

  Invoke-WebRequest -Uri $url -OutFile $dest

if (Test-Path $dest) {
  Write-Host "Download successful" -ForegroundColor Green
} else {
  Write-Warning "Download failed. Please check the URL or your network." -Foreground Red
}
#>

#Package Printer Files for Win32 App Deployment
$IntuneWinAppUtil = ".\IntuneWinAppUtil.exe"
$SourcePath = ".\ExportedPrinters"
$PrinterFolders = Get-Childitem $SourcePath -Directory

foreach ($PrinterFolder in $PrinterFolders) {
    $setupFolder   = $PrinterFolder.FullName
    $printerName = $PrinterFolder.Name
    $setupFile   = "install.ps1"
    $setupPath   = Join-Path $setupFolder $setupFile

    if (-not (Test-Path $setupPath)) {
        Write-Warning "No install.ps1 in $setupFolder - skipping"
        continue
    }

    Write-Host "Packaging $printerName for Intune deployment..." -ForegroundColor Cyan
    & $IntuneWinAppUtil -c $setupFolder -s $setupFile -o $setupFolder -q
    Write-Host "Successfully Created .intunewin for $printername" -ForegroundColor Green
}

$runuploadscript = Read-Host "**All printers & drivers have been exported and packaged for Intune upload. Do you want to upload these printers now?** (Type Y or N and press enter)"
$runuploadscript = $runuploadscript.Trim().ToUpper()
If ($runuploadscript.Trim().ToUpper() -eq "Y") {
    Write-Host "User entered $runuploadscript - running script to upload printers to Intune" -ForegroundColor Yellow
    Start-Sleep 2
    & .\UploadIntuneWinPrinters.ps1
}
else {
    Write-Host "User entered $runuploadscript - ending script" -ForegroundColor Yellow
}