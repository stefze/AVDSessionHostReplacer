function Get-SHRDrainCandidate {
    <#
.SYNOPSIS
    Returns registered session hosts that are tagged to be placed in drain mode after deployment.
.DESCRIPTION
    Lightweight lookup used by the high frequency drain trigger. It lists the session hosts in the host pool
    and, only for those that currently allow new sessions, reads the DeployInDrainMode tag from the VM. This avoids
    the expensive Get-AzVM call done by Get-SHRSessionHost so it can run frequently against large host pools.
    The returned objects expose the FQDN, ResourceId, AllowNewSession and DeployInDrainMode properties consumed by
    Set-SHRNewSessionHostDrainMode.
.EXAMPLE
    Get-SHRDrainCandidate | Set-SHRNewSessionHostDrainMode
#>
    [CmdletBinding()]
    param (
        [Parameter()]
        [string] $ResourceGroupName = (Get-FunctionConfig _HostPoolResourceGroupName),

        [Parameter()]
        [string] $HostPoolName = (Get-FunctionConfig _HostPoolName),

        [Parameter()]
        [string] $TagDeployInDrainMode = (Get-FunctionConfig _Tag_DeployInDrainMode)
    )

    $sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -ErrorAction Stop |
        Select-Object Name, ResourceId, AllowNewSession, Status

    foreach ($item in $sessionHosts) {
        # Only registered hosts that still allow new sessions can be candidates for the initial drain.
        if ($item.AllowNewSession -ne $true) { continue }

        $vmTags = Get-AzTag -ResourceId $item.ResourceId -ErrorAction SilentlyContinue
        if ($vmTags.Properties.TagsProperty[$TagDeployInDrainMode] -eq 'True') {
            [PSCustomObject]@{
                FQDN              = $item.Name -replace ".+\/(.+)", '$1'
                ResourceId        = $item.ResourceId
                AllowNewSession   = $item.AllowNewSession
                DeployInDrainMode = $true
            }
        }
    }
}
