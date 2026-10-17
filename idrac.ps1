# Dell iDRAC KVM launcher
# Downloads the Java viewer (avctKVM.jar) and its native libraries directly
# from the iDRAC, installs the bundled JRE if no Java is found, and starts
# the virtual console. Files are cached per host under %LOCALAPPDATA%, so
# only the first launch against a given iDRAC needs the downloads.
#
# Usage:
#   idrac.ps1 [-DracHost <ip>] [-User <name>] [-Password <pw>] [-Refresh]
# With no arguments it shows a menu from hosts.txt (if present) or prompts.
# -Refresh throws away the cached viewer files and downloads them again.
#
# Must stay compatible with Windows PowerShell 2.0 on .NET 3.5 (Windows 7):
# no [pscustomobject], -File/-Directory, Unblock-File, .NET 4.5 APIs, and
# no bare "if" statements used as values.

param(
    [string]$DracHost,
    [string]$User,
    [string]$Password,
    [switch]$Refresh
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$appDir = Join-Path $env:LOCALAPPDATA 'dell_idrac_launcher'
$hostsFile = Join-Path $scriptDir 'hosts.txt'
$kvmPort = 5900

# Lines in the Java log that mean the cached viewer files are broken.
$brokenCachePattern = 'ClassNotFoundException|NoClassDefFoundError|UnsatisfiedLinkError|ZipException|Invalid or corrupt jarfile|Could not find or load main class'

try {

$nativeHelpers = $false
try {
    Add-Type -Namespace IdracLauncher -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool DeleteFile(string path);

public static void TrustAllCertificates() {
    System.Net.ServicePointManager.ServerCertificateValidationCallback = delegate { return true; };
}
'@
    $nativeHelpers = $true
} catch { }

# Files from a downloaded zip carry the "mark of the web", which makes
# Windows show extra security prompts for the JRE installer. Unblock-File
# needs PowerShell 3, so delete the Zone.Identifier stream directly.
if ($nativeHelpers) {
    Get-ChildItem -LiteralPath $scriptDir | Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        [void][IdracLauncher.Native]::DeleteFile($_.FullName + ':Zone.Identifier')
    }
}

# Old iDRACs use self-signed certs and only speak old TLS versions. A C#
# delegate is safer than a scriptblock on PowerShell 2.0.
if ($nativeHelpers) {
    [IdracLauncher.Native]::TrustAllCertificates()
} else {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
$protocols = [Net.SecurityProtocolType]::Tls
foreach ($name in 'Tls11', 'Tls12', 'Ssl3') {
    try {
        # .NET 3.5 has no Tls11/Tls12 - Parse throws and the name is skipped.
        [Net.ServicePointManager]::SecurityProtocol = $protocols -bor [Enum]::Parse([Net.SecurityProtocolType], $name)
        $protocols = [Net.ServicePointManager]::SecurityProtocol
    } catch { }
}

# --- Helpers ---

# Quotes arguments the way the MS C runtime parses them, so passwords with
# spaces or quotes survive the trip to java.exe.
function ConvertTo-ArgString([string[]]$Arguments) {
    ($Arguments | ForEach-Object {
        if ($_ -ne '' -and $_ -notmatch '[\s"]') { $_ }
        else { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }
    }) -join ' '
}

# Runs a console program and captures its stderr (where java -version,
# curl and IdracFetch report) without letting Windows PowerShell turn
# stderr lines into terminating errors. Only stderr is redirected, so a
# synchronous read cannot deadlock.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    New-Object PSObject -Property @{ ExitCode = $proc.ExitCode; Output = $stderr }
}

function Get-InnermostMessage($ErrorRecord) {
    $e = $ErrorRecord.Exception
    while ($e.InnerException) { $e = $e.InnerException }
    $e.Message
}

function Test-TcpPort([string]$Address, [int]$Port, [int]$TimeoutMs = 4000) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Address, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-ZipFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $stream = [IO.File]::OpenRead($Path)
    try {
        $magic = New-Object byte[] 2
        return ($stream.Read($magic, 0, 2) -eq 2 -and $magic[0] -eq 0x50 -and $magic[1] -eq 0x4B)
    } finally {
        $stream.Dispose()
    }
}

