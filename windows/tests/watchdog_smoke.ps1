param([Parameter(Mandatory=$true)][string]$BuildDirectory)
$ErrorActionPreference = 'Stop'
$BuildDirectory = (Resolve-Path $BuildDirectory).Path
$launcher = Join-Path $BuildDirectory 'SignageXWatchdog.exe'
$player = Join-Path $BuildDirectory 'SignageXPlayer.exe'
$record = Join-Path $BuildDirectory 'launches.txt'
$previousMode = $env:SIGNAGEX_WATCHDOG_TEST_MODE

function Wait-Exit($process, [int]$milliseconds = 15000) {
  if (-not $process.WaitForExit($milliseconds)) { throw "Process did not exit: $($process.Id)" }
  $process.Refresh()
  return $process.ExitCode
}
function Wait-Launches([int]$count) {
  $deadline = (Get-Date).AddSeconds(15)
  do {
    if (Test-Path $record) {
      $lines = @(Get-Content $record)
      if ($lines.Count -ge $count) { return }
    }
    Start-Sleep -Milliseconds 100
  } while ((Get-Date) -lt $deadline)
  throw "Expected $count launches"
}

try {
  Remove-Item $record -ErrorAction SilentlyContinue
  $env:SIGNAGEX_WATCHDOG_TEST_MODE = 'normal'
  $watcher = Start-Process $launcher -PassThru
  if ((Wait-Exit $watcher) -ne 0) { throw 'Normal close failed' }
  if (@(Get-Content $record).Count -ne 1) { throw 'Normal exit relaunched player' }

  Remove-Item $record
  $env:SIGNAGEX_WATCHDOG_TEST_MODE = 'crash-once'
  $watcher = Start-Process $launcher -PassThru
  Wait-Launches 2
  $duplicate = Start-Process $launcher -PassThru
  if ((Wait-Exit $duplicate 3000) -ne 0) { throw 'Duplicate launcher failed' }
  if (@(Get-Content $record).Count -ne 2) { throw 'Duplicate launched another player' }
  $stopper = Start-Process $launcher -ArgumentList '--stop' -PassThru
  if ((Wait-Exit $stopper) -ne 0) { throw 'Maintenance stop failed' }
  if ((Wait-Exit $watcher) -ne 0) { throw 'Watchdog did not stop' }
  Start-Sleep -Seconds 1
  if (@(Get-Content $record).Count -ne 2) { throw 'Maintenance caused relaunch' }

  # A fresh launcher after maintenance must work (no persistent stop marker).
  $env:SIGNAGEX_WATCHDOG_TEST_MODE = 'normal'
  $watcher = Start-Process $launcher -PassThru
  if ((Wait-Exit $watcher) -ne 0) { throw 'Post-upgrade relaunch failed' }
  if (@(Get-Content $record).Count -ne 3) { throw 'Post-upgrade player not launched' }

  Remove-Item $record
  $env:SIGNAGEX_WATCHDOG_TEST_MODE = 'crash-once'
  $watcher = Start-Process $launcher -PassThru
  Wait-Launches 1
  # Stop during the first crash's five-second backoff, before the retry.
  $stopper = Start-Process $launcher -ArgumentList '--stop' -PassThru
  if ((Wait-Exit $stopper) -ne 0) { throw 'Backoff stop failed' }
  if ((Wait-Exit $watcher) -ne 0) { throw 'Backoff watchdog did not stop' }
  if (@(Get-Content $record).Count -ne 1) { throw 'Stop during backoff relaunched player' }

  Rename-Item $player 'SignageXPlayer.saved.exe'
  $watcher = Start-Process $launcher -PassThru
  if ((Wait-Exit $watcher) -eq 0) { throw 'Missing executable must report failure' }
  Write-Host 'Native watchdog smoke tests passed'
} finally {
  # Restrict cleanup to processes in this test directory, never a real player.
  Get-Process SignageXWatchdog,SignageXPlayer -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and (Split-Path $_.Path) -eq $BuildDirectory } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  $saved = Join-Path $BuildDirectory 'SignageXPlayer.saved.exe'
  if (Test-Path $saved) { Move-Item $saved $player -Force }
  $env:SIGNAGEX_WATCHDOG_TEST_MODE = $previousMode
}
