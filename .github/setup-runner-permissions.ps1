#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time setup for a self-hosted Windows GitHub Actions runner used to
    deploy to an Ignition gateway.

.DESCRIPTION
    Fixes the failure:
        "File ...\_work\_temp\<guid>.ps1 cannot be loaded because running
         scripts is disabled on this system... PSSecurityException:
         UnauthorizedAccess"

    That error is a PowerShell execution-policy block, not an NTFS
    permissions problem, so this script's first and load-bearing action is
    Step 1. Steps 2-3 additionally grant the runner's service account write
    access to the Ignition data folder, since later steps in the deploy
    workflow (git checkout/clean against that folder) need it.

    Steps:
      1. Set PowerShell execution policy to RemoteSigned at LocalMachine
         scope, for the current PowerShell host (the one this script is
         running under).
      2. Auto-detect the actual account the actions.runner.* service runs
         as (do not assume NETWORK SERVICE  -  verify it).
      3. Grant that account Full Control (recursive) on the Ignition data
         folder via icacls.
      4. Restart the runner service so nothing is left mid-transition.
      5. Print a verification summary.

    Safe to re-run: every step only applies a state, it does not toggle
    anything, so running this twice does not double-grant or break anything.

.NOTES
    Run this in an elevated PowerShell prompt (Run as Administrator) on the
    self-hosted runner box, BEFORE the first workflow run on that machine.

    If the box still fails with "running scripts is disabled" when you try
    to launch THIS script, that's the same policy blocking the script
    runner itself  -  run this one line directly in the elevated console
    first, then re-run this script normally:

        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

    Companion script: undo-runner-permissions.ps1 reverts everything this
    script does, so you can put the machine back into the failing state and
    re-test the fix.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$exitCode = 0

# ---- Configuration: adjust only if your box differs ----
$RepoPath             = "C:\Program Files\Inductive Automation\Ignition\data"
$RunnerServicePattern = "actions.runner.*"
$FallbackAccount      = "NT AUTHORITY\NETWORK SERVICE"   # used only if the service can't be found yet

function Write-Section($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

Write-Section "Step 1: PowerShell execution policy"
try {
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
    Write-Host "Execution policy set to RemoteSigned at LocalMachine scope." -ForegroundColor Green
} catch {
    Write-Host "WARNING: Failed to set execution policy: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "This usually means a Group Policy / MDM baseline (e.g. an AWS WorkSpaces image policy) is forcing" -ForegroundColor Yellow
    Write-Host "execution policy at a scope Set-ExecutionPolicy cannot override. Check with: Get-ExecutionPolicy -List" -ForegroundColor Yellow
    $exitCode = 1
}

Write-Host ""
Write-Host "Effective policy chain (informational  -  MachinePolicy/UserPolicy rows, if present, take precedence" -ForegroundColor Gray
Write-Host "over the LocalMachine value this script just set):" -ForegroundColor Gray
Get-ExecutionPolicy -List | Format-Table -AutoSize

Write-Section "Step 2: Detecting the runner service account"
$runnerServices = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'actions.runner%'" -ErrorAction SilentlyContinue
$ServiceAccount = $null
if ($runnerServices) {
    foreach ($svc in $runnerServices) {
        Write-Host "Service '$($svc.Name)' runs as: $($svc.StartName)"
    }
    $ServiceAccount = ($runnerServices | Select-Object -First 1 -ExpandProperty StartName)
} else {
    Write-Host "WARNING: No service matching '$RunnerServicePattern' found yet." -ForegroundColor Yellow
    Write-Host "Falling back to default assumption: $FallbackAccount" -ForegroundColor Yellow
    Write-Host "Re-run this script once the runner is installed/registered as a service to confirm the real account." -ForegroundColor Yellow
    $ServiceAccount = $FallbackAccount
}
Write-Host "Using service account for permissions grant: $ServiceAccount" -ForegroundColor Green

Write-Section "Step 3: Granting NTFS permissions on repo path"
if (Test-Path -LiteralPath $RepoPath) {
    # icacls writes normal progress lines to stdout AND to stderr for some
    # Windows builds; capture both and check the exit code, don't rely on
    # PowerShell's stream coloring to judge success.
    $icaclsOutput = & icacls "$RepoPath" /grant "${ServiceAccount}:(OI)(CI)F" /T /C 2>&1
    $icaclsExit = $LASTEXITCODE
    $icaclsOutput | ForEach-Object { Write-Host $_ }
    if ($icaclsExit -eq 0) {
        Write-Host "Granted Full Control to '$ServiceAccount' on '$RepoPath' (recursive)." -ForegroundColor Green
    } else {
        Write-Host "WARNING: icacls exited with code $icaclsExit  -  some paths under '$RepoPath' may not have been updated" -ForegroundColor Yellow
        Write-Host "(this is common for a few in-use files under Ignition's data folder; /C tells icacls to continue past them)." -ForegroundColor Yellow
        $exitCode = 1
    }
} else {
    Write-Host "WARNING: Path '$RepoPath' not found. Skipping icacls step  -  update `$RepoPath in this script and re-run." -ForegroundColor Yellow
    $exitCode = 1
}

Write-Section "Step 4: Restarting runner service"
$runnerServices = Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue
if ($runnerServices) {
    foreach ($svc in $runnerServices) {
        Write-Host "Restarting service: $($svc.Name)"
        try {
            Restart-Service -Name $svc.Name -Force
            Write-Host "Restarted '$($svc.Name)'." -ForegroundColor Green
        } catch {
            Write-Host "WARNING: Failed to restart '$($svc.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
            $exitCode = 1
        }
    }
} else {
    Write-Host "WARNING: No service matching '$RunnerServicePattern' found. Nothing to restart  -  start it manually once installed." -ForegroundColor Yellow
}

Write-Section "Step 5: Verification"
Write-Host "Execution policy (LocalMachine scope):"
Get-ExecutionPolicy -Scope LocalMachine

Write-Host ""
Write-Host "Runner service(s):"
Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize

Write-Host "Available IPv4 adapters (confirm which one is the LAN-facing IP the workflow's scan steps rely on):"
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize

Write-Host ""
Write-Host "Reminder: the git safe.directory exception is handled inside the workflow YAML" -ForegroundColor Gray
Write-Host "via GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0 env vars  -  no action needed here." -ForegroundColor Gray

Write-Section "Setup complete"
if ($exitCode -ne 0) {
    Write-Host "Completed with warnings  -  review the WARNING lines above before trusting this box for the next workflow run." -ForegroundColor Yellow
} else {
    Write-Host "All steps applied cleanly." -ForegroundColor Green
}
exit $exitCode
