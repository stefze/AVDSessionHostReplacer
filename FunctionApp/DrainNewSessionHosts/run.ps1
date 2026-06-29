# Input bindings are passed in via param block.
param($Timer)

# This trigger runs frequently to place newly deployed session hosts into drain mode as soon as they register
# with the host pool. It only does work when DeploySessionHostsInDrainMode is enabled, and only touches hosts that
# carry the DeployInDrainMode tag and still allow new sessions, so it is cheap to run at high frequency.
if (-not (Get-FunctionConfig _DeploySessionHostsInDrainMode)) {
    Write-PSFMessage -Level Host -Message "DeploySessionHostsInDrainMode is disabled. Nothing to do."
    return
}

Write-PSFMessage -Level Host -Message "Checking for newly registered session hosts to place in drain mode."
$drainCandidates = Get-SHRDrainCandidate
Write-PSFMessage -Level Host -Message "Found {0} session host(s) pending initial drain." -StringValues $drainCandidates.Count

if ($drainCandidates.Count -gt 0) {
    Set-SHRNewSessionHostDrainMode -SessionHosts $drainCandidates
}
