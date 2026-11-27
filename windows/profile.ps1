# PowerShell 7 profile, dot-sourced from $PROFILE:
#   . "$HOME\Documents\GitHub\nixconf\windows\profile.ps1"

if (Get-Module -ListAvailable PSWriteColor) {
    Write-Color -Text "  ____  _     _     _           _     " -Color Blue, DarkCyan, Cyan
    Write-Color -Text " |  _ \(_)___| |__ | |__   ___ | |__  " -Color Blue, Cyan
    Write-Color -Text " | |_) | / __| '_ \| '_ \ / _ \| '_ \ " -Color Blue, DarkCyan, Cyan
    Write-Color -Text " |  _ <| \__ \ | | | |_) | (_) | |_) |" -Color Blue, DarkCyan, Cyan
    Write-Color -Text " |_| \_\_|___/_| |_|_.__/ \___/|_.__/ " -Color Blue, DarkBlue, DarkCyan, Cyan
    Write-Host ""
}

Set-PSReadLineOption -PredictionSource History
Set-PSReadLineOption -PredictionViewStyle ListView

# POSH_THEMES_PATH is set by the oh-my-posh winget package.
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\bubbles.omp.json" | Invoke-Expression
}

# Prints a timestamp every 5s; handy for spotting when a remote session or the VM stalls.
function heartbeat {
    Write-Host "--- Heartbeat Started (Ctrl+C to stop) ---" -ForegroundColor Cyan
    while ($true) {
        Write-Host "[$(Get-Date -Format HH:mm:ss)] Alive" -ForegroundColor Green
        Start-Sleep -Seconds 5
    }
}

# Live per-adapter dedicated VRAM usage (10 Hz). Bars are scaled to 5 GB (20 x 256 MB).
function gvtop {
    $cursorWasVisible = [Console]::CursorVisible
    [Console]::CursorVisible = $false
    Clear-Host
    try {
        while ($true) {
            # Overwrite in place instead of clearing, so it doesn't flicker.
            [Console]::SetCursorPosition(0, 0)
            Write-Host "--- GPU VRAM (Ctrl+C to exit) ---" -ForegroundColor Cyan
            $data = Get-Counter "\GPU Adapter Memory(*)\Dedicated Usage" -ErrorAction SilentlyContinue
            if ($data) {
                foreach ($sample in $data.CounterSamples) {
                    $mb = [Math]::Round($sample.CookedValue / 1MB, 2)
                    $bar = ("|" * [Math]::Min([Math]::Floor($mb / 256), 20)).PadRight(20, ".")
                    Write-Host ("{0,-25} : [{1}] {2,10} MB" -f $sample.InstanceName, $bar, $mb)
                }
            } else {
                Write-Host "Searching for GPU counters..." -ForegroundColor Yellow
            }
            Start-Sleep -Milliseconds 100
        }
    } finally {
        [Console]::CursorVisible = $cursorWasVisible
    }
}
