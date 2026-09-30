[CmdletBinding()]
param(
    [string]$TargetPackageFullName,
    [string]$RunDirectory,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'

function Get-Preflight([string]$Target) {
    if ($PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1.'
    }
    if ($Target -notmatch '^OpenAI\.Codex_(\d+\.\d+\.\d+\.\d+)_x64__2p2nqsd0c76g0$') {
        throw 'Unexpected target package identity.'
    }
    $targetVersion = [version]$Matches[1]
    $current = @(Get-AppxPackage -Name 'OpenAI.Codex')
    if ($current.Count -ne 1) { throw 'Expected one registered Codex package.' }
    $current = $current[0]
    if ($current.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0' -or
        $current.Status.ToString() -ne 'Ok' -or $current.SignatureKind.ToString() -ne 'Store' -or
        $current.IsDevelopmentMode -or -not $current.InstallLocation) {
        throw 'Current package identity or state is unexpected.'
    }
    $sets = (Get-Command Add-AppxPackage).ParameterSets | Where-Object {
        'MainPackage' -in $_.Parameters.Name -and 'Register' -in $_.Parameters.Name
    }
    if (-not $sets) { throw 'MainPackage registration is unavailable.' }
    $targetPath = Join-Path (Split-Path -Parent $current.InstallLocation) $Target
    if ([version]$current.Version -lt $targetVersion) {
        [xml]$manifest = Get-Content -LiteralPath (Join-Path $targetPath 'AppxManifest.xml') -Raw
        $identity = $manifest.Package.Identity
        if ($identity.Name -ne $current.Name -or $identity.Publisher -ne $current.Publisher -or
            [version]$identity.Version -ne $targetVersion -or $identity.ProcessorArchitecture -ne 'x64' -or
            -not (Test-Path -LiteralPath (Join-Path $targetPath 'AppxSignature.p7x'))) {
            throw 'Staged package identity verification failed.'
        }
    }
    [pscustomobject]@{
        Current = $current; Target = $Target; TargetVersion = $targetVersion.ToString()
        TargetPath = $targetPath; UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        DeploymentNeeded = ([version]$current.Version -lt $targetVersion)
    }
}

function Get-PackageProcesses([string]$Location) {
    $prefix = $Location.TrimEnd('\') + '\'
    @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    })
}

if ($ValidateOnly) {
    Get-Preflight $TargetPackageFullName | ConvertTo-Json -Depth 6
    return
}

if (-not $RunDirectory -or -not (Test-Path -LiteralPath $RunDirectory -PathType Container)) {
    throw 'A launcher-created run directory is required.'
}
$logPath = Join-Path $RunDirectory 'worker.log'
$resultPath = Join-Path $RunDirectory 'result.json'
$result = [ordered]@{ Started = (Get-Date).ToString('o'); Success = $false; RegistrationAttempted = $false }
$exitCode = 1
function Write-Log([string]$Message) {
    ('{0} {1}' -f (Get-Date).ToString('o'), $Message) | Add-Content -LiteralPath $logPath -Encoding UTF8
}
try {
    $config = Get-Content -LiteralPath (Join-Path $RunDirectory 'config.json') -Raw | ConvertFrom-Json
    $state = Get-Preflight $config.Target
    if ($state.UserSid -ne $config.UserSid -or $config.Nonce -notmatch '^[0-9a-f-]{36}$') {
        throw 'Run identity does not match this user.'
    }
    $self = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $PID)
    [pscustomobject]@{
        Nonce = $config.Nonce; Pid = $PID; ParentPid = $self.ParentProcessId
        UserSid = $state.UserSid; Target = $state.Target; Ready = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'ready.tmp') -Encoding UTF8
    Move-Item -LiteralPath (Join-Path $RunDirectory 'ready.tmp') -Destination (Join-Path $RunDirectory 'ready.json')
    Write-Log ('Preflight ready: {0} -> {1}' -f $state.Current.Version, $state.TargetVersion)
    $goPath = Join-Path $RunDirectory 'go'
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $goPath)) {
        if ((Get-Date) -ge $deadline) { throw 'Execution marker deadline exceeded.' }
        Start-Sleep -Milliseconds 500
    }
    if ((Get-Content -LiteralPath $goPath -Raw).Trim() -ne $config.Nonce) {
        throw 'Execution marker does not match this run.'
    }
    # Recheck registration after the marker; another update may have completed.
    $state = Get-Preflight $config.Target
    if ($state.DeploymentNeeded) {
        $processes = @(Get-PackageProcesses $state.Current.InstallLocation)
        foreach ($process in $processes) {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
            if ($owner.ReturnValue -ne 0 -or $owner.Sid -ne $state.UserSid) {
                throw 'Cannot verify every package process belongs to this user; no processes stopped.'
            }
        }
        Write-Log ('Stopping scoped processes once: {0}' -f ($processes.ProcessId -join ','))
        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        }
        foreach ($check in 1..2) {
            Start-Sleep -Seconds 2
            $remaining = @(Get-PackageProcesses $state.Current.InstallLocation)
            Write-Log ('Zero-process check {0}: {1}' -f $check, $remaining.Count)
            if ($remaining.Count) { throw 'Package processes remain or restarted; no registration attempted.' }
        }
        $result.RegistrationAttempted = $true
        Write-Log ('Registering once: {0}' -f $state.Target)
        Add-AppxPackage -Register -MainPackage $state.Target -ErrorAction Stop
    } else {
        Write-Log 'Target is already registered or superseded; no deployment.'
    }
    $installed = @(Get-AppxPackage -Name 'OpenAI.Codex')
    if ($installed.Count -ne 1) { throw 'Expected one package after registration.' }
    $installed = $installed[0]
    $result.Version = $installed.Version.ToString()
    $result.PackageFullName = $installed.PackageFullName
    $result.Status = $installed.Status.ToString()
    $result.SignatureKind = $installed.SignatureKind.ToString()
    $result.IsDevelopmentMode = $installed.IsDevelopmentMode
    if ([version]$installed.Version -lt [version]$state.TargetVersion -or
        $installed.PackageFamilyName -ne 'OpenAI.Codex_2p2nqsd0c76g0' -or
        $result.Status -ne 'Ok' -or $result.SignatureKind -ne 'Store' -or $installed.IsDevelopmentMode) {
        throw 'Post-registration package verification failed.'
    }
    $result.Success = $true
    $exitCode = 0
    Write-Log ('Registered version verified: {0}; verify running app after relaunch.' -f $result.Version)
} catch {
    $result.Error = ($_ | Format-List * -Force | Out-String)
    $result.Exception = $_.Exception.ToString()
    Write-Log $result.Error
} finally {
    $result.Finished = (Get-Date).ToString('o')
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Log ('Worker finished: success={0}' -f $result.Success)
}
exit $exitCode
