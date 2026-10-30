# check-restart-race.ps1  v0.3.0
# Read-only check: does Windows' own log show the "restart race" pattern after
# a Razer BIOS update attempt? It changes NOTHING, needs no administrator
# rights, and prints no user or computer names.
#
# Run it:  open PowerShell in the folder where you saved this file, then:
#          powershell -NoProfile -ExecutionPolicy Bypass -File .\check-restart-race.ps1
#   Look further back:   ... -Days 90
#   Wider time window:   ... -WindowSeconds 30
#
# For every run of AMI's flasher (AFUWINx64.EXE), it looks for:
#   1. Event 1074 from AFUWINx64.EXE: the flasher asks Windows to shut down.
#   2. Event 1074 from shutdown.exe within a few seconds: a request whose
#      shutdown/restart type must be checked.
#   3. The next Kernel-Power 109 and its numeric action type: 4 = shutdown,
#      5 = shutdown/reset (a restart), 6 = shutdown/power-off. This number does
#      not depend on the language of Windows. It records a transition that was
#      started, not proof that it completed.
# "POSSIBLE RESTART RACE" = 1, then 2, then a 109 with action type 5, in that
# order. Check the request types shown: the flasher should ask for a shutdown,
# and shutdown.exe for a restart. Event timing alone does not prove what
# caused a failed update; it shows that the sequence was present.
#
# Made by Claude (Opus 5.5, an AI model by Anthropic) after one Razer Blade 16
# (2025) update. MIT licence. Not affiliated with Razer or AMI.

param(
  [int]$Days = 30,
  [int]$WindowSeconds = 15
)

if ($Days -lt 1 -or $Days -gt 3650) { Write-Host 'Days must be between 1 and 3650.'; exit 2 }
if ($WindowSeconds -lt 1 -or $WindowSeconds -gt 300) { Write-Host 'WindowSeconds must be between 1 and 300.'; exit 2 }

function Get-Field($ev, [string]$name) {
  $x = [xml]$ev.ToXml()
  $n = $x.Event.EventData.Data | Where-Object { $_.Name -eq $name } | Select-Object -First 1
  if ($n) { return [string]$n.'#text' } else { return '' }
}
function Get-ExeName([string]$s) {
  # "C:\Windows\SysWOW64\shutdown.exe (PC-NAME)" -> "shutdown.exe"
  $m = [regex]::Match($s, '([^\\/ ]+\.exe)', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value } else { return '' }
}

Write-Host ''
Write-Host 'Razer BIOS update: restart-race check v0.3.0 (read-only, changes nothing)'
Write-Host '-------------------------------------------------------------------------'
$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
if ($cs) { Write-Host ('Laptop:   ' + $cs.Manufacturer + ' ' + $cs.Model) }
if ($bios) {
  $rd = ''
  if ($bios.ReleaseDate) { $rd = ' (dated ' + $bios.ReleaseDate.ToString('yyyy-MM-dd') + ')' }
  Write-Host ('BIOS now: ' + $bios.SMBIOSBIOSVersion + $rd)
}
foreach ($e in @(Get-ChildItem 'HKLM:\HARDWARE\UEFI\ESRT' -ErrorAction SilentlyContinue)) {
  $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
  if ($p -and $p.Type -eq 1) {
    Write-Host ('Firmware update record (ESRT): version ' + $p.Version + ', last attempted ' + $p.LastAttemptVersion + ', last status ' + $p.LastAttemptStatus)
    Write-Host '  If you tried to install a newer version and "last attempted" still shows the old one,'
    Write-Host '  no attempt at the newer version was recorded.'
  }
}

Write-Host ''
Write-Host ('Reading the last ' + $Days + ' days of the System log ...')
$since = (Get-Date).AddDays(-$Days)
try {
  $all1074 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = 1074; StartTime = $since } -ErrorAction Stop | Sort-Object TimeCreated)
} catch {
  if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $all1074 = @() }
  else { Write-Host ('Could not read the System log: ' + $_.Exception.Message); Write-Host 'RESULT: UNKNOWN (log not readable).'; exit 3 }
}
try {
  $all109 = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 109; StartTime = $since } -ErrorAction Stop | Sort-Object TimeCreated)
} catch { $all109 = @() }

$afu = @($all1074 | Where-Object { (Get-ExeName (Get-Field $_ 'param1')) -match '^AFUWIN' })
if ($afu.Count -eq 0) {
  Write-Host 'No BIOS flasher run (AFUWINx64.EXE) found in this period.'
  Write-Host 'RESULT: NO EVIDENCE. Run it again with -Days 90, or right after a failed update.'
  exit 0
}

$race = 0; $off = 0; $unclassified = 0
foreach ($a in $afu) {
  $t0 = $a.TimeCreated
  $sx = $all1074 | Where-Object { $_.TimeCreated -gt $t0 -and $_.TimeCreated -le $t0.AddSeconds($WindowSeconds) -and (Get-ExeName (Get-Field $_ 'param1')) -ieq 'shutdown.exe' } | Select-Object -First 1
  $kp = $all109 | Where-Object { $_.TimeCreated -ge $t0 -and $_.TimeCreated -le $t0.AddSeconds(120) } | Select-Object -First 1
  $act = ''
  if ($kp) { $act = Get-Field $kp 'ShutdownActionType' }
  $line = $t0.ToString('yyyy-MM-dd HH:mm:ss') + '  [record ' + $a.RecordId + ']  flasher asked: "' + (Get-Field $a 'param5') + '"'
  if ($sx) {
    $gap = [Math]::Round(($sx.TimeCreated - $t0).TotalSeconds, 1)
    $line += '; ' + $gap + ' s later shutdown.exe asked: "' + (Get-Field $sx 'param5') + '" [record ' + $sx.RecordId + ']'
  } else {
    $line += '; no shutdown.exe within ' + $WindowSeconds + ' s'
  }
  if ($kp) { $line += '; Kernel-Power 109 recorded action type ' + $act + ' (4 = shutdown, 5 = shutdown/reset, 6 = shutdown/power-off)' } else { $line += '; no Kernel-Power 109 found within 120 s' }

  if ($sx -and $kp -and $kp.TimeCreated -ge $sx.TimeCreated -and $act -eq '5') { $race++; Write-Host ($line + '  ==> POSSIBLE RESTART RACE') }
  elseif ($act -eq '4' -or $act -eq '6') { $off++; Write-Host ($line + '  ==> shutdown transition recorded') }
  else { $unclassified++; Write-Host ($line + '  ==> UNCLASSIFIED') }
}

Write-Host ''
Write-Host ('RESULT: ' + $race + ' possible restart race(s); ' + $off + ' run(s) with a shutdown transition recorded; ' + $unclassified + ' run(s) unclassified.')
if ($race -gt 0) {
  Write-Host 'Possible restart-race sequence found. Verify the displayed request types and updater configuration before drawing conclusions.'
  Write-Host 'Read README.md first, and open a Razer support case. Our report is from one laptop, not a general fix.'
} elseif ($unclassified -gt 0) {
  Write-Host 'Some runs could not be classified. Compare the events by hand (README, section 1).'
} else {
  Write-Host 'No run matches the sequence, so our report probably does not apply to you.'
}
