/*
This solution is made up of:
1- AppServicePlan - Used to host all functions
2- Azure Function: AVDSessionHostReplacer
4- StorageAccount - To store FunctionApp
5- LogAnalyticsWorkspace - Used to store Logs, and AppService insights
*/

//------ Parameters ------//
@description('Required: No | Region of the Function App. This does not need to be the same as the location of the Azure Virtual Desktop Host Pool. | Default: Location of the resource group.')
param Location string = resourceGroup().location

//Storage Account
@description('Required: Yes | Name of the storage account used by the Function App. This name must be unique across all existing storage account names in Azure. It must be 3 to 24 characters in length and use numbers and lower-case letters only.')
param StorageAccountName string

//Log Analytics Workspace
@description('Required: Yes | Name of the Log Analytics Workspace used by the Function App Insights.')
param LogAnalyticsWorkspaceName string

//FunctionApp
@description('Required: Yes | Name of the Function App.')
param FunctionAppName string

@description('Required: No | Subscription ID of the Azure Virtual Desktop Host Pool. | Default: The subscription ID of the resource group.')
param SubscriptionId string = subscription().subscriptionId

@description('Required: No | Name of the resource group containing the Azure Virtual Desktop Host Pool. | Default: The resource group of the Function App.')
param HostPoolResourceGroupName string = resourceGroup().name

@description('Required: No | Use this if you want to deploy VMs in a different Resource Group. By default it will be the same Resource Group as Host Pool | Default: Leave it empty to use the host pool resource group.')
param SessionHostResourceGroupName string = ''

@description('Required: Yes | Name of the Azure Virtual Desktop Host Pool.')
param HostPoolName string

@description('Required: No | URL of the FunctionApp.zip package. By default, this is derived from the current template URL so it follows the deployed repo branch automatically.')
param FunctionAppZipUrl string = contains(deployment().properties, 'templateLink') && !empty(deployment().properties.templateLink.uri)
  ? uri(replace(split(deployment().properties.templateLink.uri, '?')[0], 'DeployAVDSessionHostReplacer.json', ''), '../../FunctionApp/FunctionApp.zip')
  : 'https://github.com/WillyMoselhy/AVDReplacementPlans/releases/download/v0.1.5/FunctionApp.zip'

@description('Required: No | If true, will apply tags for Include In Auto Replace and Deployment Timestamp to existing session hosts. This will not enable automatic deletion of existing session hosts. | Default: True.')
param FixSessionHostTags bool = true

@description('Required: No | Tag name used to indicate that a session host should be included in the automatic replacement process. | Default: IncludeInAutoReplace.')
param TagIncludeInAutomation string = 'IncludeInAutoReplace'

@description('Required: No | Tag name used to indicate the timestamp of the last deployment of a session host. | Default: AutoReplaceDeployTimestamp.')
param TagDeployTimestamp string = 'AutoReplaceDeployTimestamp'

@description('Required: No | Tag name used to indicate drain timestamp of session host pending deletion. | Default: AutoReplacePendingDrainTimestamp.')
param TagPendingDrainTimestamp string = 'AutoReplacePendingDrainTimestamp'

@description('Required: No | Tag name used to exclude session host from Scaling Plan activities. | Default: ScalingPlanExclusion')
param TagScalingPlanExclusionTag string = 'ScalingPlanExclusion'

@description('Required: No | Target age of session hosts in days. | Default:  45 days.')
param TargetVMAgeDays int = 45

@description('Required: No | Grace period in hours for session hosts to drain before deletion. | Default: 24 hours.')
param DrainGracePeriodHours int = 24

@description('Required: No | Prefix used for the deployment name of the session hosts. | Default: AVDSessionHostReplacer')
param SHRDeploymentPrefix string = 'AVDSessionHostReplacer'

@description('Required: Yes | Number of session hosts to maintain in the host pool.')
param TargetSessionHostCount int

@description('Required: Yes | Prefix used for the name of the session hosts.')
param SessionHostNamePrefix string

@description('Required: Yes | URI or Template Spec Resource Id of the arm template used to deploy the session hosts.')
param SessionHostTemplate string

@description('Required: Yes | A compressed (one line) json string containing the parameters of the template used to deploy the session hosts.')
param SessionHostParameters string

@description('Required: Yes, for Active Directory Domain Services | Distinguished Name of the OU to join session hosts to.')
param ADOrganizationalUnitPath string = ''

@description('Required: Yes | Resource ID of the subnet to deploy session hosts to.')
param SubnetId string

@description('Required: No | Number of digits to use for the instance number of the session hosts (eg. AVDVM-01). | Default: 2')
param SessionHostInstanceNumberPadding int = 2

@description('Required: No | Minimum numeric suffix for managed session hosts. Hosts below this suffix are ignored when calculating how many new hosts to deploy. | Default: 1025')
param ManagedSessionHostMinSuffix int = 1025

@description('Required: No | If true, will replace session hosts when a new image version is detected. | Default: true')
param ReplaceSessionHostOnNewImageVersion bool = true

@description('Required: No | Delay in days before replacing session hosts when a new image version is detected. | Default: 0 (no delay).')
param ReplaceSessionHostOnNewImageVersionDelayDays int = 0

@description('Required: No | App Service Plan SKU name | Default: FC1 for Flex Consumption plan')
param AppPlanName string = 'FC1'

@description('Required: No | App Service Plan Tier | Default: FlexConsumption for Flex Consumption plan')
param AppPlanTier string = 'FlexConsumption'

