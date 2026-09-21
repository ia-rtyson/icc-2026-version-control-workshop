#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Full teardown / undo for setup-runner-permissions.ps1.

.DESCRIPTION
    Reverts everything the setup script applied AND removes the self-hosted
    GitHub Actions runner itself, so the box can be re-tested from a clean
    slate (re-register the runner, re-run setup-runner-permissions.ps1,
    re-trigger the workflow, confirm the original failure is fixed again).

    Steps:
      1. Revert PowerShell execution policy back to Undefined at
         LocalMachine scope (for both powershell.exe and pwsh.exe, if
         present)  -  this restores the original "running scripts is
         disabled" failure mode rather than guessing at whatever the
         pre-existing value was.
      2. Detect the runner service account and remove (only) the explicit
         Full Control grant this setup added on the Ignition data folder,
         via icacls /remove:g  -  this does not touch any other ACEs on that
         folder.
      3. Stop the runner service and unregister it from GitHub (repo or
         org level), then uninstall the Windows service.
      4. Optionally delete the local runner install directory.
      5. Print a verification summary.

    Safe to re-run: every step is a no-op if already undone (e.g. no
    grant to remove, no service to stop).

.NOTES
    Run this in an elevated PowerShell prompt (Run as Administrator) on the
    self-hosted runner box.

    To unregister the runner from GitHub you need EITHER:
      - A removal token from the GitHub UI (repo/org Settings > Actions >
        Runners > select runner > Remove)  -  valid ~1 hour, paste into
        $RemovalToken below, OR
      - A GitHub Personal Access Token with 'repo' (repo-level runner) or
        'admin:org' (org-level runner) scope in $GitHubPAT  -  the script
        fetches a removal token via the API automatically.
    If neither is supplied, GitHub-side deregistration is skipped (with a
    clear warning) but every local step (policy, permissions, service,
    directory) still runs, so you're not blocked from retesting locally.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$exitCode = 0

# ---- Configuration: adjust for your environment ----
$RepoPath             = "C:\Program Files\Inductive Automation\Ignition\data"
$RunnerServicePattern = "actions.runner.*"
$RunnerDir            = "C:\actions-runner"                       # where the runner was installed
$RepoOrOrgUrl         = "https://github.com/OWNER/REPO"           # or "https://github.com/ORG" for org-level
$FallbackAccount      = "NT AUTHORITY\NETWORK SERVICE"            # used only if the service can't be found

# Option A: paste a removal/registration token obtained from the GitHub UI
$RemovalToken = ""

# Option B: leave $RemovalToken blank and set a PAT here instead;
# the script fetches a removal token via the API automatically
$GitHubPAT = ""

# Set to $true to also delete the local runner install directory after
# GitHub-side removal succeeds (or is skipped). No prompt  -  this script is
# meant to run unattended for repeatable retesting.
$DeleteLocalRunnerDir = $true

# ------------------------------------------------------------------

function Write-Section($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}

function Reset-PolicyForHost {
    param([string]$ExeName, [string]$DisplayName)
    $exe = Get-Command $ExeName -ErrorAction SilentlyContinue
    if (-not $exe) {
        Write-Host "$DisplayName not found on this box  -  skipping." -ForegroundColor Gray
        return
    }
    $cmd = "try { Set-ExecutionPolicy -ExecutionPolicy Undefined -Scope LocalMachine -Force; " +
           "Write-Output ('RESULT:' + (Get-ExecutionPolicy -Scope LocalMachine)) } " +
           "catch { Write-Output ('ERROR:' + `$_.Exception.Message) }"
    $output = (& $exe.Source -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String).Trim()
    if ($output -like "RESULT:*") {
        Write-Host "$DisplayName ($($exe.Source)): LocalMachine execution policy cleared (now: $($output.Substring(7)))." -ForegroundColor Green
    } else {
        Write-Host "WARNING: $DisplayName reported: $output" -ForegroundColor Yellow
        $script:exitCode = 1
    }
}

Write-Section "Step 1: Reverting PowerShell execution policy"
Reset-PolicyForHost -ExeName "powershell.exe" -DisplayName "Windows PowerShell 5.1"
Reset-PolicyForHost -ExeName "pwsh.exe"       -DisplayName "PowerShell 7+"
Get-ExecutionPolicy -List | Format-Table -AutoSize

Write-Section "Step 2: Removing NTFS permissions grant"
$runnerServicesForAccount = Get-CimInstance -ClassName Win32_Service -Filter "Name LIKE 'actions.runner%'" -ErrorAction SilentlyContinue
if ($runnerServicesForAccount) {
    $ServiceAccount = ($runnerServicesForAccount | Select-Object -First 1 -ExpandProperty StartName)
} else {
    Write-Host "No runner service found to read the account from  -  falling back to $FallbackAccount for the icacls removal." -ForegroundColor Yellow
    $ServiceAccount = $FallbackAccount
}
Write-Host "Removing grant for: $ServiceAccount"

