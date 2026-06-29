function Get-SHRSessionHost {
    <#
.SYNOPSIS
    This function gets Session Host details from a host pool.
.DESCRIPTION
    A longer description of the function, its purpose, common use cases, etc.
.NOTES
    Information or caveats about the function e.g. 'This function is not supported in Linux'
.LINK
    Specify a URI to a help page, this will show when Get-Help -Online is used.
.EXAMPLE
    Test-MyTestFunction -Verbose
    Explanation of the function or its result. You can include multiple examples with additional .EXAMPLE lines
#>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $ResourceGroupName = (Get-FunctionConfig _HostPoolResourceGroupName),
        [Parameter()]
        [string] $HostPoolName = (Get-FunctionConfig _HostPoolName),
        [Parameter()]
        [string] $TagIncludeInAutomation = (Get-FunctionConfig _Tag_IncludeInAutomation),
        [Parameter()]
        [string] $TagDeployTimestamp = (Get-FunctionConfig _Tag_DeployTimestamp),
        [Parameter()]
        [string] $TagPendingDrainTimeStamp = (Get-FunctionConfig _Tag_PendingDrainTimestamp),
        [Parameter()]
        [string] $TagDeployInDrainMode = (Get-FunctionConfig _Tag_DeployInDrainMode),
        [Parameter()]
        [switch] $FixSessionHostTags,
        [Parameter()]
        [bool] $IncludePreExistingSessionHosts = (Get-FunctionConfig _IncludePreExistingSessionHosts)

    )

    # Get current session hosts
    Write-PSFMessage -Level Host -Message 'Getting current session hosts in host pool {0}' -StringValues $HostPoolName
    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop | Select-Object Name, ResourceId, Session, AllowNewSession, Status, AssignedUser
    Write-PSFMessage -Level Host -Message 'Found {0} session hosts' -StringValues $sessionHosts.Count

    # Bulk fetch VM details (created time, image version and tags) for all session hosts in a single Azure Resource Graph
    # query instead of one Get-AzVM + Get-AzTag call per host. This keeps enumeration fast for large host pools.
    Write-PSFMessage -Level Host -Message 'Getting VM details for {0} session hosts using Azure Resource Graph' -StringValues $sessionHosts.Count
    $vmQuery = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| project id, name, timeCreated = properties.timeCreated, exactVersion = properties.storageProfile.imageReference.exactVersion, tags
