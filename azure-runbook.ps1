[CmdletBinding()]


$ResourceGroupName = $Env:resourceGroupName
$AutomationAccount = $Env:AutomationAccountName
$keyvaultName = $Env:keyVaultName
$RunAsAccountName = "$($AutomationAccount)-runas"
$CertificatSubjectName = "CN=$($RunAsAccountName)"
$AzAppUniqueId = (New-Guid).Guid
$AzAdAppURI = "http://$($AutomationAccount)$($AzAppUniqueId)"



$AzureKeyVaultCertificatePolicy = New-AzKeyVaultCertificatePolicy -SubjectName $CertificatSubjectName -IssuerName "Self" -KeyType "RSA" -KeyUsage "DigitalSignature" -ValidityInMonths 120 -RenewAtNumberOfDaysBeforeExpiry 20 -KeyNotExportable:$False -ReuseKeyOnRenewal:$False

Add-AzKeyVaultCertificate -VaultName $keyvaultName -Name $RunAsAccountName -CertificatePolicy $AzureKeyVaultCertificatePolicy | out-null

do {
    start-sleep -Seconds 20
} until ((Get-AzKeyVaultCertificateOperation -Name $RunAsAccountName -vaultName $keyvaultName).Status -eq "completed")



$PfxPassword = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 48| foreach-object {[char]$_})  
$PfxFilePath = join-path -Path (get-location).path -ChildPath "cert.pfx"

start-sleep 30

$AzKeyVaultCertificatSecret = Get-AzKeyVaultSecret -VaultName $keyvaultName -Name $RunAsAccountName
$AzKeyVaultCertifocatSecretPlain = $AzKeyVaultCertificatSecret.SecretValue | ConvertFrom-SecureString -AsPlainText
$AzKeyVaultCertificatSecretBytes = [System.Convert]::FromBase64String($AzKeyVaultCertifocatSecretPlain)

$certCollection = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$certCollection.Import($AzKeyVaultCertificatSecretBytes,$null,[System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)

$protectedCertificateBytes = $certCollection.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12, $PfxPassword)
[System.IO.File]::WriteAllBytes($PfxFilePath, $protectedCertificateBytes)
Write-Output "New-AzADApplication -DisplayName $RunAsAccountName -HomePage http://$($RunAsAccountName) -IdentifierUris $AzAdAppURI"
$AzADApplicationRegistration = New-AzADApplication -DisplayName $RunAsAccountName -HomePage "http://$($RunAsAccountName)" -IdentifierUris $AzAdAppURI

# Add debugging
Write-Output $AzADApplicationRegistration

$AzKeyVaultCertificatStringValue = [System.Convert]::ToBase64String($certCollection.GetRawCertData())
$AzADApplicationCredential = New-AzADAppCredential -ApplicationId $AzADApplicationRegistration.ApplicationId -CertValue $AzKeyVaultCertificatStringValue -StartDate $certCollection.NotBefore -EndDate $certCollection.NotAfter


$AzADServicePrincipal = New-AzADServicePrincipal -ApplicationId $AzADApplicationRegistration.ApplicationId -SkipAssignment


$PfxPassword = ConvertTo-SecureString $PfxPassword -AsPlainText -Force
New-AzAutomationCertificate -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccount -Path $PfxFilePath -Name "AzureRunAsCertificate" -Password $PfxPassword -Exportable:$Exportable 



$ConnectionFieldData = @{
        "ApplicationId" = $AzADApplicationRegistration.ApplicationId
        "TenantId" = (Get-AzContext).Tenant.ID
        "CertificateThumbprint" = $certCollection.Thumbprint
        "SubscriptionId" = (Get-AzContext).Subscription.ID
    }

New-AzAutomationConnection -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccount -Name "AzureRunAsConnection" -ConnectionTypeName "AzureServicePrincipal" -ConnectionFieldValues $ConnectionFieldData

# Let's Encrypt after doing automation

$letsencryptParameters = @{'domainsJson'=$Env:domainsJson; 'emailAddress'=$Env:emailAddress; 'STResourceGroupName'=$Env:resourceGroupName; 'storageName'=$Env:storageName; 'storageContainerName'=$Env:storageContainerName; 'AGResourceGroupName'=$Env:resourceGroupName; 'AGNamesJson'=$Env:AGNamesJson; 'AGOldCertName'=$Env:AGOldCertName;}
Start-AzAutomationRunbook -AutomationAccountName $Env:AutomationAccountName -Name $Env:runbookName -ResourceGroupName $Env:resourceGroupName -MaxWaitSeconds 1000 -Wait -Parameters $letsencryptParameters