if (Test-Path -LiteralPath $RepoPath) {
    $icaclsOutput = & icacls "$RepoPath" /remove:g "$ServiceAccount" /T /C 2>&1
    $icaclsExit = $LASTEXITCODE
    $icaclsOutput | ForEach-Object { Write-Host $_ }
    if ($icaclsExit -eq 0) {
        Write-Host "Removed explicit grant for '$ServiceAccount' on '$RepoPath' (recursive)." -ForegroundColor Green
    } else {
        Write-Host "WARNING: icacls exited with code $icaclsExit while removing the grant  -  some paths may be unchanged." -ForegroundColor Yellow
        $exitCode = 1
    }
} else {
    Write-Host "WARNING: Path '$RepoPath' not found. Nothing to revert there." -ForegroundColor Yellow
}

Write-Section "Step 3: Unregistering runner from GitHub"
if (-not $RemovalToken -and $GitHubPAT) {
    Write-Host "Fetching removal token via GitHub API..."
    $parts = $RepoOrOrgUrl -replace "https://github.com/", "" -split "/"
    $apiUrl = if ($parts.Count -eq 1) {
        "https://api.github.com/orgs/$($parts[0])/actions/runners/remove-token"
    } else {
        "https://api.github.com/repos/$($parts[0])/$($parts[1])/actions/runners/remove-token"
    }
    try {
        $response = Invoke-RestMethod -Method Post -Uri $apiUrl `
            -Headers @{ Authorization = "token $GitHubPAT"; Accept = "application/vnd.github+json" }
        $RemovalToken = $response.token
        Write-Host "Removal token retrieved." -ForegroundColor Green
    } catch {
        Write-Host "ERROR: Failed to fetch removal token via API: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Set `$RemovalToken manually (from the GitHub UI) and re-run, or continue  -  local cleanup still proceeds." -ForegroundColor Yellow
        $exitCode = 1
    }
}

$githubDeregistered = $false
if (Test-Path -LiteralPath $RunnerDir) {
    Push-Location $RunnerDir

    Write-Host "Stopping runner service..."
    $svc = Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue
    if ($svc) {
        foreach ($s in $svc) {
            Write-Host "Stopping service: $($s.Name)"
            Stop-Service -Name $s.Name -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "No running runner service found  -  may already be stopped or never installed as a service."
    }

    if ($RemovalToken -and (Test-Path ".\config.cmd")) {
        & .\config.cmd remove --token $RemovalToken
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Runner unregistered from GitHub." -ForegroundColor Green
            $githubDeregistered = $true
        } else {
            Write-Host "WARNING: config.cmd remove exited with code $LASTEXITCODE  -  check token validity (tokens expire ~1hr) and re-run." -ForegroundColor Yellow
            $exitCode = 1
        }
    } elseif (-not $RemovalToken) {
        Write-Host "No removal token available  -  skipping GitHub-side deregistration." -ForegroundColor Yellow
        Write-Host "Remove it manually via: repo/org Settings > Actions > Runners > select runner > Remove." -ForegroundColor Yellow
    } else {
        Write-Host "WARNING: config.cmd not found in '$RunnerDir'  -  cannot unregister automatically." -ForegroundColor Yellow
        Write-Host "Remove it manually via: repo/org Settings > Actions > Runners > select runner > Remove." -ForegroundColor Yellow
    }

    if (Test-Path ".\svc.cmd") {
        Write-Host "Uninstalling service registration via svc.cmd..."
        & .\svc.cmd uninstall 2>$null
    } else {
        Write-Host "WARNING: svc.cmd not found  -  skipping service uninstall command (service may already be gone)." -ForegroundColor Yellow
    }

    Pop-Location
} else {
    Write-Host "Runner directory '$RunnerDir' not found  -  nothing to stop/unregister locally. Update `$RunnerDir if it differs." -ForegroundColor Yellow
}

Write-Section "Step 4: Deleting local runner directory"
if ($DeleteLocalRunnerDir) {
    if (Test-Path -LiteralPath $RunnerDir) {
        Set-Location $env:TEMP
        Remove-Item -Path $RunnerDir -Recurse -Force
        Write-Host "Deleted '$RunnerDir'." -ForegroundColor Green
    } else {
        Write-Host "Nothing to delete  -  '$RunnerDir' does not exist." -ForegroundColor Gray
    }
} else {
    Write-Host "`$DeleteLocalRunnerDir is `$false  -  leaving '$RunnerDir' in place." -ForegroundColor Gray
}

Write-Section "Step 5: Verification"
Write-Host "Execution policy (LocalMachine scope):"
Get-ExecutionPolicy -Scope LocalMachine

Write-Host ""
Write-Host "Runner service(s) still present (should be none):"
Get-Service -Name $RunnerServicePattern -ErrorAction SilentlyContinue | Select-Object Name, Status | Format-Table -AutoSize

Write-Host ""
Write-Section "Undo complete"
if (-not $githubDeregistered -and -not $RemovalToken) {
    Write-Host "Local state (policy, permissions, service, directory) is reverted, but the runner may still show as" -ForegroundColor Yellow
    Write-Host "green/idle in the GitHub UI since no token was supplied  -  remove it there before re-registering a new one" -ForegroundColor Yellow
    Write-Host "with the same name, or GitHub will reject the duplicate." -ForegroundColor Yellow
}
if ($exitCode -ne 0) {
    Write-Host "Completed with warnings  -  review the WARNING lines above." -ForegroundColor Yellow
} else {
    Write-Host "All steps completed cleanly. Box is back to a pre-setup, pre-registration state for retesting." -ForegroundColor Green
}
exit $exitCode
