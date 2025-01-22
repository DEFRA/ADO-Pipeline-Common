<#
.SYNOPSIS
Azure Resource Manager Deployment Script
.DESCRIPTION
Validate/Deploy resource manager template (arm/bicep) and optionally run What-If analysis for the template.
.PARAMETER TemplateFile
Mandatory. Fully qualified template file name.
.PARAMETER Location
Mandatory. Azure Location.
.PARAMETER ResourceGroupName
Optional. Resource Group Name.
.PARAMETER ParameterFilePath
Optional. Parameter file folder name.
.PARAMETER WhatIf
Mandatory. Flag to run What If analysis.
.PARAMETER Deploy
Mandatory. Flag to deploy the template, True will deploy and False will only validate template.
.EXAMPLE
.\Template-Deployment.ps1 -TemplateFile <TemplateFile> -Location <Location> -ResourceGroupName <ResourceGroupName> -ParameterFilePath <ParameterFilePath> `
                            -WhatIf <True/False> -Deploy <True/False>
#>
[CmdletBinding()]
Param
(
    [Parameter(Mandatory)]
    [string]$TemplateFile,
    [Parameter(Mandatory)]
    [string]$Location,
    [Parameter()]
    [string]$ResourceGroupName,
    [Parameter()]
    [string]$ParameterFilePath,
    [Parameter()]
    [bool]$WhatIf = $false,
    [Parameter()]
    [bool]$Deploy = $false,
    [Parameter()]
    [string]$WorkingDirectory = $PWD
)

Set-StrictMode -Version 3.0

[string]$functionName = $MyInvocation.MyCommand
[datetime]$startTime = [datetime]::UtcNow

[int]$exitCode = -1
[bool]$setHostExitCode = (Test-Path -Path ENV:TF_BUILD) -and ($ENV:TF_BUILD -eq "true")
[bool]$enableDebug = (Test-Path -Path ENV:SYSTEM_DEBUG) -and ($ENV:SYSTEM_DEBUG -eq "true")

Set-Variable -Name ErrorActionPreference -Value Continue -scope global
Set-Variable -Name InformationPreference -Value Continue -Scope global

if ($enableDebug) {
    Set-Variable -Name VerbosePreference -Value Continue -Scope global
    Set-Variable -Name DebugPreference -Value Continue -Scope global
}

Write-Host "${functionName} started at $($startTime.ToString('u'))"
Write-Debug "${functionName}:TemplateFile=$TemplateFile"
Write-Debug "${functionName}:Location=$Location"
Write-Debug "${functionName}:ResourceGroupName=$ResourceGroupName"
Write-Debug "${functionName}:ParameterFilePath=$ParameterFilePath"
Write-Debug "${functionName}:WhatIf=$WhatIf"
Write-Debug "${functionName}:Deploy=$Deploy"

function Get-TemplateParameterFilePath {
    param (
        [Parameter(Mandatory)]
        [string]$TemplateFileName,
        [Parameter()]
        [string]$ParameterFilePath
    )
    begin {
        [string]$functionName = $MyInvocation.MyCommand
        Write-Debug "${functionName}:Entered"
        Write-Debug "${functionName}:TemplateFileName=$TemplateFileName"
        Write-Debug "${functionName}:ParameterFilePath=$ParameterFilePath"
    }
    
    process {
        [string]$parametersPath = ''
        if ($ParameterFilePath -and $(Test-Path $ParameterFilePath)) {
            $parametersPath = Join-Path -Path $ParameterFilePath -ChildPath "$TemplateFileName.transformed.bicepparam"
            Write-Debug "Looking for parameter file: $parametersPath"
            if (-not $(Test-Path -Path $parametersPath)) {
                $parametersPath = Join-Path -Path $ParameterFilePath -ChildPath "$TemplateFileName.transformed.parameters.json"
                Write-Debug "Looking for parameter file: $parametersPath"
                if (-not $(Test-Path -Path $parametersPath)) {
                    throw "Parameter file not found for the template: $TemplateFileName"
                }
            }
        }
        else {
            [string]$templateFolder = Split-Path -Path $TemplateFile
            $parametersPath = Join-Path -Path $templateFolder -ChildPath "$TemplateFileName.transformed.bicepparam"
            Write-Debug "Looking for parameter file: $parametersPath"
            if (-not $(Test-Path -Path $parametersPath)) {
                $parametersPath = Join-Path -Path $templateFolder -ChildPath "$TemplateFileName.transformed.parameters.json"
                Write-Debug "Looking for parameter file: $parametersPath"
                if (-not $(Test-Path -Path $parametersPath)) {
                    throw "Parameter file not found for the template: $TemplateFileName"
                }
            }
        }
        return $parametersPath
    }
    
    end {
        Write-Debug "${functionName}:Exited"
    }
}

try {
    [System.IO.DirectoryInfo]$moduleDir = Join-Path -Path $WorkingDirectory -ChildPath "templates/powershell/modules/ps-helpers"
    Write-Debug "${functionName}:moduleDir.FullName=$($moduleDir.FullName)"
    Import-Module $moduleDir.FullName -Force
    
    [string]$command = ''
    if ($ResourceGroupName -ne '') {
        Write-Host "Checking if the following resource group exists: $ResourceGroupName."
        $command = "az group exists --name $ResourceGroupName"
        $resourceGroupExists = Invoke-CommandLine -Command $command
        Write-Host "Resource group exists: $resourceGroupExists."
        if (-not ([bool]::Parse($resourceGroupExists))) {
            $command = "az group create --name $ResourceGroupName --location $Location"
            Invoke-CommandLine -Command $command | Out-Null
        }
    }

    [string]$fileName = $(Split-Path -Path $TemplateFile -Leaf).Replace('.json', '').Replace('.bicep', '')
    [string]$deploymentName = "$fileName-" + $(Get-Date -Format "yyyyMMdd-HHmmss")
    $baseCommand = "az deployment {0} "
    
    if ($ResourceGroupName -ne '') { $command = $baseCommand -f "group" } else { $command = $baseCommand -f "sub" }
    
    if ($WhatIf) { $command += "what-if " }
    elseif ($Deploy) { $command += "create " }
    else { $command += "validate " }

    if ($ResourceGroupName -ne '') {
        $command += "--resource-group $ResourceGroupName "
    }
    else {
        $command += "--location $Location "
    }
    
    $templateParameterFile = Get-TemplateParameterFilePath -TemplateFileName $fileName -ParameterFilePath $ParameterFilePath
    $command += "--name $deploymentName --template-file $TemplateFile --parameters $templateParameterFile"

    if ($WhatIf) { Write-Host "Starting template What-IF." }
    elseif ($Deploy) { Write-Host "Starting template deployment." }
    else { Write-Host "Starting template validation." }    
    Write-Host "Deployment name is $deploymentName"
    Write-Host "Contents of the parameter file are:"
    Get-Content -Path $templateParameterFile

    if ($WhatIf) { Invoke-CommandLine -Command $command }
    else { Invoke-CommandLine -Command $command | Out-Null }
    if ($Deploy) {
        if ($ResourceGroupName -ne '') { $command = $baseCommand -f "group show -g $ResourceGroupName" } else { $command = $baseCommand -f "sub show" }
        $command += "-n $deploymentName --query properties.outputs"

        $deploymentOutput = Invoke-CommandLine -Command $command
        Write-Host "##vso[task.setvariable variable=azureDeploymentOutputs;]$deploymentOutput"
    }
    $exitCode = 0
}
catch {
    $exitCode = -2
    Write-Error $_.Exception.ToString()
    throw $_.Exception
}
finally {
    [DateTime]$endTime = [DateTime]::UtcNow
    [Timespan]$duration = $endTime.Subtract($startTime)

    Write-Host "${functionName} finished at $($endTime.ToString('u')) (duration $($duration -f 'g')) with exit code $exitCode"
    if ($setHostExitCode) {
        Write-Debug "${functionName}:Setting host exit code"
        $host.SetShouldExit($exitCode)
    }
    exit $exitCode
}
