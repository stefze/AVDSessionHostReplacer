function Set-SHRNewSessionHostDrainMode {
    <#
.SYNOPSIS
    Places newly deployed session hosts into drain mode after they register with the host pool.
.DESCRIPTION
    When the _DeploySessionHostsInDrainMode feature is enabled, new session hosts are tagged at deployment time
    with the DeployInDrainMode tag. Because the deployment runs asynchronously, the host only appears in the host
    pool minutes later. This function is invoked on each timer run to find any registered session host that still
    carries the DeployInDrainMode tag and currently allows new sessions, set it to drain mode (AllowNewSession = false),
    and clear the tag so the action only happens once. Administrators can later allow new sessions when the host is ready.
.NOTES
    Information or caveats about the function e.g. 'This function is not supported in Linux'
.EXAMPLE
    Set-SHRNewSessionHostDrainMode -SessionHosts $sessionHosts
#>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory = $true)]
        [object[]] $SessionHosts,

        [Parameter()]
        [string] $ResourceGroupName = (Get-FunctionConfig _HostPoolResourceGroupName),

        [Parameter()]
        [string] $HostPoolName = (Get-FunctionConfig _HostPoolName),

        [Parameter()]
        [string] $TagDeployInDrainMode = (Get-FunctionConfig _Tag_DeployInDrainMode)
    )

    $sessionHostsToDrain = $SessionHosts | Where-Object { $_.DeployInDrainMode }
    Write-PSFMessage -Level Host -Message 'Found {0} newly deployed session host(s) tagged for drain mode.' -StringValues $sessionHostsToDrain.Count

    foreach ($sessionHost in $sessionHostsToDrain) {
        if ($sessionHost.AllowNewSession -eq $false) {
            Write-PSFMessage -Level Host -Message 'Session host {0} is already in drain mode. Clearing the {1} tag.' -StringValues $sessionHost.FQDN, $TagDeployInDrainMode
        }
        else {
            Write-PSFMessage -Level Host -Message 'Placing newly deployed session host {0} into drain mode.' -StringValues $sessionHost.FQDN
            if ($PSCmdlet.ShouldProcess($sessionHost.FQDN, 'Set AllowNewSession to false')) {
                Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $sessionHost.FQDN -AllowNewSession:$false -ErrorAction Stop
            }
        }

        # Clear the marker tag so we only drain the host once. This allows administrators to allow new sessions later without it being re-drained.
        Write-PSFMessage -Level Host -Message 'Clearing tag {0} on session host {1}.' -StringValues $TagDeployInDrainMode, $sessionHost.FQDN
        if ($PSCmdlet.ShouldProcess($sessionHost.FQDN, "Set tag $TagDeployInDrainMode to False")) {
            $null = Update-AzTag -ResourceId $sessionHost.ResourceId -Tag @{ $TagDeployInDrainMode = 'False' } -Operation Merge
        }
    }
}
