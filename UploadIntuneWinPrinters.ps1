function Upload-IntuneWinFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$SasUrl,

        [int]$ChunkSizeBytes = 16MB,

        [switch]$SendContentMD5
    )

    if (-not (Test-Path $FilePath)) {
        throw "File not found: $FilePath"
    }

    $blockIds  = New-Object System.Collections.Generic.List[string]
    $totalBytesSent = 0L

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client  = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(30)

    $fs = [System.IO.File]::OpenRead($FilePath)
    try {
        $index  = 0
        $buffer = New-Object byte[] $ChunkSizeBytes

        while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $blockIdPlain = ($index).ToString("0000000000")
            $blockIdB64   = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($blockIdPlain))
            $blockIds.Add($blockIdB64) | Out-Null

            $blockUri = "{0}&comp=block&blockid={1}" -f $SasUrl, [Uri]::EscapeDataString($blockIdB64)

            $chunkBytes = New-Object byte[] $read
            [System.Buffer]::BlockCopy($buffer, 0, $chunkBytes, 0, $read)

            $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $chunkBytes)

            if ($SendContentMD5) {
                $md5    = [System.Security.Cryptography.MD5]::Create().ComputeHash($chunkBytes)
                $md5b64 = [Convert]::ToBase64String($md5)
                $content.Headers.Add("Content-MD5", $md5b64)
            }

            $resp = $client.PutAsync($blockUri, $content).GetAwaiter().GetResult()
            if (-not $resp.IsSuccessStatusCode) {
                $err = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                throw "Put Block failed at index $index (size=$read, HTTP $([int]$resp.StatusCode)): $err"
            }

            $totalBytesSent += $read
            $index++
        }
    }
    finally {
        $fs.Dispose()
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="utf-8"?><BlockList>')
    $blockIds | ForEach-Object { [void]$sb.Append("<Latest>$($_)</Latest>") }
    [void]$sb.Append('</BlockList>')
    $xml = $sb.ToString()

    $uriList = "$SasUrl&comp=blocklist"
    $xmlContent = New-Object System.Net.Http.StringContent($xml, [Text.Encoding]::UTF8, "application/xml")

    $xmlContent.Headers.Remove("Content-Type") | Out-Null
    $xmlContent.Headers.Add("Content-Type","application/xml")

    $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Put, $uriList)
    $req.Content = $xmlContent
    $req.Headers.Add("x-ms-version","2019-12-12")

    $resp2 = $client.SendAsync($req).GetAwaiter().GetResult()
    if (-not $resp2.IsSuccessStatusCode) {
        $err2 = $resp2.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        throw "Put Block List failed (HTTP $([int]$resp2.StatusCode)): $err2"
    }

    [pscustomobject]@{
        FilePath       = $FilePath
        FileLength     = (Get-Item $FilePath).Length
        ChunkSizeBytes = $ChunkSizeBytes
        BlocksUploaded = $blockIds.Count
        BytesSent      = $totalBytesSent
        Finalized      = $true
    }
}
Start-Transcript -path ".\UploadIntuneWinPrinters.log"

$modules = 'Microsoft.Graph.Authentication', 'Microsoft.Graph.DeviceManagement', 'Microsoft.Graph.Beta.DeviceManagement'
Write-Host -ForegroundColor DarkYellow "Installing Required Modules if they're missing..."
Foreach ($module in $modules) {
if (Get-Module -ListAvailable -Name $module) {
    Write-Host -ForegroundColor Yellow "$module module is already installed"
} 
else {
    Write-Host -ForegroundColor Yellow "Installing the $module Module for Current User"
    Install-Module -Name $module -Scope CurrentUser -Force 
    Write-Host "Installed $module module for current user"
}
}

#Login to Graph
$scopes = @(
  "DeviceManagementApps.ReadWrite.All",
  "DeviceManagementConfiguration.ReadWrite.All",
  "Files.ReadWrite.All"
)
Connect-MgGraph -Scopes $scopes

#Root where all printer packages live
$source = ".\ExportedPrinters"

#Get Base64 value of image for app icon
$imagefile = ".\printericon.jpg"
$imageBytes  = [System.IO.File]::ReadAllBytes((Resolve-Path $imageFile))
$imageBase64 = [Convert]::ToBase64String($imageBytes)

