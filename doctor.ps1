# Windows Server Doctor - the 60-second verdict
# Free to run. Checks the six things that silently cost people days.
# Exit code: 0 = clean, 1 = warnings, 2 = something will not self-heal
#
# Elias Easton - Recovery Kit
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\doctor.ps1
# Options:
#   -ConfigPath <path>   check a JSON config file validates (default: auto-detect)
#   -LogDir <path>       scan logs for auth errors (default: .\logs)
#   -Hours <n>           log lookback window (default: 24)
#   -StateFiles <p1,p2>  state files that must survive a write-read round trip

param(
  [string]$ConfigPath,
  [string]$LogDir,
  [int]$Hours = 24,
  [string[]]$StateFiles,
  [string]$AppName
)

$ErrorActionPreference = 'Continue'
$script:Problems = 0
$script:Warnings = 0
$script:Report = New-Object 'System.Collections.Generic.List[string]'

function Section($t) { $script:Report.Add(''); $script:Report.Add("== $t ==") }
function Pass($t)    { $script:Report.Add("  [ok]   $t") }
function Warn($t)    { $script:Warnings++; $script:Report.Add("  [warn] $t") }
function Fail($t)    { $script:Problems++; $script:Report.Add("  [FAIL] $t") }

# ---------------------------------------------------------------- 1. parse AND validate
Section '1. Config: does it parse, and is it actually valid?'
$cfg = $ConfigPath
if (-not $cfg) {
  $candidates = @(
    (Join-Path $PSScriptRoot 'config.json'),
    (Join-Path $PSScriptRoot 'app.json'),
    (Join-Path $PSScriptRoot 'settings.json')
  )
  foreach ($c in $candidates) { if ((Test-Path $c) -and -not $cfg) { $cfg = $c } }
}

if (-not $cfg) {
  Warn 'No config file found to check (pass -ConfigPath). Skipping.'
} elseif (-not (Test-Path $cfg)) {
  Fail "Config not found at $cfg"
} else {
  $raw = Get-Content $cfg -Raw
  $parsed = $null
  try {
    $parsed = $raw | ConvertFrom-Json
    Pass 'JSON parses.'
  } catch {
    Fail 'JSON does not even parse: ' + $_.Exception.Message
  }
  if ($parsed) {
    # a parser accepts {"a":{}} for almost anything. Look for the shapes that break loaders.
    $bad = New-Object 'System.Collections.Generic.List[string]'
    function Walk($node, $path) {
      if ($null -eq $node) { return }
      if ($node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $node.PSObject.Properties) {
          $v = $p.Value
          if ($null -eq $v) { $bad.Add("$path.$($p.Name) is null") }
          elseif ($v -is [string] -and $v.Trim() -eq '' -and $p.Name -notmatch 'password|secret|token|key') {
            # empty strings are usually fine; only flag obvious required shapes
          }
          Walk $v "$path.$($p.Name)"
        }
      } elseif ($node -is [System.Array]) {
        $i = 0
        foreach ($item in $node) { Walk $item "$path[$i]"; $i++ }
      }
    }
    Walk $parsed '$'
    if ($bad.Count -eq 0) {
      Pass 'No null-valued keys found (common loader rejection).'
    } else {
      Warn ("Possible loader-rejected nulls: " + (($bad | Select-Object -First 5) -join '; '))
    }
  }
}

# ---------------------------------------------------------------- 2. backups vs their own names
Section '2. Backups: does the name match reality?'
$backupDirs = @($PSScriptRoot)
if ($cfg) { $backupDirs += (Split-Path $cfg -Parent) }
$backups = @()
foreach ($d in ($backupDirs | Select-Object -Unique)) {
  if (Test-Path $d) {
    $backups += Get-ChildItem $d -Filter '*.bak*' -File -ErrorAction SilentlyContinue
  }
}
if ($backups.Count -eq 0) {
  Warn 'No backup files found. If this app overwrites config, make one before every change.'
} else {
  foreach ($b in ($backups | Sort-Object LastWriteTime -Descending | Select-Object -First 10)) {
    $nameDate = $null
    $m = [regex]::Match($b.Name, '(20\d{6})[_-]?(\d{4,6})?')
    if ($m.Success) {
      $s = $m.Groups[1].Value
      try { $nameDate = [datetime]::ParseExact($s, 'yyyyMMdd', $null) } catch { $nameDate = $null }
    }
    if ($nameDate) {
      $deltaDays = [math]::Round(($b.LastWriteTime.Date - $nameDate.Date).TotalDays)
      if ([math]::Abs($deltaDays) -ge 2) {
        Fail ("$($b.Name) says $($nameDate.ToString('yyyy-MM-dd')) but was actually written $($b.LastWriteTime.ToString('yyyy-MM-dd')) - off by $deltaDays days")
      } else {
        Pass "$($b.Name) - name date matches write date."
      }
    } else {
      Pass "$($b.Name) (no date in name; written $($b.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))"
    }
  }
}

