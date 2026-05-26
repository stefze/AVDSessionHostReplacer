# Welcome to Azure Virtual Desktop (AVD) Session Host Replacer

## Overview

This tool automates the deployment and replacement of session hosts in an Azure Virtual Desktop host pool.

The best practice for AVD recommends replacing the session hosts instead of maintaining them,
the AVD Session Host Replacer helps you manage the task of deploying refreshed session hosts automatically.

## Getting started

| Deployment Type           | Link                                                                                                                                                                                                                                                                                                                                                                                                                       |
| :------------------------ | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Azure Portal UI           | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fstefze%2FAVDSessionHostReplacer%2Ffeature%2Fadd-only-managed-hosts%2Fdeploy%2Farm%2FDeployAVDSessionHostReplacer.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fstefze%2FAVDSessionHostReplacer%2Ffeature%2Fadd-only-managed-hosts%2Fdeploy%2Fportal-ui%2Fportal-ui.json)
| Command line (Bicep/ARM)  | [![Powershell/Azure CLI](./docs/icons/powershell.png)](./docs/CodeDeploy.md)

## Pre-requisites
The Session Host Replacer requires permissions to manage resources in Azure and, if the session hosts are Entra joined, permissions in Entra. The recommended approach is to create a User Managed Identity, assign the necessary permissions to it, and use it for all instances of the Session Host Replacer.

If you do not select a User Managed Identity, the deployment will create a System Managed Identity and assign permissions to it. However, some additional permissions may need to be assigned manually after deployment. This is not recommended if you have more than one instance of the Session Host Replacer.

Detailed instructions on the required permissions and how to assign them are available [here](docs/Permissions.md).

## How it works?

There are two criteria for deploying refreshed session hosts:

1. **Image Version:** Is there a new image version available? If so, we create a new session host with the new image version. This can be from Marketplace or Gallery Image Definition.
2. **Session Host VM Age:** If a managed session host is older than a certain age (default is 45 days), we create a new session host.

The core of an AVD Session Host Replacer is an Azure Function App built using PowerShell. The function is triggered every hour to check each session host against the above criteria.

To deploy new session hosts, the function uses an ARM Template that is stored as a Template Spec at deployment time.

### Add-Only Behavior

**Session host decommissioning is completely disabled.** The function will only add new session hosts and will never:
- Drain existing session hosts
- Delete or remove existing session hosts  
- Modify existing session hosts
- Apply scaling-plan exclusion tags for pending deletion

All session host removal and cleanup must be performed manually by administrators.

### Managed vs. Legacy Session Hosts

The function distinguishes between "managed" and "legacy" session hosts based on their numeric suffix:

- **Managed Session Hosts:** Session hosts with a numeric suffix >= `_ManagedSessionHostMinSuffix` (default `1025`)
- **Legacy Session Hosts:** Session hosts with a numeric suffix < `_ManagedSessionHostMinSuffix`

**Only managed session hosts are counted toward `_TargetSessionHostCount`.**

The `_ManagedSessionHostMinSuffix` parameter allows you to have pre-existing "legacy" session hosts that are completely ignored by the automation. This is useful when migrating from manual deployments or when you want to maintain some session hosts outside of automation.

**Example:**
- `_ManagedSessionHostMinSuffix` = `1025` (default)
- `_TargetSessionHostCount` = `5`
- Existing hosts: `AVDVM-0001`, `AVDVM-0002`, `AVDVM-1025`, `AVDVM-1027`

In this scenario:
- Legacy hosts (`0001`, `0002`) are ignored and not counted
- Only managed hosts (`1025`, `1027`) are counted = 2 hosts
- The function will deploy 3 new hosts to reach the target of 5: `AVDVM-1026`, `AVDVM-1028`, `AVDVM-1029`

