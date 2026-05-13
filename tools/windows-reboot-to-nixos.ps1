#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"

$patterns = @(
    "NixOS",
    "Linux Boot Manager",
    "systemd-boot",
    "UEFI OS"
)

$entries = @()
$current = $null

foreach ($line in (& bcdedit /enum firmware)) {
    if ($line -match "^\s*identifier\s+(\{[^}]+\})") {
        if ($current) {
            $entries += [pscustomobject]$current
        }
        $current = @{
            Identifier = $matches[1]
            Description = ""
        }
        continue
    }

    if ($current -and $line -match "^\s*description\s+(.+)$") {
        $current.Description = $matches[1].Trim()
    }
}

if ($current) {
    $entries += [pscustomobject]$current
}

$target = $entries |
    Where-Object {
        $matched = $false
        if ($_.Identifier -notin @("{fwbootmgr}", "{bootmgr}")) {
            foreach ($pattern in $patterns) {
                if ($_.Description -like "*$pattern*") {
                    $matched = $true
                    break
                }
            }
        }
        $matched
    } |
    Select-Object -First 1

if (-not $target) {
    Write-Error "Could not find a NixOS/systemd-boot firmware entry. Run 'bcdedit /enum firmware' and check the entry description."
}

Write-Host "Setting one-time UEFI boot target to $($target.Description) ($($target.Identifier))."
& bcdedit /set "{fwbootmgr}" bootsequence "$($target.Identifier)"
& shutdown /r /t 0