# Accepts what people paste: "https://10.0.0.5/", "10.0.0.5:443", " 10.0.0.5 ".
function ConvertFrom-HostInput([string]$Text) {
    $text = $Text.Trim() -replace '^[a-zA-Z]+://', ''
    $text = ($text -split '[/?#]')[0]
    $port = 443
    if ($text -match '^\[(.+)\](?::(\d+))?$') {
        $text = $Matches[1]
        if ($Matches[2]) { $port = [int]$Matches[2] }
    } elseif ($text -match '^([^:]+):(\d+)$') {
        $text = $Matches[1]
        $port = [int]$Matches[2]
    }
    New-Object PSObject -Property @{ Address = $text; WebPort = $port }
}

# Notepad saves UTF-8 without BOM, Windows PowerShell assumes ANSI - try
# strict UTF-8 first so "kælder" does not turn into "kÃ¦lder".
function Read-TextFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    try {
        $text = (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    } catch {
        $text = [Text.Encoding]::Default.GetString($bytes)
    }
    $text.TrimStart([char]0xFEFF) -split "`r?`n"
}

function Read-HostsFile {
    if (-not (Test-Path -LiteralPath $hostsFile)) { return @() }
    @(Read-TextFile $hostsFile |
        Where-Object { $_ -match '\S' -and $_ -notmatch '^\s*#' } |
        ForEach-Object {
            # Max 4 parts, so a password may itself contain ';'.
            $parts = $_.Split([char[]]';', 4)
            if ($parts.Count -lt 2 -or -not $parts[1].Trim()) {
                Write-Host "Springer over ugyldig linje i hosts.txt: $_" -ForegroundColor Yellow
                return
            }
            $entryUser = $null
            $entryPassword = $null
            if ($parts.Count -gt 2 -and $parts[2].Trim()) { $entryUser = $parts[2].Trim() }
            if ($parts.Count -gt 3 -and $parts[3] -ne '') { $entryPassword = $parts[3] }
            New-Object PSObject -Property @{
                Name     = $parts[0].Trim()
                Address  = $parts[1].Trim()
                User     = $entryUser
                Password = $entryPassword
            }
        })
}

function Find-Java {
    $candidates = @(
        (Join-Path $scriptDir 'jre\bin\java.exe'),
        'C:\jre\bin\java.exe'
    )
    foreach ($root in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if (-not $root) { continue }
        $candidates += Join-Path $root 'Java\jre7\bin\java.exe'
        $candidates += @(Get-ChildItem -Path (Join-Path $root 'Java') -Filter 'jre1.8*' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer } |
            Sort-Object Name -Descending | ForEach-Object { Join-Path $_.FullName 'bin\java.exe' })
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Install-BundledJava {
    $is64BitOs = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64')
    $installerName = 'jre-7u80-windows-i586.exe'
    if ($is64BitOs) { $installerName = 'jre-7u80-windows-x64.exe' }
    $installer = Join-Path $scriptDir $installerName
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Host "Installationsfilen mangler: $installer" -ForegroundColor Yellow
        return $false
    }
    Write-Host 'Java mangler - installerer den medfølgende Java 7 i C:\jre.'
    Write-Host 'Klik "Ja", når Windows spørger om administratorrettigheder ...' -ForegroundColor Cyan
    try {
        Start-Process -FilePath $installer -ArgumentList '/s INSTALLDIR=C:\jre' -Verb RunAs -Wait
    } catch {
        Write-Host 'Installationen blev afbrudt (der blev ikke klikket "Ja").' -ForegroundColor Yellow
        return $false
    }
    # The installer hands work over to msiexec; give it a moment to finish.
    for ($i = 0; $i -lt 60 -and -not (Test-Path 'C:\jre\bin\java.exe'); $i++) { Start-Sleep -Seconds 1 }
    return (Test-Path 'C:\jre\bin\java.exe')
}

