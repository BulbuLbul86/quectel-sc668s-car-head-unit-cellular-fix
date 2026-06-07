param(
    [Parameter(Mandatory = $true)]
    [string]$Device,

    [Parameter(Mandatory = $true)]
    [string]$Image,

    [string]$Adb = ".\adb.exe"
)

$ErrorActionPreference = "Stop"

$ExpectedImageBytes = 95014912
$ExpectedPartitionBytes = 188743680
$ExpectedImageSha256 = "88602460D786BEB88DD63352A10F22CD53CBA15E8CA2F122144548B96EA97102"
$ExpectedWrittenPartitionSha256 = "DE6582A856D4C659C679A160102051FFEAE3B8DB9FB032C01380A96712EE8BD2"
$ImageBlocks = 23197
$TailBlocks = 22883
$BlockSize = 4096

function Invoke-Adb {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

    & $Adb -s $Device @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "ADB command failed: $($Arguments -join ' ')"
    }
}

if (-not (Test-Path -LiteralPath $Adb)) {
    throw "adb.exe not found: $Adb"
}

if (-not (Test-Path -LiteralPath $Image)) {
    throw "modem image not found: $Image"
}

$imageFile = Get-Item -LiteralPath $Image
if ($imageFile.Length -ne $ExpectedImageBytes) {
    throw "Unexpected modem.img size: $($imageFile.Length)"
}

$imageHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Image).Hash
if ($imageHash -ne $ExpectedImageSha256) {
    throw "Unexpected modem.img SHA256: $imageHash"
}

& $Adb connect $Device
if ($LASTEXITCODE -ne 0) {
    throw "Cannot connect to $Device"
}

$state = (Invoke-Adb get-state | Out-String).Trim()
if ($state -ne "device") {
    throw "Device is not ready: $state"
}

$uid = (Invoke-Adb shell id -u | Out-String).Trim()
if ($uid -ne "0") {
    throw "Root ADB is required. Current uid: $uid"
}

$slot = (Invoke-Adb shell getprop ro.boot.slot_suffix | Out-String).Trim()
if ($slot -ne "_a") {
    throw "This script only writes active slot A. Current slot: $slot"
}

$partitionBytes = [int64]((Invoke-Adb shell blockdev --getsize64 /dev/block/by-name/modem_a | Out-String).Trim())
if ($partitionBytes -ne $ExpectedPartitionBytes) {
    throw "Unexpected modem_a size: $partitionBytes"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path (Get-Location) "backup-$timestamp-modem_a.img"

Write-Host "Saving current modem_a to $backup"
& $Adb -s $Device pull /dev/block/by-name/modem_a $backup
if ($LASTEXITCODE -ne 0) {
    throw "Failed to create modem_a backup"
}

$backupFile = Get-Item -LiteralPath $backup
if ($backupFile.Length -ne $ExpectedPartitionBytes) {
    throw "Backup size is invalid: $($backupFile.Length)"
}

$backupHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $backup).Hash
Write-Host "Backup SHA256: $backupHash"

$confirmation = Read-Host "Type FLASH-MODEM-A to continue"
if ($confirmation -cne "FLASH-MODEM-A") {
    throw "Cancelled"
}

$remoteImage = "/data/local/tmp/modem_prepcn.img"
& $Adb -s $Device push $Image $remoteImage
if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload modem image"
}

$remoteHash = ((Invoke-Adb shell sha256sum $remoteImage | Out-String) -split "\s+")[0].ToUpperInvariant()
if ($remoteHash -ne $ExpectedImageSha256) {
    throw "Uploaded image SHA256 mismatch: $remoteHash"
}

Invoke-Adb shell blockdev --setrw /dev/block/by-name/modem_a | Out-Null
$readOnly = (Invoke-Adb shell blockdev --getro /dev/block/by-name/modem_a | Out-String).Trim()
if ($readOnly -ne "0") {
    throw "Could not make modem_a writable"
}

Write-Host "Writing modem_a. Do not disconnect power."
Invoke-Adb shell dd "if=$remoteImage" "of=/dev/block/by-name/modem_a" "bs=$BlockSize"
Invoke-Adb shell dd "if=/dev/zero" "of=/dev/block/by-name/modem_a" "bs=$BlockSize" "seek=$ImageBlocks" "count=$TailBlocks"
Invoke-Adb shell sync

$writtenHash = ((Invoke-Adb shell sha256sum /dev/block/by-name/modem_a | Out-String) -split "\s+")[0].ToUpperInvariant()
if ($writtenHash -ne $ExpectedWrittenPartitionSha256) {
    throw "Written modem_a SHA256 mismatch: $writtenHash. Restore the local backup before rebooting."
}

Invoke-Adb shell blockdev --setro /dev/block/by-name/modem_a | Out-Null
Invoke-Adb shell rm -f $remoteImage

Write-Host "modem_a written and verified successfully."
Write-Host "Backup: $backup"
Write-Host "Backup SHA256: $backupHash"
Write-Host "Rebooting device. Wireless ADB port may change."
Invoke-Adb reboot

