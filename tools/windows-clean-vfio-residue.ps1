param(
    [switch]$RemovePresent
)

$ErrorActionPreference = "Stop"

$pattern = "QEMU|BOCHS|KVM|VIRTIO|VEN_QEMU|VEN_REDHAT|SPICE|QXL|VMWARE|VBOX|XEN|VIOSCSI|VIOSTOR|NETKVM|BALLOON|VDAGENT"

Write-Host "Suspicious currently-present PnP devices:"
$present = Get-PnpDevice -PresentOnly | Where-Object {
    $_.InstanceId -match $pattern -or $_.FriendlyName -match $pattern
}
$present | Format-Table Status,Class,FriendlyName,InstanceId -AutoSize

Write-Host ""
Write-Host "Suspicious non-present/stale PnP devices:"
$stale = Get-PnpDevice | Where-Object {
    -not ($present.InstanceId -contains $_.InstanceId) -and
    ($_.InstanceId -match $pattern -or $_.FriendlyName -match $pattern)
}
$stale | Format-Table Status,Class,FriendlyName,InstanceId -AutoSize

if ($stale.Count -gt 0) {
    Write-Host ""
    Write-Host "Removing stale suspicious PnP device records..."
    foreach ($device in $stale) {
        Write-Host "pnputil /remove-device `"$($device.InstanceId)`""
        pnputil /remove-device "$($device.InstanceId)" | Out-Host
    }
}

if ($RemovePresent -and $present.Count -gt 0) {
    Write-Host ""
    Write-Host "Removing present suspicious PnP devices because -RemovePresent was requested..."
    foreach ($device in $present) {
        Write-Host "pnputil /remove-device `"$($device.InstanceId)`" /force"
        pnputil /remove-device "$($device.InstanceId)" /force | Out-Host
    }
} elseif ($present.Count -gt 0) {
    Write-Host ""
    Write-Host "Present suspicious devices were left alone. Reboot after host-side fixes, then rerun this script."
}

