<#
* Copyright (c) 2019, Contrast Security, Inc.
* All rights reserved.
*
* Redistribution and use in source and binary forms, with or without modification, are
* permitted provided that the following conditions are met:
*
* Redistributions of source code must retain the above copyright notice, this list of
* conditions and the following disclaimer.
*
* Redistributions in binary form must reproduce the above copyright notice, this list of
* conditions and the following disclaimer in the documentation and/or other materials
* provided with the distribution.
*
* Neither the name of the Contrast Security, Inc. nor the names of its contributors may
* be used to endorse or promote products derived from this software without specific
* prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
* EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
* MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
* THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
* SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT
* OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
* INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
* STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
* THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
################### Contrast.NET Agent Automated Install and Configuration Example Script ############
#>
<#
.SYNOPSIS
This script will check if IIS is installed and has applications running using .NET Framework.
If so, it will download the latest available Contrast.NET Agent and install it.
If the agent is already installed, it will be upgraded.
Authentication settings will be taken from the existing installation or parameters of this script.

.DESCRIPTION
If Contrast.NET Agent is already installed, this script will use the Contrast UI authentication settings from
its yaml config file, or DotnetAgentService.config file (for older agents). If these files are not available
or no agent is installed, then the authentication settings below must be passed in as the following parameters.

.PARAMETER ApiUrl
Url for Contrast UI (api.url). Defaults to https://app.contrastsecurity.com if not provided

.PARAMETER ApiKey
Api Key for Contrast UI (api.api_key)

.PARAMETER ServiceKey
Service Key for Contrast UI (api.service_key)

.PARAMETER ApiUserName
Username of Contrast UI (api.user_name)
#>

Param(
  [Parameter(Mandatory=$false)]
  [string] $ApiUrl,
  [Parameter(Mandatory=$false)]
  [string] $ApiKey,
  [Parameter(Mandatory=$false)]
  [string] $ServiceKey,
  [Parameter(Mandatory=$false)]
  [string] $ApiUserName
)

# Function to check if IIS is installed
function Is-IISInstalled {
    $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    return $iisFeature -and $iisFeature.Installed
}

# Function to check if IIS is running
function Is-IISRunning {
    $w3svc = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
    return $w3svc -and $w3svc.Status -eq 'Running'
}

# Function to determine if there are .NET Framework applications running in IIS
function Has-DotNetFrameworkApplications {
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    if (-not (Get-Module -Name WebAdministration)) {
        Write-Host "The WebAdministration module could not be loaded. Ensure you have IIS Management Scripts and Tools installed." -ForegroundColor Yellow
        return $false
    }

    $websites = Get-ChildItem IIS:\Sites

    foreach ($site in $websites) {
        $appPoolName = $site.applicationPool
        $appPool = Get-Item ("IIS:\AppPools\$appPoolName")
        $clrVersion = $appPool.managedRuntimeVersion

        if ($clrVersion -eq "v4.0" -or $clrVersion -eq "v2.0") {
            return $true
        }
    }
    return $false
}

# Start of the main script

# Check if IIS is installed
if (-not (Is-IISInstalled)) {
    Write-Host "IIS is not installed on this system. Exiting script." -ForegroundColor Yellow
    exit
}

# Check if IIS is running
if (-not (Is-IISRunning)) {
    Write-Host "IIS is not running. Starting IIS..."
    Start-Service W3SVC -ErrorAction SilentlyContinue

    if (-not (Is-IISRunning)) {
        Write-Host "Failed to start IIS. Exiting script." -ForegroundColor Red
        exit
    }
}

# Check for .NET Framework applications in IIS
if (-not (Has-DotNetFrameworkApplications)) {
    Write-Host "No .NET Framework applications are running in IIS. The Contrast.NET Agent installation is not necessary." -ForegroundColor Yellow
    exit
}

# Proceed with the existing autoupdate.ps1 script
# Helper function. See below for main script
function GetXmlConfigSetting($xmlDoc, $configKey)
{
    $appSettings = $xmlDoc.configuration.appSettings
    $configElement = $appSettings.add | Where-Object{ $_.key -eq $configKey } | Select-Object -first 1
    if($null -ne $configElement ) {
        return $configElement.value
    }
    else {
        return $null
    }
}

