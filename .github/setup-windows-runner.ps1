#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time setup for a self-hosted Windows GitHub Actions runner
    used to deploy to an Ignition gateway.

.DESCRIPTION
    Configures:
      1. PowerShell execution policy so runner step scripts (.ps1) can execute
      2. NTFS permissions on the Ignition repo/data folder for the runner service account
      3. Restarts the runner service so the execution policy change takes effect
      4. Reports the runner service account and available IPv4 adapters for verification

.NOTES
    Run this in an elevated PowerShell prompt (Run as Administrator).
    Adjust $RepoPath and $ServiceAccount below if your setup differs.
#>

# ---- Configuration: adjust these for your environment ----
$RepoPath = "C:\Program Files\Inductive Automation\Ignition\data"
$RunnerServicePattern = "actions.runner.*"
$ServiceAccount = "NT AUTHORITY\NETWORK SERVICE"   # confirm this matches your runner's actual service account

Write-Host "=== Step 1: Setting PowerShell execution policy (LocalMachine) ===" -ForegroundColor Cyan
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
Write-Host "Execution policy set to RemoteSigned for LocalMachine scope." -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 2: Granting NTFS permissions on repo path ===" -ForegroundColor Cyan
if (Test-Path $RepoPath) {
    icacls "$RepoPath" /grant "${ServiceAccount}:(OI)(CI)F" /T
    Write-Host "Granted Full Control to '$ServiceAccount' on '$RepoPath' (recursive)." -ForegroundColor Green
} else {
    Write-Host "WARNING: Path '$RepoPath' not found. Skipping icacls step — update `$RepoPath and re-run." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Step 3: Restarting runner service ===" -ForegroundColor Cyan
$runnerServices = Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue
if ($runnerServices) {
    foreach ($svc in $runnerServices) {
        Write-Host "Restarting service: $($svc.Name)"
        Restart-Service -Name $svc.Name -Force
    }
    Write-Host "Runner service(s) restarted." -ForegroundColor Green
} else {
    Write-Host "WARNING: No service matching '$RunnerServicePattern' found. Restart it manually once installed." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "=== Step 4: Verification info ===" -ForegroundColor Cyan
Write-Host "Runner service account(s) currently on this box:"
Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize

Write-Host "Available IPv4 adapters (confirm which one is the LAN-facing IP used by the workflow's scan steps):"
Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias, IPAddress | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Setup complete ===" -ForegroundColor Cyan
Write-Host "Reminder: the git safe.directory exception is handled inside the workflow YAML" -ForegroundColor Gray
Write-Host "via GIT_CONFIG_COUNT / GIT_CONFIG_KEY_0 / GIT_CONFIG_VALUE_0 env vars — no action needed here." -ForegroundColor Gray