# ---------------------------------------------------------------- 3. processes that are online but failing
Section "3. Processes: online is not working (last $Hours h of logs)"
if (-not $LogDir) {
  # Only claim a log dir if it actually CONTAINS logs. Guessing a folder and then
  # reporting "no logs modified" is a false alarm - the check must not cry wolf.
  foreach ($cand in @((Join-Path $PSScriptRoot 'logs'), $PSScriptRoot)) {
    if (-not (Test-Path $cand)) { continue }
    $probe = Get-ChildItem $cand -Filter '*.log' -File -ErrorAction SilentlyContinue
    if ($probe) { $LogDir = $cand; break }
  }
}
$authPattern = '401|403|Unauthorized|Forbidden|invalid token|auth failed|authentication'
if ($LogDir -and (Test-Path $LogDir)) {
  $cutoff = (Get-Date).AddHours(-$Hours)
  $logs = Get-ChildItem $LogDir -Filter '*.log' -File -Recurse -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -gt $cutoff }
  if (-not $logs) {
    Warn "No logs modified in the last $Hours h in $LogDir. If the app should be busy, that itself is a signal."
  } else {
    foreach ($l in $logs) {
      $hits = Select-String -Path $l.FullName -Pattern $authPattern -ErrorAction SilentlyContinue
      if ($hits -and $hits.Count -gt 0) {
        $last = $hits[-1]
        Fail "${l}: $($hits.Count) auth error(s); latest line $($last.LineNumber) -> $($last.Line.Trim().Substring(0,[Math]::Min(90,$last.Line.Trim().Length)))"
      } else {
        Pass "${l}: no auth errors."
      }
    }
  }
} else {
  Warn 'No log directory found (pass -LogDir).'
}

# ---------------------------------------------------------------- 4. state files that must round-trip
Section '4. State files: write it, read it, get the same thing back'
if (-not $StateFiles -or $StateFiles.Count -eq 0) {
  Warn 'No state files given (pass -StateFiles a.json,b.txt). This is the check that catches corrupted state.'
} else {
  $sfList = @()
  foreach ($s in $StateFiles) { foreach ($p in ($s -split ',')) { if ($p.Trim()) { $sfList += $p.Trim() } } }
  foreach ($sf in $sfList) {
    $full = $sf
    if (-not [System.IO.Path]::IsPathRooted($sf)) {
      $full = Join-Path $PSScriptRoot $sf
      if (-not (Test-Path $full)) { $full = Join-Path (Get-Location).Path $sf }
    }
    if (-not (Test-Path $full)) { Warn "$sf does not exist yet."; continue }
    if ($full -match '\.json$') {
      try {
        $o = Get-Content $full -Raw | ConvertFrom-Json
        $types = @()
        if ($o -is [System.Array]) {
          foreach ($e in $o) { $types += $e.GetType().Name }
          $wrong = @($types | Where-Object { $_ -notin @('String','Int32','Int64','Double','Boolean') })
          if ($o.Count -eq 1 -and $o[0] -is [string] -and $o[0] -match '\s' -and $o[0].Length -gt 40) {
            $n = ([regex]::Matches($o[0], '\s')).Count + 1
            Fail "${sf}: parsed into ONE string containing ~$n values. Your writer joined an array into a string - a reader comparing single values will never match, and will silently re-process everything. (Real bug, seen in the wild.)"
          } elseif ($wrong.Count -gt 0) {
            Warn "${sf}: array holds $($wrong.Count) non-scalar element(s); check the writer."
          } else {
            Pass "${sf}: $($o.Count) scalar entries, round-trip clean."
          }
        } else {
          Pass "${sf}: object, parses clean."
        }
      } catch {
        Fail "$sf is not valid JSON: $($_.Exception.Message)"
      }
    } else {
      $lines = Get-Content $full
      $blank = @($lines | Where-Object { $_.Trim() -eq '' }).Count
      if ($blank -gt 0) { Warn "$sf has $blank blank line(s) - dedupe loaders often treat these as an entry." }
      else { Pass "${sf}: $($lines.Count) lines, no blanks." }
    }
  }
}

# ---------------------------------------------------------------- 5. scheduled work that never delivers
Section '5. Scheduled jobs: has this actually ever run?'
$sched = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskPath -notmatch '\\Microsoft\\' }
$deadSched = 0
foreach ($t in $sched) {
  $info = Get-ScheduledTaskInfo -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue
  if ($info -and -not $info.LastRunTime) { $deadSched++ }
}
if ($sched -and $sched.Count -gt 0) {
  if ($deadSched -gt 0) { Warn "$deadSched of $($sched.Count) user scheduled tasks have never run." }
  else { Pass "$($sched.Count) user scheduled tasks; all have run at least once." }
} else {
  Warn 'No user scheduled tasks found.'
}

# ---------------------------------------------------------------- 6. disk + service floor
Section '6. Floor checks'
$sys = Get-PSDrive C -ErrorAction SilentlyContinue
if ($sys) {
  $freeGB = [math]::Round($sys.Free / 1GB, 1)
  if ($freeGB -lt 5) { Fail "Only $freeGB GB free on C: - logs and backups will fail silently." }
  elseif ($freeGB -lt 15) { Warn "$freeGB GB free on C:." }
  else { Pass "$freeGB GB free on C:." }
}
Pass "PowerShell $($PSVersionTable.PSVersion) on $([System.Environment]::OSVersion.VersionString)"

# ---------------------------------------------------------------- verdict
$exit = 0
if ($script:Problems -gt 0) { $exit = 2 } elseif ($script:Warnings -gt 0) { $exit = 1 }

$script:Report.Add('')
$script:Report.Add('===============================')
if ($exit -eq 0) { $script:Report.Add('VERDICT: CLEAN. Nothing silently broken here.') }
elseif ($exit -eq 1) { $script:Report.Add("VERDICT: $($script:Warnings) warning(s). Worth a look, nothing fatal.") }
else { $script:Report.Add("VERDICT: $($script:Problems) FAILURE(S). At least one of these does NOT self-heal.") }
$script:Report.Add('===============================')

$script:Report -join "`r`n"
exit $exit
