# Maps D: to the data4 share as SYSTEM at boot, so Macrium Reflect (which runs
# as SYSTEM) has a backup target. Your own Z: mapping is separate and stays.
# Uses credentials already stored for SYSTEM (cmdkey); none are in this file.
#
# Run as SYSTEM from the \AutoMountD\AutoMountD scheduled task:
#   powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File <this script>

$ProgressPreference = 'SilentlyContinue'

$DriveLetter = "D:"
$Server      = "10.0.0.3"   # rishabh-nix on br0
$Share       = "\\$Server\data4"
$MaxRetries  = 5
$RetryDelay  = 15           # seconds; the VM can boot before Samba is up

function Log($Msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $Msg" }

# Bare-metal boots see the data4 disk directly as a local D:.
$volume = Get-Volume -DriveLetter $DriveLetter.TrimEnd(':') -ErrorAction SilentlyContinue
if ($volume -and $volume.DriveType -eq 'Fixed') {
    Log "Local data4 disk found on $DriveLetter; nothing to map."
    exit 0
}

for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    Log "Attempt $attempt/$($MaxRetries): checking ${Server}:445"
    if ((Test-NetConnection $Server -Port 445 -WarningAction SilentlyContinue).TcpTestSucceeded) {
        net use $DriveLetter /delete /y 2>&1 | Out-Null
        $out = net use $DriveLetter $Share /persistent:no 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "Mapped $DriveLetter -> $Share"
            exit 0
        }
        Log "net use failed ($LASTEXITCODE): $out"
    } else {
        Log "Samba not reachable yet."
    }
    if ($attempt -lt $MaxRetries) { Start-Sleep -Seconds $RetryDelay }
}

Log "Giving up: no backup target."
exit 1
