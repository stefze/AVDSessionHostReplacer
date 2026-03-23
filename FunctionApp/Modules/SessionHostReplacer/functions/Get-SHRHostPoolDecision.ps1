function Get-SHRHostPoolDecision {
    <#
    .SYNOPSIS
        This function will decide how many session hosts to deploy and if we should decommission any session hosts.
    #>
    [CmdletBinding()]
    param (
        # Session hosts to consider
        [Parameter()]
        [array] $SessionHosts = @(),

        # Running deployments
        [Parameter()]
        $RunningDeployments,

        # Target age of session hosts in days - after this many days we consider a session host for replacement.
        [Parameter()]
        [int] $TargetVMAgeDays = (Get-FunctionConfig _TargetVMAgeDays),

        # Target number of session hosts in the host pool. If we have more than or equal to this number of session hosts we will decommission some.
        [Parameter()]
        [int] $TargetSessionHostCount = (Get-FunctionConfig _TargetSessionHostCount),

        [Parameter()]
        [int] $TargetSessionHostBuffer = (Get-FunctionConfig _TargetSessionHostBuffer),

        # Latest image version
        [Parameter()]
        [PSCustomObject] $LatestImageVersion,

        # Should we replace session hosts on new image version
        [Parameter()]
        [bool] $ReplaceSessionHostOnNewImageVersion = (Get-FunctionConfig _ReplaceSessionHostOnNewImageVersion),

        # Delay days before replacing session hosts on new image version
        [Parameter()]
        [int] $ReplaceSessionHostOnNewImageVersionDelayDays = (Get-FunctionConfig _ReplaceSessionHostOnNewImageVersionDelayDays),

        # Minimum numeric suffix for session hosts managed by this function.
        [Parameter()]
        [int] $ManagedSessionHostMinSuffix = (Get-FunctionConfig _ManagedSessionHostMinSuffix)
    )

    function Get-SHRSessionHostNumericSuffix {
        param(
            [Parameter(Mandatory = $true)]
            [string] $VMName
        )

        $suffixMatch = [regex]::Match($VMName, '(\d+)$')
        if (-not $suffixMatch.Success) {
            return $null
        }

        [int]$suffixMatch.Groups[1].Value
    }

    # Basic Info
    Write-PSFMessage -Level Host -Message "We have {0} session hosts (included in Automation)" -StringValues $SessionHosts.Count

    [array] $managedSessionHosts = foreach ($sessionHost in $SessionHosts) {
        $numericSuffix = Get-SHRSessionHostNumericSuffix -VMName $sessionHost.VMName
        if ($null -eq $numericSuffix -or $numericSuffix -ge $ManagedSessionHostMinSuffix) {
            $sessionHost
        }
    }

    [array] $legacySessionHosts = foreach ($sessionHost in $SessionHosts) {
        $numericSuffix = Get-SHRSessionHostNumericSuffix -VMName $sessionHost.VMName
        if ($null -ne $numericSuffix -and $numericSuffix -lt $ManagedSessionHostMinSuffix) {
            $sessionHost
        }
    }

    Write-PSFMessage -Level Host -Message "Managed session host suffix baseline is {0}" -StringValues $ManagedSessionHostMinSuffix
    Write-PSFMessage -Level Host -Message "Found {0} managed session hosts (suffix >= baseline or non-numeric suffix)." -StringValues $managedSessionHosts.Count
    Write-PSFMessage -Level Host -Message "Ignoring {0} legacy session hosts with suffix below baseline for deployment count evaluation." -StringValues $legacySessionHosts.Count

    [array] $managedRunningDeployments = foreach ($runningSessionHostName in $RunningDeployments.SessionHostNames) {
        $numericSuffix = Get-SHRSessionHostNumericSuffix -VMName $runningSessionHostName
        if ($null -eq $numericSuffix -or $numericSuffix -ge $ManagedSessionHostMinSuffix) {
            $runningSessionHostName
        }
    }

    [array] $deletionEligibleSessionHosts = $managedSessionHosts | Where-Object { [string]::IsNullOrWhiteSpace($_.AssignedUser) }
    [array] $assignedSessionHosts = $SessionHosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_.AssignedUser) }
    Write-PSFMessage -Level Host -Message "Found {0} session hosts assigned to users." -StringValues $assignedSessionHosts.Count

    # Identify Session hosts that should be replaced
    if ($TargetVMAgeDays -gt 0) {
        $targetReplacementDate = (Get-Date).AddDays(-$TargetVMAgeDays)
        [array] $sessionHostsOldAge = $deletionEligibleSessionHosts | Where-Object { $_.DeployTimestamp -lt $targetReplacementDate }
        Write-PSFMessage -Level Host -Message "Found {0} session hosts to replace due to old age. {1}" -StringValues $sessionHostsOldAge.Count, ($sessionHostsOldAge.VMName -join ',')

    }

    if ($ReplaceSessionHostOnNewImageVersion) {
        $latestImageAge = (New-TimeSpan -Start $LatestImageVersion.Date -End (Get-Date -AsUTC)).TotalDays
        Write-PSFMessage -Level Host -Message "Latest Image {0} is {1:N0} days old." -StringValues $LatestImageVersion.Version, $latestImageAge
        if ($latestImageAge -ge $ReplaceSessionHostOnNewImageVersionDelayDays) {
            Write-PSFMessage -Level Host -Message "Latest Image age is older than (or equal) New Image Delay value {0}" -StringValues $ReplaceSessionHostOnNewImageVersionDelayDays
            [array] $sessionHostsOldVersion = $deletionEligibleSessionHosts | Where-Object { $_.ImageVersion -ne $LatestImageVersion.Version }
            Write-PSFMessage -Level Host -Message "Found {0} session hosts to replace due to new image version. {1}" -StringValues $sessionHostsOldVersion.Count, ($sessionHostsOldVersion.VMName -Join ',')
        }
    }

    [array] $sessionHostsToReplace = ($sessionHostsOldAge + $sessionHostsOldVersion) | Select-Object -Property * -Unique
    Write-PSFMessage -Level Host -Message "Found {0} session hosts to replace in total. {1}" -StringValues $sessionHostsToReplace.Count, ($sessionHostsToReplace.VMName -join ',')

    # Good Session Hosts

    $managedSessionHostsCurrentTotal = ([array]$managedSessionHosts.VMName + [array]$managedRunningDeployments ) | Select-Object -Unique

    Write-PSFMessage -Level Host -Message "We have {0} managed session hosts including {1} managed session hosts being deployed" -StringValues $managedSessionHostsCurrentTotal.Count, $managedRunningDeployments.Count
    Write-PSFMessage -Level Host -Message "We target having {0} session hosts in good shape" -StringValues $TargetSessionHostCount
    Write-PSFMessage -Level Host -Message "We have a buffer of {0} session hosts more than the target." -StringValues $TargetSessionHostBuffer

    $weCanDeployUpTo = $TargetSessionHostCount + $TargetSessionHostBuffer - $managedSessionHosts.count - $managedRunningDeployments.Count
    if ($weCanDeployUpTo -ge 0) {
        Write-PSFMessage -Level Host -Message "We can deploy up to {0} session hosts" -StringValues $weCanDeployUpTo

        $weNeedToDeploy = $TargetSessionHostCount - $managedSessionHostsCurrentTotal.Count
        if ($weNeedToDeploy -gt 0) {
            Write-PSFMessage -Level Host -Message "We need to deploy {0} new session hosts" -StringValues $weNeedToDeploy
            $weCanDeploy = if ($weNeedToDeploy -gt $weCanDeployUpTo) { $weCanDeployUpTo } else { $weNeedToDeploy } # If we need to deploy 10 machines, and we can deploy 5, we should only deploy 5.
            Write-PSFMessage -Level Host -Message "Buffer allows deploying {0} session hosts" -StringValues $weCanDeploy
        }
        else {
            $weCanDeploy = 0
            Write-PSFMessage -Level Host -Message "We have enough session hosts in good shape."
        }
    }
    else {
        Write-PSFMessage -Level Host -Message "Buffer is full. We can not deploy more session hosts"
        $weCanDeploy = 0
    }


    $weCanDelete = 0
    $sessionHostsPendingDelete = @()
    Write-PSFMessage -Level Host -Message "Session host decommissioning is disabled. No session hosts will be deleted."


    [PSCustomObject]@{
        PossibleDeploymentsCount       = $weCanDeploy
        PossibleSessionHostDeleteCount = $weCanDelete
        SessionHostsPendingDelete      = $sessionHostsPendingDelete
        ExistingSessionHostVMNames     = ([array]$SessionHosts.VMName + [array]$managedRunningDeployments) | Select-Object -Unique
    }
}