function Get-JavaSecurityOverride {
    # Re-enables the old TLS versions, ciphers and certificate algorithms
    # that iDRAC6 needs and that newer Java updates switch off.
    $path = Join-Path $appDir 'java.security.override'
    $content = @(
        'jdk.tls.disabledAlgorithms=',
        'jdk.certpath.disabledAlgorithms=',
        'jdk.jar.disabledAlgorithms=',
        'jdk.security.legacyAlgorithms='
    ) -join "`r`n"
    [IO.File]::WriteAllText($path, $content)
    return $path
}

# Tries Windows' own HTTPS first, then curl.exe, then Java's TLS stack
# (the only one that still speaks TLS 1.0 if Windows has switched it off).
function Get-DracFile([string]$Url, [string]$Dest) {
    $errors = @()

    try {
        (New-Object Net.WebClient).DownloadFile($Url, $Dest)
        if (Test-ZipFile $Dest) { return }
        $errors += 'Windows: svaret var ikke en jar-fil'
    } catch {
        $errors += "Windows: $(Get-InnermostMessage $_)"
    }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        $result = Invoke-Native $curl @('-k', '-s', '-S', '-f', '-L', '--tlsv1.0', '--connect-timeout', '15', '-o', $Dest, $Url)
        if ($result.ExitCode -eq 0 -and (Test-ZipFile $Dest)) { return }
        $errors += "curl: $($result.Output.Trim())"
    }

    $fetchDir = Join-Path $scriptDir 'fetch'
    if (Test-Path -LiteralPath (Join-Path $fetchDir 'IdracFetch.class')) {
        $result = Invoke-Native $java @('-cp', $fetchDir, "-Djava.security.properties=$securityFile",
            '-Djsse.enableSNIExtension=false', 'IdracFetch', $Url, $Dest)
        if ($result.ExitCode -eq 0 -and (Test-ZipFile $Dest)) { return }
        $errors += "Java: $($result.Output.Trim())"
    }

    Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    throw "Kunne ikke hente $Url`n  " + ($errors -join "`n  ")
}

# Unpacked with Java: .NET 3.5 (PowerShell 2.0 on Windows 7) cannot read zips.
function Expand-Dlls([string]$JarPath, [string]$TargetDir) {
    $result = Invoke-Native $java @('-cp', (Join-Path $scriptDir 'fetch'), 'IdracFetch', '--extract-dlls', $JarPath, $TargetDir)
    if ($result.ExitCode -ne 0) {
        throw "Kunne ikke pakke $JarPath ud: $($result.Output.Trim())"
    }
}

function Test-ViewerCache {
    (Test-ZipFile $jarPath) -and
        @(Get-ChildItem -LiteralPath $libDir -Filter 'avctKVMIOWin*.dll' -ErrorAction SilentlyContinue).Count -gt 0
}

# Downloads into a temp folder and only swaps it in once everything is
# there, so an interrupted download can never leave a half-filled cache.
function Update-ViewerCache {
    $tmpDir = "$cacheDir.download"
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    $tmpLib = Join-Path $tmpDir "lib$archSuffix"
    New-Item -ItemType Directory -Force -Path $tmpLib | Out-Null

    Write-Host "Henter konsol-filerne fra $DracHost ..."
    Get-DracFile "$baseUrl/software/avctKVM.jar" (Join-Path $tmpDir 'avctKVM.jar')

    # avctKVMIOWin = keyboard/video (required). The virtual media library is
    # avmWinLib on iDRAC6 and avctVMAPI_DLLWin on iDRAC7/8 (optional).
    $libSets = @(
        @{ Names = @("avctKVMIOWin$archSuffix.jar"); Required = $true },
        @{ Names = @("avmWinLib$archSuffix.jar", "avctVMAPI_DLLWin$archSuffix.jar"); Required = $false }
    )
    foreach ($set in $libSets) {
        $done = $false
        $lastError = $null
        foreach ($libJar in $set.Names) {
            $tmp = Join-Path $tmpDir $libJar
            try {
                Get-DracFile "$baseUrl/software/$libJar" $tmp
                Expand-Dlls $tmp $tmpLib
                Remove-Item -LiteralPath $tmp
                $done = $true
                break
            } catch {
                $lastError = $_
            }
        }
        if (-not $done) {
            if ($set.Required) { throw $lastError }
            Write-Host 'Virtuelle medier er ikke tilgængelige (biblioteket kunne ikke hentes) - konsollen virker stadig.' -ForegroundColor Yellow
        }
    }

    if (Test-Path -LiteralPath $cacheDir) {
        try {
            Remove-Item -LiteralPath $cacheDir -Recurse -Force
        } catch {
            Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            throw "De gamle konsol-filer for $DracHost er i brug. Luk alle åbne konsoller mod $DracHost og prøv igen."
        }
    }
    Move-Item -LiteralPath $tmpDir -Destination $cacheDir
}

