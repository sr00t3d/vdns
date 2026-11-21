<#
.SYNOPSIS
    vdns.ps1 — DNS & RDAP Registrar Diagnostics CLI (PowerShell)

.DESCRIPTION
    End-to-end DNS and domain registrar diagnostics CLI for Windows PowerShell 5.1+
    and PowerShell 7+. Queries NS, A/AAAA, MX, PTR, SPF/DMARC, DKIM, multi-resolver
    propagation (Cloudflare/Google/Quad9/OpenDNS), official RDAP (Registro.br and
    rdap.org), and automatic port-43 WHOIS fallback.

    Author  : Percio Castelo <percio@perciocastelo.com.br>
    Website : https://perciocastelo.com.br
    Project : https://perciocastelo.com.br/projetos/en/vdns.html
    Repo    : https://github.com/sr00t3d/vdns
    License : Apache-2.0
    Version : 2.2.0

.EXAMPLE
    .\vdns.ps1 -All perciocastelo.com.br
    .\vdns.ps1 -Registrar -Dns -Propagation example.com -Output json
    .\vdns.ps1 -All github.io -Output csv
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Domain,

    [Alias('a')]
    [switch]$All,

    [Alias('c')]
    [switch]$Registrar,

    [Alias('n')]
    [switch]$Dns,

    [Alias('m')]
    [switch]$Mail,

    [Alias('l')]
    [switch]$Propagation,

    [string]$DkimSelector = 'default',

    [Alias('F', 'o')]
    [ValidateSet('table', 'json', 'csv')]
    [string]$Output = 'table',

    [int]$Timeout = 8,

    [Alias('q')]
    [switch]$Quiet,

    [switch]$NoColor,

    [Alias('V')]
    [switch]$Version,

    [Alias('h')]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptName = 'vdns.ps1'
$ScriptVersion = '2.2.0'
$TimestampUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$HasResolveDnsName = [bool](Get-Command -Name Resolve-DnsName -ErrorAction SilentlyContinue)

function Show-Help {
@"
$ScriptName v$ScriptVersion — DNS & RDAP Registrar Diagnostics CLI (PowerShell)

Usage:
  .\vdns.ps1 [options] <domain>

Options:
  -All, -a                   Full lookup (Registrar RDAP/WHOIS + DNS + Mail + Propagation)
  -Registrar, -c             Official RDAP lookup (Registro.br for .br, rdap.org + WHOIS fallback)
  -Dns, -n                   NS, A, AAAA, and www records
  -Mail, -m                  MX, PTR, SPF, DMARC, and DKIM TXT records
  -Propagation, -l           Multi-resolver propagation check (1.1.1.1, 8.8.8.8, 9.9.9.9, 208.67.222.222)
  -DkimSelector <name>       Custom DKIM selector (default: default)
  -Output, -F, -o <fmt>      Output format: table (default), json, csv
  -Timeout <sec>             Network timeout in seconds (default: 8)
  -Quiet, -q                 Suppress banner header
  -NoColor                   Disable colored output
  -Version, -V               Show version and exit
  -Help, -h                  Show this help and exit
"@ | Write-Output
}

function Write-ColorLine {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    if ($NoColor -or $env:NO_COLOR -or $Output -ne 'table') { Write-Output $Text }
    else { Write-Host $Text -ForegroundColor $Color }
}

function Query-DnsType {
    param([string]$Name, [string]$Type, [string]$Server = '')
    $out = @()
    if ($HasResolveDnsName) {
        try {
            $p = @{ Name = $Name; Type = $Type; DnsOnly = $true; ErrorAction = 'Stop' }
            if ($Server) { $p['Server'] = $Server }
            $recs = Resolve-DnsName @p
            foreach ($r in $recs) {
                switch ($Type) {
                    'A'    { if ($r.PSObject.Properties['IPAddress'] -and $r.IPAddress) { $out += $r.IPAddress } }
                    'AAAA' { if ($r.PSObject.Properties['IPAddress'] -and $r.IPAddress) { $out += $r.IPAddress } }
                    'NS'   { if ($r.PSObject.Properties['NameHost'] -and $r.NameHost) { $out += $r.NameHost.TrimEnd('.') } }
                    'MX'   { if ($r.PSObject.Properties['NameExchange'] -and $r.NameExchange) { $out += "$($r.Preference) $($r.NameExchange.TrimEnd('.'))" } }
                    'TXT'  { if ($r.PSObject.Properties['Strings'] -and $r.Strings) { $out += ($r.Strings -join '') } }
                }
            }
        } catch { }
    } elseif ($Type -eq 'A' -or $Type -eq 'AAAA') {
        try {
            $fam = if ($Type -eq 'A') { [System.Net.Sockets.AddressFamily]::InterNetwork } else { [System.Net.Sockets.AddressFamily]::InterNetworkV6 }
            foreach ($a in ([System.Net.Dns]::GetHostAddresses($Name))) {
                if ($a.AddressFamily -eq $fam) { $out += $a.IPAddressToString }
            }
        } catch { }
    }
    return @($out | Select-Object -Unique)
}

