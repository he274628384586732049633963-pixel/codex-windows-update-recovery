[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$errors = New-Object System.Collections.Generic.List[string]
$packages = @()
$processes = @()
$events = @()
$candidates = @()
$records = @()
$current = $null
$identitySid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$logName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
$since = (Get-Date).AddHours(-24)

try {
    $registered = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)
    $packages = @($registered | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            PackageFullName = $_.PackageFullName
            PackageFamilyName = $_.PackageFamilyName
            Publisher = $_.Publisher
            Version = $_.Version.ToString()
            InstallLocation = $_.InstallLocation
            Status = $_.Status.ToString()
            SignatureKind = $_.SignatureKind.ToString()
            IsDevelopmentMode = [bool]$_.IsDevelopmentMode
        }
    })
    if ($registered.Count -eq 1) {
        $current = $registered[0]
    } else {
        $errors.Add(('Expected one current-user Codex package; found {0}.' -f $registered.Count))
    }
} catch {
    $errors.Add(('Package query: {0}' -f $_.Exception.Message))
}

if ($current -and $current.InstallLocation) {
    try {
        $prefix = $current.InstallLocation.TrimEnd('\') + '\'
        $scoped = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
        })
        $processes = @($scoped | ForEach-Object {
            $ownerSid = $null
            $ownerVerified = $false
            try {
                $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction Stop
                if ($owner.ReturnValue -ne 0 -or -not $owner.Sid) {
                    throw 'Process owner SID query did not succeed.'
                }
                $ownerSid = $owner.Sid
                $ownerVerified = ($ownerSid -eq $identitySid)
            } catch {
                $errors.Add(('Process owner query: {0}' -f $_.Exception.Message))
            }
            [pscustomobject]@{
                ProcessId = $_.ProcessId
                ParentProcessId = $_.ParentProcessId
                Name = $_.Name
                ExecutablePath = $_.ExecutablePath
                OwnerSid = $ownerSid
                IsCurrentUser = $ownerVerified
            }
        })
    } catch {
        $errors.Add(('Process query: {0}' -f $_.Exception.Message))
    }
}

try {
    $records = @(Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $since } -MaxEvents 1000 -ErrorAction Stop)
    $related = @($records | Where-Object { $_.Message -match 'OpenAI\.Codex' })
    $events = @($related | Select-Object -First 20 | ForEach-Object {
        [pscustomobject]@{
            Id = $_.Id
            TimeCreated = $_.TimeCreated.ToString('o')
            Level = $_.LevelDisplayName
            Message = $_.Message
        }
    })
    $stageNames = @($related | Where-Object {
        $_.Id -eq 400 -and $_.Message -match 'Stage operation.*finished successfully'
    } | ForEach-Object {
        [regex]::Matches($_.Message, 'OpenAI\.Codex_\d+\.\d+\.\d+\.\d+_[A-Za-z0-9]+_[^_\s"''<>]*_2p2nqsd0c76g0') | ForEach-Object { $_.Value }
    } | Sort-Object -Unique)
    if ($current -and $current.InstallLocation) {
        $packageRoot = Split-Path -Path $current.InstallLocation -Parent
        $candidates = @($stageNames | ForEach-Object {
            $fullName = $_
            $targetPath = Join-Path $packageRoot $fullName
            $verified = $false
            $newer = $null
            $validationError = $null
            $version = $null
            try {
                if ($fullName -notmatch '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$') {
                    throw 'Candidate full name is not the expected x64 package identity.'
                }
                $version = $Matches[1]
                [xml]$manifest = Get-Content -LiteralPath (Join-Path $targetPath 'AppxManifest.xml') -Raw -ErrorAction Stop
                $manifestIdentity = $manifest.Package.Identity
                if ($manifestIdentity.Name -ne $current.Name -or
                    $manifestIdentity.Publisher -ne $current.Publisher -or
                    [version]$manifestIdentity.Version -ne [version]$version -or
                    $manifestIdentity.ProcessorArchitecture -ne 'x64' -or
                    -not (Test-Path -LiteralPath (Join-Path $targetPath 'AppxSignature.p7x') -PathType Leaf)) {
                    throw 'Candidate manifest identity or signature-file verification failed.'
                }
                $verified = $true
                $newer = ([version]$version -gt [version]$current.Version)
            } catch {
                $validationError = $_.Exception.Message
                $errors.Add(('Candidate {0}: {1}' -f $fullName, $validationError))
            }
            [pscustomobject]@{
                PackageFullName = $fullName
                Version = $version
                InstallLocation = $targetPath
                ManifestVerified = $verified
                IsNewerThanCurrent = $newer
                ValidationError = $validationError
            }
        })
    }
} catch {
    $errors.Add(('AppX event query: {0}' -f $_.Exception.Message))
}

[pscustomobject]@{
    Inspected = (Get-Date).ToString('o')
    IdentitySid = $identitySid
    CurrentPackages = $packages
    PackageProcesses = $processes
    StageCandidates = $candidates
    AppXEvents = $events
    EventQuery = [pscustomobject]@{
        LogName = $logName
        Since = $since.ToString('o')
        MaximumRecords = 1000
        RecordsRead = $records.Count
        LimitReached = ($records.Count -eq 1000)
        MaximumRelatedEventsReturned = 20
    }
    Errors = @($errors.ToArray())
} | ConvertTo-Json -Depth 6