//-------//

//------ Variables ------//
var varFunctionAppSettings = [
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'AzureWebJobs.timerTrigger1.Disabled'
    value: '1'
  }
  {
    name: 'AzureWebJobsStorage'
    value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${storageAccount.listKeys().keys[0].value}'
  }
  {
    name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
    value: appInsights.properties.InstrumentationKey
  }
  {
    name: '_FixSessionHostTags'
    value: FixSessionHostTags
  }
  {
    name: '_HostPoolResourceGroupName'
    value: HostPoolResourceGroupName
  }
  {
    name: '_SessionHostResourceGroupName'
    value: SessionHostResourceGroupName
  }
  {
    name: '_HostPoolName'
    value: HostPoolName
  }
  {
    name: '_SHRDeploymentPrefix'
    value: SHRDeploymentPrefix
  }
  {
    name: '_SessionHostNamePrefix'
    value: SessionHostNamePrefix
  }
  {
    name: '_SubscriptionId'
    value: SubscriptionId
  }
  {
    name: '_SessionHostTemplate'
    value: SessionHostTemplate
  }
  {
    name: '_SessionHostParameters'
    value: SessionHostParameters
  }
  {
    name: '_ADOrganizationalUnitPath'
    value: ADOrganizationalUnitPath
  }
  {
    name: '_SubnetId'
    value: SubnetId
  }
  {
    name: '_SessionHostInstanceNumberPadding'
    value: SessionHostInstanceNumberPadding
  }
  {
    name: '_ManagedSessionHostMinSuffix'
    value: ManagedSessionHostMinSuffix
  }
  {
    name: '_TargetSessionHostCount'
    value: TargetSessionHostCount
  }
  {
    name: '_Tag_IncludeInAutomation'
    value: TagIncludeInAutomation
  }
  {
    name: '_Tag_DeployTimestamp'
    value: TagDeployTimestamp
  }
  {
    name: '_Tag_PendingDrainTimestamp'
    value: TagPendingDrainTimestamp
  }
  {
    name: '_Tag_ScalingPlanExclusionTag'
    value: TagScalingPlanExclusionTag
  }
  {
    name: '_TargetVMAgeDays'
    value: TargetVMAgeDays
  }
  {
    name: '_DrainGracePeriodHours'
    value: DrainGracePeriodHours
  }
  {
    name: '_StorageAccountName'
    value: StorageAccountName
  }
  {
    name: '_WorkspaceID'
    value: logAnalyticsWorkspace.properties.customerId
  }
  {
    name: '_WorkspaceKey'
    value: logAnalyticsWorkspace.listkeys().primarySharedKey
  }
  {
    name: '_ReplaceSessionHostOnNewImageVersion'
    value: ReplaceSessionHostOnNewImageVersion
  }
  {
    name: '_ReplaceSessionHostOnNewImageVersionDelayDays'
    value: ReplaceSessionHostOnNewImageVersionDelayDays
  }
]

var varAppServicePlanName = '${FunctionAppName}-asp'
var varDeploymentContainerName = 'function-releases'
//-------//

//------ Resources ------//

// Deploy Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-05-01' = {
  name: StorageAccountName
  location: Location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    // TODO: Discuss securing the storage account (firewall)
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2022-09-01' = {
  name: '${storageAccount.name}/default/${varDeploymentContainerName}'
}

// Deploy Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: LogAnalyticsWorkspaceName
  location: Location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Deploy App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: varAppServicePlanName
  location: Location
  kind: 'functionapp,linux'
  sku: {
    name: AppPlanName
    tier: AppPlanTier
  }
  properties: {
    reserved: true
  }
}

// Deploy App Insights for App Service Plan
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: varAppServicePlanName
  location: Location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

// Create ReplaceSessionHost function with Managed System Identity (MSI)
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: FunctionAppName
  location: Location
  kind: 'functionApp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    httpsOnly: true
    serverFarmId: appServicePlan.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}/${varDeploymentContainerName}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 1
      }
      runtime: {
        name: 'powershell'
        version: '7.4'
      }
    }
    siteConfig: {
      use32BitWorkerProcess: false
      appSettings: varFunctionAppSettings
      ftpsState: 'Disabled'
    }
  }
}

resource functionAppDeployFromUrl 'Microsoft.Web/sites/extensions@2023-01-01' = {
  name: '${FunctionAppName}/onedeploy'
  properties: {
    packageUri: FunctionAppZipUrl
    type: 'zip'
  }
  dependsOn: [
    functionApp
  ]
}
//------//

module RBACFunctionApphasDesktopVirtualizationVirtualMachineContributor 'modules/RBACRoleAssignment.bicep' = {
  name: 'RBACFunctionApphasDesktopVirtualizationVirtualMachineContributor'
  params: {
    PrinicpalId: functionApp.identity.principalId
    RoleDefinitionId: 'a959dbd1-f747-45e3-8ba6-dd80f235f97c' // Desktop Virtualization Virtual Machine Contributor
    Scope: resourceGroup().id
  }
}
module RBACFunctionApphasReaderOnTemplateSpec 'modules/RBACRoleAssignment.bicep' = if (startsWith(SessionHostTemplate, '/subscriptions/')){
  name: 'RBACFunctionApphasReaderOnTemplateSpec'
  params: {
    PrinicpalId: functionApp.identity.principalId
    RoleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    Scope: SessionHostTemplate
  }
}