"@
    $vmLookup = @{}
    $skipToken = $null
    do {
        $graphParams = @{ Query = $vmQuery; First = 1000 }
        if ($skipToken) { $graphParams['SkipToken'] = $skipToken }
        $batch = Search-AzGraph @graphParams -ErrorAction Stop
        foreach ($vm in $batch) {
            $vmLookup[$vm.id.ToLower()] = $vm
        }
        $skipToken = $batch.SkipToken
    } while ($skipToken)
    Write-PSFMessage -Level Host -Message 'Retrieved {0} VM records from Azure Resource Graph' -StringValues $vmLookup.Count

    # For each session host, combine the host pool details with the VM details
    $result = foreach ($item in $sessionHosts) {
        $vm = $vmLookup[$item.ResourceId.ToLower()]
        if (-not $vm) {
            Write-PSFMessage -Level Warning -Message 'Could not find VM details for session host {0}. Skipping.' -StringValues $item.Name
            continue
        }
        $vmTimeCreated = [DateTime]$vm.timeCreated
        Write-PSFMessage -Level Host -Message 'VM was created on {0}' -StringValues $vmTimeCreated
        Write-PSFMessage -Level Host -Message 'VM exact version is {0}' -StringValues $vm.exactVersion

        # Tags come back from Resource Graph as a dictionary; index directly by tag name.
        $vmTagsProperty = @{}
        if ($vm.tags) {
            foreach ($tag in $vm.tags.PSObject.Properties) { $vmTagsProperty[$tag.Name] = $tag.Value }
        }
        #region: Tag DeployTimestamp
        $vmDeployTimeStamp = $vmTagsProperty[$TagDeployTimestamp]
        try {
            $vmDeployTimeStamp = [DateTime]::Parse($vmDeployTimeStamp)
            Write-PSFMessage -Level Host -Message 'VM has a tag {0} with value {1}' -StringValues $TagDeployTimestamp, $vmDeployTimeStamp
        }
        catch {
            $value = if ($null -eq $vmDeployTimeStamp) { 'null' } else { $vmDeployTimeStamp }
            Write-PSFMessage -Level Host -Message 'VM tag {0} with value {1} is not a valid date' -StringValues $TagDeployTimestamp, $value
            if ($FixSessionHostTags) {
                Write-PSFMessage -Level Host -Message 'Copying VM CreateTime to tag {0} with value {1}' -StringValues $TagDeployTimestamp, $vmTimeCreated.ToString('o')
                Update-AzTag -ResourceId $item.ResourceId -Tag @{ $TagDeployTimestamp = $vmTimeCreated.ToString('o') } -Operation Merge
            }
            $vmDeployTimeStamp = $vmTimeCreated
        }
        #endregion: Tag DeployTimestamp

        #region: Tag IncludeInAutomation
        $vmIncludeInAutomation = $vmTagsProperty[$TagIncludeInAutomation]
        if ($vmIncludeInAutomation -eq "True") {
            Write-PSFMessage -Level Host -Message 'VM has a tag {0} with value {1}' -StringValues $TagIncludeInAutomation, $vmIncludeInAutomation
            $vmIncludeInAutomation = $true
        }
        elseif ($vmIncludeInAutomation -eq "False") {
            Write-PSFMessage -Level Host -Message 'VM has a tag {0} with value {1}' -StringValues $TagIncludeInAutomation, $vmIncludeInAutomation
            $vmIncludeInAutomation = $false
        }
        else {
            $value = if ($null -eq $vmIncludeInAutomation) { 'null' } else { $vmIncludeInAutomation }
            Write-PSFMessage -Level Host -Message 'VM tag {0} with value {1} is not set to True/False' -StringValues $TagIncludeInAutomation, $value
            if ($FixSessionHostTags) {
                Write-PSFMessage -Level Host -Message 'Setting tag {0} to {1}' -StringValues $TagIncludeInAutomation, $IncludePreExistingSessionHosts
                Update-AzTag -ResourceId $item.ResourceId -Tag @{ $TagIncludeInAutomation = "$IncludePreExistingSessionHosts" } -Operation Merge
            }

            $vmIncludeInAutomation = $IncludePreExistingSessionHosts
        }
        #endregion: Tag IncludeInAutomation

        #region: Tag PendingDrainTimeStamp
        $vmPendingDrainTimeStamp = $vmTagsProperty[$TagPendingDrainTimeStamp]
        try {
            $vmPendingDrainTimeStamp = [DateTime]::Parse($vmPendingDrainTimeStamp)
            Write-PSFMessage -Level Host -Message 'VM has a tag {0} with value {1}' -StringValues $TagPendingDrainTimeStamp, $vmPendingDrainTimeStamp
        }
        catch {
            Write-PSFMessage -Level Host -Message "VM tag {0} is not set." -StringValues $TagPendingDrainTimeStamp
            $vmPendingDrainTimeStamp = $null
        }

        #endregion: Tag PendingDrainTimeStamp

        #region: Tag DeployInDrainMode
        $vmDeployInDrainMode = $vmTagsProperty[$TagDeployInDrainMode]
        if ($vmDeployInDrainMode -eq "True") {
            Write-PSFMessage -Level Host -Message 'VM has a tag {0} with value {1}' -StringValues $TagDeployInDrainMode, $vmDeployInDrainMode
            $vmDeployInDrainMode = $true
        }
        else {
            $vmDeployInDrainMode = $false
        }
        #endregion: Tag DeployInDrainMode

        $vmOutput = @{ # We are combining the VM details and SessionHost objects into a single PS Custom Object
            VMName                = $vm.name
            FQDN                  = $item.Name -replace ".+\/(.+)", '$1'
            DeployTimestamp       = $vmDeployTimeStamp
            IncludeInAutomation   = $vmIncludeInAutomation
            PendingDrainTimeStamp = $vmPendingDrainTimeStamp
            DeployInDrainMode     = $vmDeployInDrainMode
            ImageVersion          = $vm.exactVersion
        }
        $item.PSObject.Properties.ForEach{ $vmOutput[$_.Name] = $_.Value }

        [PSCustomObject]$vmOutput

    }

    $result
}