function Invoke-WhoisRaw {
    param([string]$Server, [string]$Query)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($Server, 43, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne(($Timeout * 1000), $false)) { return '' }
        $client.EndConnect($ar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $Timeout * 1000
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("$Query`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        return $reader.ReadToEnd()
    } catch { return '' } finally { $client.Close() }
}

function Get-RegistrarInfo {
    param([string]$Dom)
    $headers = @{ 'User-Agent' = "vdns/$ScriptVersion (+https://github.com/sr00t3d/vdns)" }
    $url = if ($Dom.EndsWith('.br')) { "https://rdap.registro.br/domain/$Dom" } else { "https://rdap.org/domain/$Dom" }
    $src = if ($Dom.EndsWith('.br')) { 'registro.br-rdap' } else { 'rdap.org' }
    try {
        $r = Invoke-RestMethod -Uri $url -Headers $headers -TimeoutSec $Timeout -ErrorAction Stop
        $status = if ($r.PSObject.Properties['status'] -and $r.status) { (@($r.status) -join ', ') } else { '' }
        $exp = ''; $reg = ''
        if ($r.PSObject.Properties['events'] -and $r.events) {
            foreach ($ev in $r.events) {
                if ($ev.eventAction -eq 'expiration')   { $exp = [string]$ev.eventDate }
                if ($ev.eventAction -eq 'registration') { $reg = [string]$ev.eventDate }
            }
        }
        $nsList = @()
        if ($r.PSObject.Properties['nameservers'] -and $r.nameservers) {
            foreach ($ns in $r.nameservers) { if ($ns.ldhName) { $nsList += $ns.ldhName } }
        }
        $dnssec = 'unsigned'
        if ($r.PSObject.Properties['secureDNS'] -and $r.secureDNS -and $r.secureDNS.delegationSigned) { $dnssec = 'signed' }
        return [PSCustomObject]@{
            source = $src; status = $status; registered = $reg; expires = $exp; dnssec = $dnssec; nameservers = $nsList
        }
    } catch {
        $iana = Invoke-WhoisRaw 'whois.iana.org' $Dom
        if ($iana -match '(?im)^refer:\s*(\S+)') {
            $raw = Invoke-WhoisRaw $Matches[1].Trim() $Dom
            $exp = if ($raw -match '(?im)(?:Registry Expiry Date|Expiration Date|Expiry Date|expires)\s*:\s*(\S+)') { $Matches[1] } else { '' }
            $reg = if ($raw -match '(?im)(?:Creation Date|created)\s*:\s*(\S+)') { $Matches[1] } else { '' }
            return [PSCustomObject]@{
                source = 'whois-fallback'; status = 'active'; registered = $reg; expires = $exp; dnssec = 'unknown'; nameservers = @()
            }
        }
    }
    return [PSCustomObject]@{ source = 'unavailable'; status = 'unknown'; registered = ''; expires = ''; dnssec = 'unknown'; nameservers = @() }
}

if ($Help) { Show-Help; exit 0 }
if ($Version) { Write-Output "$ScriptName $ScriptVersion"; exit 0 }
if (-not $Domain) { Show-Help; exit 1 }

$CleanDomain = ($Domain -replace '^https?://', '' -replace '/.*$', '').Trim().TrimEnd('.').ToLowerInvariant()
if (-not ($All -or $Registrar -or $Dns -or $Mail -or $Propagation)) { $All = $true }

$RegInfo = $null
$A = @(); $AAAA = @(); $NS = @(); $MX = @(); $PTR = ''; $SPF = @(); $DMARC = @(); $DKIM = @()
$PropMap = @{}

if ($All -or $Registrar) { $RegInfo = Get-RegistrarInfo $CleanDomain }
if ($All -or $Dns) {
    $A    = @(Query-DnsType $CleanDomain 'A')
    $AAAA = @(Query-DnsType $CleanDomain 'AAAA')
    $NS   = @(Query-DnsType $CleanDomain 'NS')
}
if ($All -or $Mail) {
    $MX = @(Query-DnsType $CleanDomain 'MX')
    $txts = @(Query-DnsType $CleanDomain 'TXT')
    $SPF = @($txts | Where-Object { $_ -like 'v=spf1*' })
    $DMARC = @(Query-DnsType "_dmarc.$CleanDomain" 'TXT')
    $DKIM  = @(Query-DnsType "$DkimSelector._domainkey.$CleanDomain" 'TXT')
    if ($A.Count -gt 0) {
        try {
            $e = [System.Net.Dns]::GetHostEntry($A[0])
            if ($e.HostName -and $e.HostName -ne $A[0]) { $PTR = $e.HostName.TrimEnd('.') }
        } catch { }
    }
}
if ($All -or $Propagation) {
    foreach ($srv in @('1.1.1.1', '8.8.8.8', '9.9.9.9', '208.67.222.222')) {
        $PropMap[$srv] = @(Query-DnsType $CleanDomain 'A' $srv)
    }
}

$Report = [PSCustomObject]@{
    tool        = $ScriptName
    version     = $ScriptVersion
    timestamp   = $TimestampUtc
    domain      = $CleanDomain
    registrar   = $RegInfo
    dns         = [PSCustomObject]@{ a = $A; aaaa = $AAAA; ns = $NS }
    mail        = [PSCustomObject]@{ mx = $MX; ptr = $PTR; spf = $SPF; dmarc = $DMARC; dkim = $DKIM }
    propagation = $PropMap
}

switch ($Output) {
    'json' { $Report | ConvertTo-Json -Depth 6 | Write-Output }
    'csv' {
        Write-Output 'section,key,value'
        if ($RegInfo) {
            Write-Output "`"registrar`",`"source`",`"$($RegInfo.source)`""
            Write-Output "`"registrar`",`"status`",`"$($RegInfo.status)`""
            Write-Output "`"registrar`",`"expires`",`"$($RegInfo.expires)`""
            Write-Output "`"registrar`",`"dnssec`",`"$($RegInfo.dnssec)`""
        }
        foreach ($v in $A)    { Write-Output "`"dns`",`"A`",`"$v`"" }
        foreach ($v in $AAAA) { Write-Output "`"dns`",`"AAAA`",`"$v`"" }
        foreach ($v in $NS)   { Write-Output "`"dns`",`"NS`",`"$v`"" }
        foreach ($v in $MX)   { Write-Output "`"mail`",`"MX`",`"$v`"" }
        if ($PTR)             { Write-Output "`"mail`",`"PTR`",`"$PTR`"" }
    }
    default {
        if (-not $Quiet) {
            Write-ColorLine ('=' * 78) ([ConsoleColor]::Cyan)
            Write-Output (" {0} v{1} | DNS & RDAP Diagnostics: {2} | {3}" -f $ScriptName, $ScriptVersion, $CleanDomain, $TimestampUtc)
            Write-ColorLine ('=' * 78) ([ConsoleColor]::Cyan)
            Write-Output ''
        }
        if ($RegInfo) {
            Write-ColorLine '[REGISTRAR / RDAP]' ([ConsoleColor]::Cyan)
            Write-Output ("  Source      : {0}" -f $RegInfo.source)
            Write-Output ("  Status      : {0}" -f $RegInfo.status)
            if ($RegInfo.registered) { Write-Output ("  Registered  : {0}" -f $RegInfo.registered) }
            if ($RegInfo.expires)    { Write-Output ("  Expires     : {0}" -f $RegInfo.expires) }
            Write-Output ("  DNSSEC      : {0}" -f $RegInfo.dnssec)
            if ($RegInfo.nameservers.Count -gt 0) { Write-Output ("  RDAP NS     : {0}" -f ($RegInfo.nameservers -join ', ')) }
            Write-Output ''
        }
        if ($All -or $Dns) {
            Write-ColorLine '[DNS RECORDS]' ([ConsoleColor]::Cyan)
            Write-Output ("  A           : {0}" -f $(if ($A.Count) { $A -join ', ' } else { '-' }))
            Write-Output ("  AAAA        : {0}" -f $(if ($AAAA.Count) { $AAAA -join ', ' } else { '-' }))
            Write-Output ("  NS          : {0}" -f $(if ($NS.Count) { $NS -join ', ' } else { '-' }))
            Write-Output ''
        }
        if ($All -or $Mail) {
            Write-ColorLine '[MAIL & AUTH]' ([ConsoleColor]::Cyan)
            Write-Output ("  MX          : {0}" -f $(if ($MX.Count) { $MX -join ', ' } else { '-' }))
            Write-Output ("  PTR         : {0}" -f $(if ($PTR) { $PTR } else { '-' }))
            Write-Output ("  SPF         : {0}" -f $(if ($SPF.Count) { $SPF -join ' | ' } else { '-' }))
            Write-Output ("  DMARC       : {0}" -f $(if ($DMARC.Count) { $DMARC -join ' | ' } else { '-' }))
            Write-Output ("  DKIM ({0}) : {1}" -f $DkimSelector, $(if ($DKIM.Count) { $DKIM -join ' | ' } else { '-' }))
            Write-Output ''
        }
        if ($All -or $Propagation) {
            Write-ColorLine '[PROPAGATION (A)]' ([ConsoleColor]::Cyan)
            foreach ($srv in @('1.1.1.1', '8.8.8.8', '9.9.9.9', '208.67.222.222')) {
                $vals = @($PropMap[$srv])
                Write-Output ("  {0,-15} : {1}" -f $srv, $(if ($vals.Count) { $vals -join ', ' } else { '-' }))
            }
        }
    }
}
exit 0
