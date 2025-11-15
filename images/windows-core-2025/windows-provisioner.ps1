$ErrorActionPreference = "Continue"
$VerbosePreference = "Continue"

# Install Chocolatey
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$env:chocolateyUseWindowsCompression = 'true'
Invoke-WebRequest https://chocolatey.org/install.ps1 -UseBasicParsing | Invoke-Expression

# Add Chocolatey to powershell profile
$ChocoProfileValue = @'
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}

refreshenv
'@
# Write it to the $profile location
Set-Content -Path "$PsHome\Microsoft.PowerShell_profile.ps1" -Value $ChocoProfileValue -Force
# Source it
. "$PsHome\Microsoft.PowerShell_profile.ps1"

refreshenv

Write-Host "Installing cloudwatch agent..."
Invoke-WebRequest -Uri https://s3.amazonaws.com/amazoncloudwatch-agent/windows/amd64/latest/amazon-cloudwatch-agent.msi -OutFile C:\amazon-cloudwatch-agent.msi
$cloudwatchParams = '/i', 'C:\amazon-cloudwatch-agent.msi', '/qn', '/L*v', 'C:\CloudwatchInstall.log'
Start-Process "msiexec.exe" $cloudwatchParams -Wait -NoNewWindow
Remove-Item C:\amazon-cloudwatch-agent.msi

# Install dependent tools
Write-Host "Installing additional development tools"
choco install git awscli -y
refreshenv

Write-Host "Creating actions-runner directory for the GH Action installation"
New-Item -ItemType Directory -Path C:\actions-runner ; Set-Location C:\actions-runner

Write-Host "Downloading the GH Action runner from ${action_runner_url}"
# Retry logic for downloading the runner with increased timeout and retry attempts
$maxRetries = 1
$retryCount = 0
$downloadSuccess = $false

while ($retryCount -lt $maxRetries -and -not $downloadSuccess) {
  try {
    $retryCount++
    Write-Host "Download attempt $retryCount of $maxRetries"
        
    # Use more robust download parameters
    Invoke-WebRequest -Uri ${action_runner_url} -OutFile actions-runner.zip -TimeoutSec 300 -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        
    # Verify the file was downloaded and has content
    if (Test-Path "actions-runner.zip" -and (Get-Item "actions-runner.zip").Length -gt 0) {
      Write-Host "Download completed successfully"
      $downloadSuccess = $true
    }
    else {
      throw "Downloaded file is empty or missing"
    }
  }
  catch {
    Write-Host "Download attempt $retryCount failed: $($_.Exception.Message)"
    if (Test-Path "actions-runner.zip") {
      Remove-Item "actions-runner.zip" -Force
    }
    if ($retryCount -lt $maxRetries) {
      Write-Host "Waiting 10 seconds before retry..."
      Start-Sleep -Seconds 10
    }
  }
}

if (-not $downloadSuccess) {
  Write-Error "Failed to download GitHub Actions runner after $maxRetries attempts"
  exit 1
}

Write-Host "Un-zip action runner"
Expand-Archive -Path actions-runner.zip -DestinationPath .

Write-Host "Delete zip file"
Remove-Item actions-runner.zip

$action = New-ScheduledTaskAction -WorkingDirectory "C:\actions-runner" -Execute "PowerShell.exe" -Argument "-File C:\start-runner.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "runnerinit" -Action $action -Trigger $trigger -User System -RunLevel Highest -Force

Write-Host "Running EC2Launch v2 to signal instance ready..."
& "$${env:ProgramFiles}\Amazon\EC2Launch\EC2Launch.exe" run