<#
.SYNOPSIS
  Make a backup whose name and timestamp cannot disagree.
.DESCRIPTION
  Every naive backup script has the same bug: it writes today's date into the
  filename, then Copy-Item carries the SOURCE file's modification time onto the
  copy. The name says when the backup was taken. The mtime says when the file
  was last changed. They disagree, the name looks authoritative, and you restore
  the wrong file.

  This function forces the two to be the same fact.
.PARAMETER Path
  File to back up.
.PARAMETER Destination
  Backup folder. Created if missing.
.PARAMETER Mode
  Stamp  - name carries the date, and mtime is set to the same moment (default).
  Hash   - name carries a content hash. No date to be wrong about.
.PARAMETER Verify
  Read the copy back and compare SHA256 with the source. On by default.
.EXAMPLE
  Safe-Backup.ps1 -Path C:\app\config.json -Destination C:\app\backups
.EXAMPLE
  Safe-Backup.ps1 -Path C:\app\config.json -Destination C:\app\backups -Mode Hash
#>
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$Destination,
  [ValidateSet('Stamp','Hash')][string]$Mode = 'Stamp',
  [switch]$KeepBoth
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) { throw "Source not found: $Path" }
if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Force -Path $Destination | Out-Null }

$src = Get-Item $Path
$srcHash = (Get-FileHash $Path -Algorithm SHA256).Hash
$now = Get-Date

if ($Mode -eq 'Hash') {
  $name = "$($src.Name).$($srcHash.Substring(0,16)).bak"
} else {
  $name = "$($src.Name).bak-$($now.ToString('yyyyMMdd-HHmmss'))"
}

$dest = Join-Path $Destination $name

# Dedupe by CONTENT across the whole folder, not by name collision.
# A same-second name clash is not evidence the content is already saved.
if (-not $KeepBoth) {
  $prior = Get-ChildItem $Destination -Filter "$($src.Name)*" -File -ErrorAction SilentlyContinue |
           ForEach-Object { [pscustomobject]@{ Path = $_.FullName; Hash = (Get-FileHash $_.FullName -Algorithm SHA256).Hash } } |
           Where-Object { $_.Hash -eq $srcHash } | Select-Object -First 1
  if ($prior) {
    Write-Output "UNCHANGED $($prior.Path) (identical content already backed up)"

  }
}

Copy-Item $Path $dest -Force

# THE FIX: in Stamp mode, force the mtime to the moment the name claims.
if ($Mode -eq 'Stamp') {
  (Get-Item $dest).LastWriteTime = $now
}

# Verify by reading it back, not by trusting Copy-Item.
$copyHash = (Get-FileHash $dest -Algorithm SHA256).Hash
if ($copyHash -ne $srcHash) {
  throw "VERIFY FAILED: copy does not match source. src=$($srcHash.Substring(0,16)) dst=$($copyHash.Substring(0,16))"
}

Write-Output "OK $dest (sha256 verified, $Mode mode)"