$authSettingsProvided = ($ApiKey -and $ApiUserName -and $ServiceKey)
# Get install folder
$contrastReg = Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Contrast Security, Inc.\Contrast.NET\" -ErrorAction SilentlyContinue -ErrorVariable ProcessError
if(($null -eq $contrastReg) -and (!$authSettingsProvided)) {
    Write-Host -ForegroundColor Yellow "Contrast.NET is not installed. Please pass in the ApiKey, ApiUserName, and ServiceKey parameters"
    exit
}
# if contrast is already installed, try to get authentication settings from it
if($contrastReg -and !$authSettingsProvided) {
    $version = $contrastReg.Version
    $installDirectory = $contrastReg.InstallDirectory
    $dataDirectory = $contrastReg.DataDirectory
    Write-Host "Contrast.NET $version is currently installed"
    # get settings from yaml file
    if(!$ApiUrl -or !$ApiKey -or !$ApiUserName -or !$ServiceKey) {
        $yamlPath = "$dataDirectory\contrast_security.yaml"
        $oldConfigPath = "$installDirectory\DotnetAgentService.exe.config"
        if(Test-Path $yamlPath) {
            Write-Host "Getting authentication settings from yaml config at $yamlPath"
            $ApiUrl = Select-String -Path $yamlPath -Pattern "^\s*url:\s*(.+)" | % { $_.Matches[0].Groups[1].Value.Trim() }
            $ApiKey = Select-String -Path $yamlPath -Pattern "^\s*api_key:\s*(.+)" | % { $_.Matches[0].Groups[1].Value.Trim() }
            $ServiceKey = Select-String -Path $yamlPath -Pattern "^\s*service_key:\s*(.+)" | % { $_.Matches[0].Groups[1].Value.Trim() }
            $ApiUserName = Select-String -Path $yamlPath -Pattern "^\s*user_name:\s*(.+)" | % { $_.Matches[0].Groups[1].Value.Trim() }
        }
        elseif(Test-Path $oldConfigPath) {
            Write-Host "Getting authentication settings from service config at $oldConfigPath"
            $configXml = [xml](Get-Content $oldConfigPath)
            $ApiUrl = GetXmlConfigSetting $configXml "TeamServerUrl"
            $ApiKey = GetXmlConfigSetting $configXml "TeamServerApiKey"
            $ServiceKey = GetXmlConfigSetting $configXml "TeamServerServiceKey"
            $ApiUserName = GetXmlConfigSetting $configXml "TeamServerUserName"
        }
    }
}
if(!$ApiKey -or !$ApiUserName -or !$ServiceKey) {
    Write-Host "Could not determine Contrast authentication settings. Please provide them using the ApiUrl, ApiKey, ApiUserName, and ServiceKey parameters"
    exit
}
if(!$ApiUrl) {
    $ApiUrl = "https://app.contrastsecurity.com"
}
# some old agents still put /Contrast in the url in the config file
elseif($ApiUrl.Contains("/Contrast")) {
    $ApiUrl = $ApiUrl.Substring(0, $ApiUrl.IndexOf("/Contrast"))
}

Write-Host "Api Url: $ApiUrl
ApiKey: $ApiKey
ServiceKey: $ServiceKey
ApiUserName: $ApiUserName"

# 1. Download the agent from Contrast UI
# Make temporary directory where the agent will be downloaded.
$tempName = [System.IO.Path]::GetRandomFileName()
$DestinationPath = (Join-Path $env:TEMP $tempName)

New-Item -ItemType Directory -Path $DestinationPath | Out-Null
Write-Host "Creating temporary directory for agent download: $DestinationPath"

# Download the agent
$enc = [system.Text.Encoding]::ASCII
$authToken = [System.Convert]::ToBase64String($enc.GetBytes($ApiUserName + ":" + $ServiceKey))
$wc = New-Object System.Net.WebClient
# Required for use with web SSL sites
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$wc.Headers.Add("Authorization", $authToken)
$wc.Headers.Add("API-Key", $ApiKey)
$wc.Headers.Add("Accept", "application/json")
$resource = "$ApiUrl/Contrast/s/api/engine/download/dotnet"
$agentFile = "$DestinationPath\ContrastSetup.zip"
Write-Host "Downloading agent installer..."
$wc.DownloadFile($resource, $agentFile)

# 2. Extract the agent
$AgentPath = "$DestinationPath\ContrastSetup.exe"
Add-Type -AssemblyName System.IO.Compression.FileSystem
Write-Host "Extracting agent from downloaded zip"
[System.IO.Compression.ZipFile]::ExtractToDirectory($agentFile, $DestinationPath)

# 3. Install the agent
Write-Host "Installing Contrast.NET Agent: $AgentPath -s -norestart PathToYaml=$DestinationPath\contrast_security.yaml SUPPRESS_RESTARTING_IIS=0 INSTALL_AGENT_EXPLORER=1 INSTALL_UPGRADE_SERVICE=1 StartTray=0" 
# This is a silent install so no GUI will be shown
# To avoid UAC prompts, make sure this script is run in an administrative console
Start-Process -FilePath $AgentPath -ArgumentList "-s -norestart PathToYaml=$DestinationPath\contrast_security.yaml SUPPRESS_RESTARTING_IIS=0 INSTALL_AGENT_EXPLORER=1 INSTALL_UPGRADE_SERVICE=1 StartTray=0" -Wait

# Cleanup the temporary directory
Write-Host "Clearing temporary directory $DestinationPath"
Remove-Item $DestinationPath -Recurse

# Display install status
$contrastReg = Get-ItemProperty "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Contrast Security, Inc.\Contrast.NET\" -ErrorAction SilentlyContinue -ErrorVariable ProcessError
if($contrastReg) {
    $version = $contrastReg.Version
    Write-Host "Contrast.NET $version has been installed."
} else {
    Write-Host -ForegroundColor Red "Contrast.NET was not installed. Please check the error messages or install manually"
}
