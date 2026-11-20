# Gate every pool line before a run: one fresh sticky session, one GET on /login/.
# 200 = CLEAN, 407 = auth/quota, anything else = dead or blocked (docs/03-OPERATIONS.md).
param(
  [Parameter(Mandatory=$true)][string]$PoolFile,
  [string]$ProxyHost = "pr.oxylabs.io",
  [int]$ProxyPort = 7777,
  [string]$PuSuffix = "-sesstime-10",
  [string]$OutFile = ".\proxies.clean.txt"
)

$ErrorActionPreference = "Stop"
$clean = @()
$n = 0
foreach ($line in (Get-Content $PoolFile | Where-Object { $_ -match ':' -and $_.Trim() -ne '' })) {
  $n++
  $i = $line.IndexOf(':'); $u = $line.Substring(0, $i); $p = $line.Substring($i + 1)
  if ($PuSuffix -eq "none") { $pu = $u }
  else { $pu = $u + "-sessid-c$n$((Get-Random -Minimum 100000 -Maximum 999999))" + $PuSuffix }
  $cred = "${pu}:${p}"
  $code = (curl.exe -s -o NUL -w "%{http_code}" --max-time 30 -x "${ProxyHost}:${ProxyPort}" -U $cred "https://www.yelp.com/login/") -join ""
  $loc = curl.exe -s --max-time 30 -x "${ProxyHost}:${ProxyPort}" -U $cred "https://ip.oxylabs.io/location"
  $ip = ""; $asn = ""
  try { $j = $loc | ConvertFrom-Json; $ip = $j.ip; $asn = $j.providers.maxmind.asn } catch {}
  $verdict = if ($code -eq "200") { "CLEAN" } else { "DEAD" }
  if ($code -eq "200") { $clean += $line }
  Write-Output ("{0} {1} http={2} ip={3} asn={4}" -f $verdict, $u, $code, $ip, $asn)
}
$clean | Set-Content -Encoding ascii $OutFile
Write-Output ("clean={0}/{1} -> {2}" -f $clean.Count, $n, $OutFile)