function Start-Viewer {
    $javaw = Join-Path (Split-Path -Parent $java) 'javaw.exe'
    if (-not (Test-Path -LiteralPath $javaw)) { $javaw = $java }
    $arguments = @(
        '-cp', $jarPath,
        "-Djava.library.path=$libDir",
        "-Djava.security.properties=$securityFile",
        'com.avocent.idrac.kvm.Main',
        "ip=$DracHost", "kmport=$kvmPort", "vport=$kvmPort",
        "user=$User", "passwd=$Password",
        'apcp=1', 'version=2', 'vmprivilege=true',
        "helpurl=$baseUrl/help/contents.html"
    )
    $proc = Start-Process -FilePath $javaw -ArgumentList (ConvertTo-ArgString $arguments) `
        -WorkingDirectory $cacheDir -PassThru `
        -RedirectStandardOutput $outLog -RedirectStandardError $errLog
    $null = $proc.Handle  # makes ExitCode available after exit in Windows PowerShell
    return $proc
}

function Save-HostEntry {
    $known = @(Read-HostsFile | Where-Object { (ConvertFrom-HostInput $_.Address).Address -eq $DracHost })
    if ($known.Count -gt 0) { return }
    $answer = Read-Host "Gem $DracHost i hosts.txt, så den står i menuen næste gang? (j/N)"
    if ($answer -notmatch '^[jJyY]') { return }
    $address = $DracHost
    if ($webPort -ne 443) { $address = "${DracHost}:$webPort" }
    $line = "$DracHost;$address"
    $answer = Read-Host 'Gem også brugernavn og password? Password gemmes i klartekst. (j/N)'
    if ($answer -match '^[jJyY]') { $line += ";$User;$Password" }
    try {
        if (-not (Test-Path -LiteralPath $hostsFile)) {
            $header = "# Én server pr. linje: navn;host/IP[;brugernavn[;password]]`r`n"
            [IO.File]::WriteAllText($hostsFile, $header, (New-Object Text.UTF8Encoding($false)))
        }
        [IO.File]::AppendAllText($hostsFile, "$line`r`n", (New-Object Text.UTF8Encoding($false)))
        Write-Host "Gemt i $hostsFile"
    } catch {
        Write-Host "Kunne ikke skrive til $hostsFile ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# --- Pick host (argument, hosts.txt menu, or prompt) ---
$typedByHand = $false
if (-not $DracHost) {
    $entries = @(Read-HostsFile)
    while (-not $DracHost) {
        if ($entries.Count -gt 0) {
            Write-Host 'Vælg server:'
            for ($i = 0; $i -lt $entries.Count; $i++) {
                Write-Host ("  {0}) {1}  ({2})" -f ($i + 1), $entries[$i].Name, $entries[$i].Address)
            }
            $choice = (Read-Host 'Nummer eller host/IP').Trim()
            if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $entries.Count) {
                $entry = $entries[[int]$choice - 1]
                $DracHost = $entry.Address
                if (-not $User) { $User = $entry.User }
                if (-not $Password) { $Password = $entry.Password }
            } elseif ($choice -match '^\d+$') {
                Write-Host "Vælg et nummer mellem 1 og $($entries.Count)." -ForegroundColor Yellow
            } else {
                $DracHost = $choice
                $typedByHand = $true
            }
        } else {
            $DracHost = (Read-Host 'iDRAC host/IP').Trim()
            $typedByHand = $true
        }
    }
}

$parsed = ConvertFrom-HostInput $DracHost
$DracHost = $parsed.Address
$webPort = $parsed.WebPort
$baseUrl = "https://$DracHost"
if ($webPort -ne 443) { $baseUrl = "https://${DracHost}:$webPort" }

# --- Check that the iDRAC answers before asking for anything else ---
Write-Host "Tjekker forbindelsen til $DracHost ..."
if (-not (Test-TcpPort $DracHost $webPort)) {
    throw "Kan ikke få forbindelse til $DracHost på port $webPort.`nTjek at IP-adressen er rigtig, at iDRAC'en er tændt og har netværk, og at du er på et net der kan nå den."
}
if (-not (Test-TcpPort $DracHost $kvmPort)) {
    Write-Host "Advarsel: port $kvmPort (konsollen) svarer ikke. Webdelen svarer, så vi prøver alligevel." -ForegroundColor Yellow
}

if (-not $User) {
    $User = (Read-Host 'Brugernavn (Enter = root)').Trim()
    if (-not $User) { $User = 'root' }
}
if (-not $Password) {
    $secure = Read-Host 'Password' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

# --- Find Java, or install the bundled JRE ---
$java = Find-Java
if (-not $java -and (Install-BundledJava)) { $java = Find-Java }
if (-not $java) {
    $pathJava = @(Get-Command java.exe -ErrorAction SilentlyContinue)
    if ($pathJava.Count -eq 0) {
        throw 'Java er ikke installeret, og den medfølgende Java kunne ikke installeres. Start idrac.bat igen og klik "Ja" til administratorrettigheder.'
    }
    $java = $pathJava[0].Definition
    Write-Host "Bruger den Java der allerede er installeret ($java). Virker konsollen ikke, så start igen og lad den medfølgende Java 7 blive installeret." -ForegroundColor Yellow
}
$versionInfo = Invoke-Native $java @('-version')
$archSuffix = '32'
if ($versionInfo.Output -match '64-Bit') { $archSuffix = '64' }

New-Item -ItemType Directory -Force -Path $appDir | Out-Null
$securityFile = Get-JavaSecurityOverride

# --- Fetch viewer + native libs from the iDRAC (cached per host) ---
$hostKey = ($DracHost -replace '[\\/:*?"<>|]', '_')
if ($webPort -ne 443) { $hostKey += "_$webPort" }
$cacheDir = Join-Path $appDir "cache\$hostKey"
$libDir = Join-Path $cacheDir "lib$archSuffix"
$jarPath = Join-Path $cacheDir 'avctKVM.jar'
# One log pair per launch: a running console keeps its log files open.
$logDir = Join-Path $appDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
Get-ChildItem -LiteralPath $logDir | Where-Object { -not $_.PSIsContainer -and $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
$logStamp = '{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $PID
$outLog = Join-Path $logDir "$logStamp-out.log"
$errLog = Join-Path $logDir "$logStamp-err.log"

if ($Refresh -or -not (Test-ViewerCache)) { Update-ViewerCache }

# --- Launch; if the viewer dies right away from broken files, refetch once ---
for ($attempt = 1; $attempt -le 2; $attempt++) {
    Write-Host "Starter KVM-konsol mod $DracHost ..."
    $proc = Start-Viewer
    if (-not $proc.WaitForExit(10000)) {
        if ($typedByHand) {
            Write-Host 'Konsollen kører.' -ForegroundColor Green
            Save-HostEntry
        } else {
            Write-Host 'Konsollen kører. Dette vindue lukker af sig selv.' -ForegroundColor Green
        }
        exit 0
    }
    if ($proc.ExitCode -eq 0) { exit 0 }

    $log = ((Get-Content -LiteralPath $outLog, $errLog -ErrorAction SilentlyContinue) -join "`n").Trim()
    if ($attempt -eq 1 -and $log -match $brokenCachePattern) {
        Write-Host 'Konsol-filerne ser ud til at være i stykker - henter dem igen ...' -ForegroundColor Yellow
        Update-ViewerCache
        continue
    }
    if ($log) { Write-Host $log }
    throw "Konsollen stoppede med fejlkode $($proc.ExitCode). Loggen ligger i $logDir"
}

} catch {
    Write-Host ''
    Write-Host "FEJL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
