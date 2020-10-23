param(
    [string] $AutomationAccountName,
    [string] $resourceGroupName,
    [string] $storageName,
    [string] $domainsJson,
    [string] $emailAddress,
    [string] $storageContainerName,
    [string] $AGNamesJson,
    [string] $AGOldCertName
)
# Json variable for domains to be passed into Parameters. Or should this logic be done on the ARM side?
# Json variable for Gateways to pass in Parameters. Or should this logic be done on the ARM side?

# Create and set runbook job schedule
$letsencryptParameters = @{"domainsJson"=$domainsJson; "emailAddress"=$emailAddress; "resourceGroupName"=$resourceGroupName; "storageName"=$storageName; "storageContainerName"=$storageContainerName; "AGResourceGroupName"=$resourceGroupName; "AGNamesJson"=$AGNamesJson; "AGOldCertName"=$AGOldCertName;};
$letsencryptRunbookName ="letsencryptrunbook"
$letsencryptRunbookSchedule ="letsencryptrunbookschdule"
$TimeZone = ([System.TimeZoneInfo]::Local).Id

# Start Runbook 
Start-AzAutomationRunbook -AutomationAccountName $AutomationAccountName -Name letsencryptRunbook -ResourceGroupName $resourceGroupName -MaxWaitSeconds 1000 -Wait -Parameters $letsencryptParameters

# Create and set runbook job schedule. This is not tested
New-AzAutomationSchedule -AutomationAccountName $AutomationAccountName -Name $letsencryptRunbookName -MonthInterval "1" -OneTime -ResourceGroupName $resourceGroupName -TimeZone $TimeZone
Register-AzAutomationScheduledRunbook -AutomationAccountName $AutomationAccountName -ResourceGroupName $resourceGroupName  -RunbookName $letsencryptRunbookName  -ScheduleName $letsencryptRunbookName

<#
ARM template with scriptcontent, can also use github uri if needed.

Does the runbook script parameters require just the names of resources or the full uri? In the arguments below its just using the name of the resources and no the full resourceid() uri such as:
resourceId('Microsoft.Storage/blobServices', variables('letsencryptContainerName'))

"properties": {
    "forceUpdateTag": "1",
    "azPowerShellVersion": "4.6",
    "arguments": "[format(' -AutomationAccountName {0} -resourceGroupName {1} -storageName {2} -domainsJson {3} -emailAddress {4} -storageContainerName {5} -AGNamesJson {6} -AGOldCertName {7}', variables('automationAccountName'), resourceGroup().name, parameters('storageAccountName'), 'test.spideroak-domain.com', 'admins@spideroak.com', 'variables('letsEncryptContainerName'), variables('applicationGatewayFlowBlockName'), 'flow')]",
    "scriptContent": "
            param(
                [string] $AutomationAccountName,
                [string] $resourceGroupName,
                [string] $storageName,
                [string] $domainsJson,
                [string] $emailAddress,
                [string] $storageContainerName,
                [string] $AGNamesJson,
                [string] $AGOldCertName
            )
            $letsencryptParameters = @{'domainsJson'=$domainsJson; 'emailAddress'=$emailAddress; 'resourceGroupName'=$resourceGroupName; 'storageName'=$storageName; 'storageContainerName'=$storageContainerName; 'AGNamesJson'=$AGNamesJson; 'AGOldCertName'=$AGOldCertName;}
            Start-AzAutomationRunbook -AutomationAccountName $AutomationAccountName -Name letsencryptRunbook -ResourceGroupName $resourceGroupname -MaxWaitSeconds 1000 -Wait -Parameters $letsencryptParameters
            ",
#>