#Find out if we should make printers available to the all users group
$assignmentresponse = Read-Host "Do you want to assign the printers as available to All Users? (Type Y or N)"
$assignmentresponse = $assignmentresponse.Trim().ToUpper()
If ($assignmentresponse -eq "Y") {
    Write-Host "User entered $assignmentresponse - Printers will be assigned as available to All Users" -ForegroundColor Yellow
}
else {
    Write-Host "User entered $assignmentresponse - Printers will be NOT be assigned" -ForegroundColor Yellow
}

Start-Sleep 2

#Loop each printer folder and create Win32 App
$PrinterFolders = Get-ChildItem $source -Directory
:printerloop foreach ($Printerfolder in $PrinterFolders) {
    $printerName   = $Printerfolder.Name
    $intunewinPath = Join-Path $Printerfolder.FullName "install.intunewin"
    $appdetectPath    = Join-Path $Printerfolder.FullName "detection.ps1"

    if (-not (Test-Path $intunewinPath)) {
        Write-Warning "No .intunewin found for $printerName — skipping"
        continue
    }
    if (-not (Test-Path $appdetectPath)) {
        Write-Warning "No detection.ps1 for $printerName — skipping"
        continue
    }
    Write-Host "Creating Win32 App Shell for $printerName..." -ForegroundColor Cyan

    #Create Win32 app shell
    $body = @{
        "@odata.type" = "#microsoft.graph.win32LobApp"
        displayName   = "Printer - $printerName"
        description   = "Installs printer $printerName with packaged driver."
        publisher     = "SMBtotheCloud"
        isFeatured    = $false
        setupFilePath = "install.ps1"
        fileName      = "install.intunewin"
        installCommandLine   = '%windir%\sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -NoProfile -File .\install.ps1'
        uninstallCommandLine = 'powershell.exe -executionpolicy bypass .\uninstall.ps1'
        installExperience    = @{ runAsAccount = "system" }
        applicableArchitectures = "x64"
        minimumSupportedOperatingSystem = @{ v10_2004 = $true }
        detectionRules = @(
            @{
                "@odata.type" = "#microsoft.graph.win32LobAppPowerShellScriptDetection"
                scriptContent  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($appdetectPath))
                enforceSignatureCheck = $false
                runAs32Bit   = $false
            }
        )
        returnCodes = @(
            @{ type = "success";  returnCode = 0 },
            @{ type = "success";  returnCode = 3010 },
            @{ type = "failed";   returnCode = 1603 }
        )
        largeIcon = @{
            type = "image/png"
            value = "$imageBase64"
        }
    }

#Send Win32 App Shell and get appID
$app = Invoke-MgGraphRequest -Method POST -Uri "/beta/deviceAppManagement/mobileApps" -Body ($body | ConvertTo-Json -Depth 10 -Compress)
$appId = $app.id

