# Pool runner for the fast path (docs/01-FAST-PATH.md).
# One sticky session per chunk, up to 4 chunks in parallel, unresolved rows re-queued.
#
#   .\runner\run-pool.ps1 -Source .\combo.txt -PoolFile .\proxies.txt
#
# PoolFile: one "user:pass" per line. Duplicate a line to run two sessions on it.
param(
  [Parameter(Mandatory=$true)][string]$Source,
  [Parameter(Mandatory=$true)][string]$PoolFile,
  [int]$Skip = 0,
  [int]$Take = 999999,
  [int]$Chunk = 28,
  [int]$MaxRetries = 2,
  [int]$Pace = 12,
  [int]$MaxWorkers = 4,
  [string]$ProxyHost = "pr.oxylabs.io",
  [int]$ProxyPort = 7777,
  [string]$PuSuffix = "-sesstime-1800",
  [string]$OutDir = ".\runs",
  [string]$RunTag = (Get-Date -Format "yyyyMMdd-HHmmss")
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
if (-not [System.IO.Path]::IsPathRooted($OutDir)) { $OutDir = Join-Path $root $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$pool = @(Get-Content $PoolFile | Where-Object { $_ -match ':' -and $_.Trim() -ne '' } | ForEach-Object {
  $i = $_.IndexOf(':'); [pscustomobject]@{ user = $_.Substring(0, $i); pass = $_.Substring($i + 1) }
})
if ($pool.Count -eq 0) { throw "empty pool: $PoolFile" }
$workers = [Math]::Min($pool.Count, $MaxWorkers)

$lines = @(Get-Content $Source | Where-Object { $_ -match ':' -and $_.Trim() -ne '' } | Select-Object -Skip $Skip -First $Take)
if ($lines.Count -eq 0) { throw "empty slice: $Source" }
$queue = [System.Collections.ArrayList]::new()
foreach ($l in $lines) { [void]$queue.Add($l.Trim()) }
$tries = @{}
$master = Join-Path $OutDir "master-$RunTag.jsonl"
if (Test-Path $master) { Remove-Item $master -Force }
$round = 0; $done = 0; $deadRounds = 0

function Run-Chunk($batch, $acct, $tag, $bid) {
  $list = Join-Path $OutDir "list_$tag.txt"
  $out = Join-Path $OutDir "chunk_$tag.jsonl"
  $batch | Set-Content -Encoding ascii $list
  $job = Start-Job -ScriptBlock {
    param($root, $list, $out, $pu, $pw, $pace, $chunk, $bid, $ph, $pp, $suffix)
    Set-Location $root
    $env:BID = "$bid"
    $env:LIST = $list; $env:OUT = $out
    $env:PU_BASE = $pu; $env:PW = $pw; $env:PU_SUFFIX = $suffix
    $env:PROXY_HOST = $ph; $env:PROXY_PORT = "$pp"
    $env:PACE = "$pace"; $env:BUDGET = "$chunk"; $env:MAXT = "600000"
    & node "$root\runner\batch-fast.js" *> "$out.log"
  } -ArgumentList $root, $list, $out, $acct.user, $acct.pass, $Pace, $batch.Count, $bid, $ProxyHost, $ProxyPort, $PuSuffix
  return @{ job = $job; out = $out; batch = $batch }
}

while ($queue.Count -gt 0 -and $round -lt 500) {
  $round++
  $jobs = @()
  for ($w = 0; $w -lt $workers -and $queue.Count -gt 0; $w++) {
    $n = [Math]::Min($Chunk, $queue.Count)
    $batch = @($queue.GetRange(0, $n)); $queue.RemoveRange(0, $n)
    $tag = ("{0}_{1:d4}_{2}" -f $RunTag, $round, $w)
    $jobs += Run-Chunk $batch $pool[$w] $tag $w
  }

  foreach ($j in $jobs) { Wait-Job $j.job | Out-Null }
  foreach ($j in $jobs) { Receive-Job $j.job | Out-Null; Remove-Job $j.job }

  $recs = @{}
  foreach ($j in $jobs) {
    if (-not (Test-Path $j.out)) { continue }
    foreach ($line in Get-Content $j.out) {
      $r = $null; try { $r = $line | ConvertFrom-Json } catch {}
      if (-not $r -or -not $r.email) { continue }
      Add-Content -Path $master -Value $line
      $recs[$r.email] = $r
    }
  }
  if ($recs.Count -eq 0) { $deadRounds++ } else { $deadRounds = 0 }
  if ($deadRounds -ge 3) {
    Write-Output "STOP: 3 rounds with no records (pool dead)"
    break
  }

  $requeue = 0
  foreach ($j in $jobs) {
    foreach ($l in $j.batch) {
      $em = ($l -split ':', 2)[0]
      $r = $recs[$em]
      if ($r -and ($r.validated -or $r.closed -or $r.success)) { $done++; continue }
      $t = 1 + [int]($tries[$em]); $tries[$em] = $t
      if ($t -le ($MaxRetries + 2)) { [void]$queue.Add($l); $requeue++ }
    }
  }

  $state = "round=$round done=$done queue=$($queue.Count) requeue=$requeue"
  $state | Set-Content -Encoding ascii (Join-Path $OutDir "state.txt")
  Write-Output $state
}

Write-Output "FINISHED round=$round done=$done queue=$($queue.Count)"
