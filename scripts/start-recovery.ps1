[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetPackageFullName,
    [string]$RunDirectory,
    [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$worker = Join-Path $PSScriptRoot 'invoke-recovery.ps1'
$state = (& $worker -TargetPackageFullName $TargetPackageFullName -ValidateOnly) | ConvertFrom-Json
if (-not $Apply -or -not $state.DeploymentNeeded) {
    $state | ConvertTo-Json -Depth 6
    return
}

$runId = [guid]::NewGuid().ToString()
$taskName = 'CodexUpdateRecovery_' + $runId
$nonce = [guid]::NewGuid().ToString()
if (-not $RunDirectory) {
    $RunDirectory = Join-Path $env:LOCALAPPDATA ('CodexUpdateRecovery\' + $runId)
}
$RunDirectory = [IO.Path]::GetFullPath($RunDirectory)
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$cmd = Join-Path $env:WINDIR 'System32\cmd.exe'
foreach ($path in @($RunDirectory, $worker, $ps51, $cmd)) {
    if ($path -match '["%\r\n]' -or $path.StartsWith('\\')) {
        throw 'Use local paths without quotes, percent signs, or line breaks.'
    }
}
if (Test-Path -LiteralPath $RunDirectory) { throw 'Run directory must be new; do not reuse old markers.' }
$createdTask = $false
$released = $false
try {
    New-Item -ItemType Directory -Path $RunDirectory | Out-Null
    [pscustomobject]@{ Target = $state.Target; UserSid = $state.UserSid; TaskName = $taskName; Nonce = $nonce } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $RunDirectory 'config.json') -Encoding UTF8
    $wrapper = Join-Path $RunDirectory 'run.cmd'
    $workerCommand = "& '{0}' -RunDirectory '{1}'" -f $worker.Replace("'", "''"), $RunDirectory.Replace("'", "''")
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerCommand))
    $wrapperText = @"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
"$ps51" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -EncodedCommand $encodedCommand >"wrapper.log" 2>&1
set "WORKER_EXIT=%ERRORLEVEL%"
"$env:WINDIR\System32\schtasks.exe" /Delete /TN "$taskName" /F >>"wrapper.log" 2>&1
"$env:WINDIR\System32\timeout.exe" /t 3 /nobreak >nul
start "" "$env:WINDIR\explorer.exe" "shell:AppsFolder\OpenAI.Codex_2p2nqsd0c76g0!App"
exit /b %WORKER_EXIT%
"@
    if ($wrapperText -match '[^\x00-\x7F]') { throw 'System executable paths must be ASCII for the CMD wrapper.' }
    Set-Content -LiteralPath $wrapper -Value $wrapperText -Encoding ASCII
    $action = New-ScheduledTaskAction -Execute $cmd -Argument ('/d /c ""{0}""' -f $wrapper) -WorkingDirectory $RunDirectory
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings | Out-Null
    $createdTask = $true
    Start-ScheduledTask -TaskName $taskName
    $readyPath = Join-Path $RunDirectory 'ready.json'
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if (Test-Path -LiteralPath (Join-Path $RunDirectory 'result.json')) { throw 'Worker failed preflight; inspect result.json.' }
        if ((Get-Date) -ge $deadline) { throw 'Worker readiness deadline exceeded.' }
        Start-Sleep -Milliseconds 500
    }
    $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
    if ($ready.Nonce -ne $nonce -or $ready.UserSid -ne $state.UserSid -or $ready.Target -ne $state.Target) {
        throw 'Readiness identity does not match this run.'
    }
    $helper = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f [int]$ready.Pid)
    $parent = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f [int]$ready.ParentPid)
    $service = Get-CimInstance Win32_Process -Filter ('ProcessId={0}' -f $parent.ParentProcessId)
    $helperOwner = Invoke-CimMethod -InputObject $helper -MethodName GetOwnerSid
    if ($helper.ParentProcessId -ne $parent.ProcessId -or
        $helper.ExecutablePath -ne $ps51 -or $parent.ExecutablePath -ne $cmd -or
        $service.ExecutablePath -ne (Join-Path $env:WINDIR 'System32\svchost.exe') -or
        $helperOwner.ReturnValue -ne 0 -or $helperOwner.Sid -ne $state.UserSid) {
        throw 'Worker is not independently launched by Windows Task Scheduler.'
    }
    Set-Content -LiteralPath (Join-Path $RunDirectory 'go.tmp') -Value $nonce -Encoding ASCII
    Move-Item -LiteralPath (Join-Path $RunDirectory 'go.tmp') -Destination (Join-Path $RunDirectory 'go')
    $released = $true
    [pscustomobject]@{ Status = 'Released'; Target = $state.Target; RunDirectory = $RunDirectory; TaskName = $taskName; Note = 'Read result.json and verify the app after relaunch; release is not completion.' } |
        ConvertTo-Json
} finally {
    if ($createdTask -and -not $released) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