## FAQ
- **Can I use a custom Template Spec for Session Hosts deployment?**

    Yes, you can use a custom Template Spec, right now this is not possible when using the portal UI as you need to customize the ARM template.
    You can base the customization on the [built-in template](StandardSessionHostTemplate/DeploySessionHosts.bicep) making sure of the following,
        - The template must accept an array parameter for the names of VMs to deploy. The default paramter name is `VMNames` and it can be changed using the parameter `VMNamesTemplateParameterName`.
        - To ensure proper cleanup, the template spec should be configured to delete disk and NICs when deleting the VM.
        - The parameter `SessionHostParameters` is a JSON object that will be passed to the template spec when deploying. The VMNames array will be added to this object. Moreover, it must contain the following properties (case sensitive),
            - `ImageReference`: Can be in the Provider/Offer/SKU or Id format for custom images.
            - `Location`: The region where the session hosts will be deployed. This is used when querying for the latest image version when using marketplace images.

- **I just deployed the Session Host Replacer, now what?

    The Session Host Replacer runs every hour on the hour. You can manually trigger it by going to the FunctionApp > timerTrigger1 > Code+Test.

    During the first run, the Session Host Replacer will download required PowerShell modules from the Internet which can take some time. Subsequent runs will be (much) faster.

- **I changed my mind about some of the settings during deployment or I want to upgrade to the latest version, what should I do?**

    You can simply redeploy the Session Host Replacer with the new settings or version. It will overwrite the existing deployment without any impact.

- **How can I force replace a specific session host?**

    On the VM(s) you want to prioritize for refresh logic, update the tag `AutoReplaceDeployTimestamp` to a date older than the target age. On the next run, the function can deploy additional session hosts.

    Existing hosts are not deleted automatically. Decommission/removal must be handled manually.

- **How does target host count work with legacy host names?**

    The `_ManagedSessionHostMinSuffix` parameter (default `1025`) defines which session hosts are managed by the automation. Only session hosts with a numeric suffix greater than or equal to this value are counted toward the `_TargetSessionHostCount`.

    This allows you to have pre-existing "legacy" session hosts that are completely ignored by the automation, enabling a smooth migration from manual deployments.

    **Example:** If `_TargetSessionHostCount` is `5` and existing suffixes are `0231`, `0678`, `0976`, `1025`, `1027`:
    - Legacy hosts (`0231`, `0678`, `0976`) are ignored
    - Only managed hosts (`1025`, `1027`) are counted = 2 hosts  
    - The function deploys 3 new hosts: `1026`, `1028`, `1029`

    See the [Managed vs. Legacy Session Hosts](#managed-vs-legacy-session-hosts) section for more details.

- **Can I change the managed session host baseline after initial deployment?**

    Yes, you can change the `_ManagedSessionHostMinSuffix` parameter by redeploying the Session Host Replacer with a new value. However, be aware that:
    - Increasing the value will exclude some previously managed hosts from the target count
    - Decreasing the value will include previously ignored hosts in the target count
    - This change only affects counting; existing hosts are never modified or deleted

- **What about AVD Scaling Plans?**

    Since session host decommissioning is completely disabled, the function never places hosts in drain mode and never applies scaling-plan exclusion tags. All session hosts remain fully available to the scaling plan.

    If you want to decommission old session hosts, you must manually:
    1. Enable drain mode on the session host
    2. Wait for user sessions to end
    3. Remove the session host from the host pool
    4. Delete the VM and associated resources

- **How do I remove old session hosts?**

    Session host removal must be performed manually. The recommended steps are:
    1. In the Azure Portal, navigate to the host pool
    2. Select the session host you want to remove
    3. Turn on "Drain mode" to prevent new connections
    4. Wait for existing user sessions to end (or notify users)
    5. Delete the session host from the host pool
    6. Delete the VM and associated resources (disk, NIC)
    7. If Entra ID joined, remove the device from Entra ID

- **What happens if a deployment fails?**

    The Session host Replacer checks for failed deployments, if any are found it will NOT take any actions. You should clean up the failed deployment by deleting any resources created, Entra Devices, etc... and delete the failed deployment from the deployment history.

- **The Session Host Replacer is failing, how can I get help?**

    While this is a community project and we do not provide direct support, you can open an issue on GitHub and we will do our best to help you. Please make sure to include the logs of failed run by going to FunctionApp > timerTrigger1 > Invocations. Or manually run from Code+Test and copy the logs.

## Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.opensource.microsoft.com.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft
trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship.
Any use of third-party trademarks or logos are subject to those third-party's policies.