#Create directory for extracted .intunewin contents, set locations and get info from detectionXML
$tempRoot = Join-Path (Get-Location).Path "ExtractedIntuneWinFiles"
$safePrinterName = ($PrinterName -replace '[<>:"/\\|?*]', '_')
$temp = Join-Path $tempRoot ("$safePrinterName" + "_" + $appId)
New-Item -ItemType Directory -Path $temp -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($intunewinPath, $temp) #need to use this because of file extension
[xml]$detectionxml = Get-Content (Join-Path $temp 'IntuneWinPackage\Metadata\Detection.xml')
$unencryptedSize = [int64]$detectionxml.ApplicationInfo.UnencryptedContentSize
$innerintunewin = Get-ChildItem -Path (Join-Path $temp 'IntuneWinPackage\Contents\') -Filter *.intunewin
$encryptedsize = [int64]$innerintunewin.Length

#Get Encryption Info from detection.xml for commit to finish Win32App creation
$encXml = $detectionxml.ApplicationInfo.EncryptionInfo
$commitBody = @{ fileEncryptionInfo = @{
  encryptionKey        = $encXml.EncryptionKey
  fileDigest           = $encXml.FileDigest
  fileDigestAlgorithm  = $encXml.FileDigestAlgorithm
  initializationVector = $encXml.InitializationVector
  mac                  = $encXml.Mac
  macKey               = $encXml.MacKey
  profileIdentifier    = $encXml.ProfileIdentifier
}} | ConvertTo-Json -Depth 10

#Set info for intunewin file. Need to send this to generate SAS URL. 
$packagejson = @{
    name          = (Split-Path $intunewinPath -Leaf)      
    size          = $unencryptedSize                
    sizeEncrypted = $encryptedsize                  
    manifest      = $null
    isDependency  = $false
  } | ConvertTo-Json -Depth 6

#Create new Content Version
$cv = Invoke-MgGraphRequest POST "/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions" -Body "{}" -ContentType "application/json"
$cvId = $cv.id

#Register file upload for new CV
$fileObj = Invoke-MgGraphRequest -Method POST -Uri "/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files" -Body $packageJson -ContentType "application/json"
$fileID = $fileobj.id
Write-Host "New Content Version $cvid has been created. Waiting for SAS URL to be generated..." -ForegroundColor Cyan

#Wait for SAS URL to populate so we can upload intunewin
do {
    Start-Sleep 2
    $fileObjstatus = Invoke-MgGraphRequest -Method GET -Uri "/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$($fileObj.id)"
    } while (-not $fileObjstatus.azureStorageUri)
Start-Sleep 2
Write-Host "Starting upload of intunewin file to Intune" -ForegroundColor Cyan

#upload .intunewin file
$uploadResult = Upload-IntuneWinFile -FilePath $innerIntunewin.FullName -SasUrl $fileObjStatus.azureStorageUri -ChunkSizeBytes 16MB -SendContentMD5
$uploadResult | Format-List

start-sleep 3

#Commit App
Invoke-MgGraphRequest POST "/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId/commit" -Body $commitBody -ContentType "application/json"

#Point app at new CV after upload state moved to commitFileSuccess. Timeout of 90 seconds to prevent the script from hanging. 
Write-Host "App committed. Waiting for file upload state to move to success before assigning content version" -ForegroundColor Cyan
$startTime = Get-Date
$timeout   = [TimeSpan]::FromSeconds(90)
do {
    Start-Sleep 2
    $appstatus = Invoke-MgGraphRequest GET "/beta/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$cvId/files/$fileId`?$select=id,name,isCommitted,uploadState,size,sizeEncrypted"
    Write-Host "Current State" - $appstatus.uploadState
    $elapsed = (Get-Date) - $startTime
        if ($elapsed -ge $timeout) {
            Write-Warning "Timeout after 90s while waiting for $($PrinterFolder.Name). Deleting printer app and moving onto the next printer"
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "/beta/deviceAppManagement/mobileApps/$AppId"
                Write-Host "Deleted orphaned app for $printerName" -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Failed to delete orphaned app for $printerName : $($_.Exception.Message)"
            }
            continue printerloop
        }
        if ($appstatus.uploadState -eq "commitFileFailed")
        {
            Write-Warning "Commit File Failed for $printername. Deleting App and Moving on to next printer"
            try {
                Invoke-MgGraphRequest -Method DELETE -Uri "/beta/deviceAppManagement/mobileApps/$AppId"
                Write-Host "Deleted orphaned app for $printerName" -ForegroundColor Yellow
            }
            catch {
                Write-Warning "Failed to delete orphaned app for $printerName : $($_.Exception.Message)"
            }
            continue printerloop
        }
  } while ($appstatus.uploadstate -ne "commitFileSuccess") 

$patchbody = @{
"@odata.type" = "#microsoft.graph.win32LobApp"
committedContentVersion = "$cvId"   
} | ConvertTo-Json
  
Invoke-MgGraphRequest -Method PATCH -Uri "/beta/deviceAppManagement/mobileApps/$AppId" -Body $patchbody -ContentType "application/json"

#Verify Commited version is correct:
$app = Invoke-MgGraphRequest GET "/beta/deviceAppManagement/mobileApps/$AppId"
Write-Host "Committed version (app) = $($app.committedContentVersion)  (expected $cvId)"
Write-Host "Finished creating deployment for $printername - Moving to the next printer in the list." -ForegroundColor Green

#Assign to All Users if chosen
If ($assignmentresponse -eq "Y") {
    $assignment = @{
        "@odata.type" = "#microsoft.graph.mobileAppAssignment"
        intent        = "available"
        target        = @{
        "@odata.type" = "#microsoft.graph.allLicensedUsersAssignmentTarget"
        }
    } | ConvertTo-Json -Depth 5

    Invoke-MgGraphRequest -Method POST -Uri "/beta/deviceAppManagement/mobileApps/$AppId/assignments" -Body $assignment -ContentType "application/json"
}
}

Disconnect-MgGraph
Stop-Transcript