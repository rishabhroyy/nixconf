# Adds a ParsecVDisplay virtual monitor (at the Mac's 3024x1900) while a Parsec
# client is connected, and removes it on disconnect. Runs forever; tails both
# Parsec logs: the system one (lock screen sessions) and the user one (desktop).

$LogPaths = @(
    "$env:ProgramData\Parsec\log.txt",
    "$env:APPDATA\Parsec\log.txt"
)
$VDisplay = "$env:ProgramFiles\ParsecVDisplay\ParsecVDisplay.exe"
$Resolution = "3024x1900"

$isConnected = $false
$lastReadPos = @{}
foreach ($path in $LogPaths) { $lastReadPos[$path] = 0 }

while ($true) {
    foreach ($LogPath in $LogPaths) {
        if (-not (Test-Path $LogPath)) { continue }
        $length = (Get-Item $LogPath).Length

        # Parsec truncates its log on restart; start over from the top.
        if ($length -lt $lastReadPos[$LogPath]) { $lastReadPos[$LogPath] = 0 }
        if ($length -eq $lastReadPos[$LogPath]) { continue }

        $stream = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite')
        try {
            $stream.Seek($lastReadPos[$LogPath], 'Begin') | Out-Null
            $reader = New-Object System.IO.StreamReader($stream)
            $newText = $reader.ReadToEnd()
            $lastReadPos[$LogPath] = $stream.Position
        } finally {
            $stream.Close()
        }

        foreach ($line in ($newText -split "`n")) {
            if ($line -match '(?i)client connected|connection accepted') {
                if (-not $isConnected) {
                    $isConnected = $true
                    Start-Process $VDisplay -ArgumentList '-cli add' -NoNewWindow -Wait
                    Start-Process $VDisplay -ArgumentList "-cli set -1 $Resolution" -NoNewWindow -Wait
                }
            } elseif ($line -match '(?i)client disconnected|connection closed|session ended') {
                if ($isConnected) {
                    $isConnected = $false
                    Start-Process $VDisplay -ArgumentList '-cli all' -NoNewWindow -Wait
                }
            }
        }
    }
    Start-Sleep -Seconds 2
}
