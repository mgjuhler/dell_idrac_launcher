# Dell iDRAC KVM launcher
# Downloads the Java viewer (avctKVM.jar) and its native libraries directly
# from the iDRAC, installs the bundled JRE if no Java is found, and starts
# the virtual console. Files are cached per host, so only the first launch
# against a given iDRAC needs the downloads.
#
# Usage:
#   idrac.ps1 [-DracHost <ip>] [-User <name>] [-Password <pw>]
# With no arguments it shows a menu from hosts.txt (if present) or prompts.

param(
    [string]$DracHost,
    [string]$User,
    [string]$Password
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

try {

# Old iDRACs use self-signed certs and only speak old TLS versions.
[Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
$protocols = [Net.SecurityProtocolType]::Tls12 -bor
             [Net.SecurityProtocolType]::Tls11 -bor
             [Net.SecurityProtocolType]::Tls
try { $protocols = $protocols -bor [Net.SecurityProtocolType]::Ssl3 } catch { }
[Net.ServicePointManager]::SecurityProtocol = $protocols

function Get-DracFile {
    param([string]$Url, [string]$Dest)
    try {
        (New-Object Net.WebClient).DownloadFile($Url, $Dest)
    } catch {
        # WebClient can refuse the iDRAC's old TLS; curl.exe (bundled with
        # Windows 10+) uses Schannel and is more forgiving with -k.
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path $curl)) { throw }
        & $curl -k -s -f -o $Dest $Url
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Dest)) {
            throw "Kunne ikke hente $Url"
        }
    }
}

function Find-Java {
    foreach ($candidate in @(
        (Join-Path $scriptDir 'jre\bin\java.exe'),
        'C:\jre\bin\java.exe'
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

# --- Pick host (argument, hosts.txt menu, or prompt) ---
if (-not $DracHost) {
    $entries = @()
    $hostsFile = Join-Path $scriptDir 'hosts.txt'
    if (Test-Path $hostsFile) {
        $entries = @(Get-Content $hostsFile |
            Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
            ForEach-Object {
                $parts = $_.Split(';')
                [pscustomobject]@{
                    Name     = $parts[0].Trim()
                    Address  = $parts[1].Trim()
                    User     = if ($parts.Count -gt 2) { $parts[2].Trim() } else { $null }
                    Password = if ($parts.Count -gt 3) { $parts[3].Trim() } else { $null }
                }
            })
    }
    if ($entries.Count -gt 0) {
        Write-Host 'Vælg server:'
        for ($i = 0; $i -lt $entries.Count; $i++) {
            Write-Host ("  {0}) {1}  ({2})" -f ($i + 1), $entries[$i].Name, $entries[$i].Address)
        }
        $choice = Read-Host 'Nummer eller host/IP'
        if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $entries.Count) {
            $entry = $entries[[int]$choice - 1]
            $DracHost = $entry.Address
            if (-not $User) { $User = $entry.User }
            if (-not $Password) { $Password = $entry.Password }
        } else {
            $DracHost = $choice
        }
    } else {
        $DracHost = Read-Host 'Host/IP'
    }
    if (-not $DracHost) { throw 'Ingen host angivet.' }
}

if (-not $User) {
    $User = Read-Host 'Brugernavn (Enter = root)'
    if (-not $User) { $User = 'root' }
}
if (-not $Password) {
    $secure = Read-Host 'Password' -AsSecureString
    $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

# --- Find Java, or silently install the bundled JRE ---
$java = Find-Java
if (-not $java) {
    Write-Host 'Java blev ikke fundet - installerer den medfølgende JRE i C:\jre (kræver administrator-godkendelse) ...'
    $installer = Join-Path $scriptDir 'jre-7u80-windows-x64.exe'
    if (-not (Test-Path $installer)) { throw "Installationsfilen mangler: $installer" }
    Start-Process $installer -ArgumentList '/s', 'INSTALLDIR=C:\jre' -Verb RunAs -Wait
    $java = Find-Java
    if (-not $java) { throw 'Java-installationen ser ud til at være fejlet.' }
}
$is64BitJava = (& $java -version 2>&1 | Out-String) -match '64-Bit'

# --- Fetch viewer + native libs from the iDRAC (cached per host) ---
$archSuffix = if ($is64BitJava) { '64' } else { '32' }
$cacheDir = Join-Path $scriptDir "cache\$DracHost"
$libDir = Join-Path $cacheDir "lib$archSuffix"
$jarPath = Join-Path $cacheDir 'avctKVM.jar'

if (-not (Test-Path $jarPath) -or -not (Test-Path $libDir)) {
    New-Item -ItemType Directory -Force -Path $libDir | Out-Null
    Write-Host "Henter konsol-filerne fra $DracHost (kun første gang) ..."
    Get-DracFile "https://$DracHost/software/avctKVM.jar" $jarPath

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    foreach ($libJar in "avctKVMIOWin$archSuffix.jar", "avmWinLib$archSuffix.jar") {
        $tmp = Join-Path $cacheDir $libJar
        Get-DracFile "https://$DracHost/software/$libJar" $tmp
        $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
        try {
            foreach ($dllEntry in ($zip.Entries | Where-Object { $_.Name -like '*.dll' })) {
                [IO.Compression.ZipFileExtensions]::ExtractToFile(
                    $dllEntry, (Join-Path $libDir $dllEntry.Name), $true)
            }
        } finally {
            $zip.Dispose()
        }
        Remove-Item $tmp
    }
}

# --- Launch ---
Write-Host "Starter KVM-konsol mod $DracHost ..."
& $java -cp $jarPath "-Djava.library.path=$libDir" com.avocent.idrac.kvm.Main `
    "ip=$DracHost" kmport=5900 vport=5900 "user=$User" "passwd=$Password" `
    apcp=1 version=2 vmprivilege=true "helpurl=https://${DracHost}:443/help/contents.html"
exit $LASTEXITCODE

} catch {
    Write-Host $_ -ForegroundColor Red
    exit 1
}
