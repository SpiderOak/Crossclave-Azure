#######################################################################################
# Script that renews a Let's Encrypt certificate for an Azure Application Gateway
# Pre-requirements:
#      - Have a storage account in which the folder path has been created: 
#        '/.well-known/acme-challenge/', to put here the Let's Encrypt DNS check files
#
#      - Add "Path-based" rule in the Application Gateway with this configuration: 
#           - Path: '/.well-known/acme-challenge/*'
#           - Check the configure redirection option
#           - Choose redirection type: permanent
#           - Choose redirection target: External site
#           - Target URL: <Blob public path of the previously created storage account>
#                - Example: 'https://test.blob.core.windows.net/public'
#      - For execution on Azure Automation: Import 'AzureRM.profile', 'AzureRM.Network' 
#        and 'ACMESharp' modules in Azure
#
#      UPDATE 2019-11-27
#      - Due to deprecation of ACMEv1, a new script is required to use ACMEv2.
#        The module to use is called ACME-PS.
#
#      UPDATE 2020-09-03
#      - Migrated to Az modules.
#        Following modules are needed now: Az.Accounts, Az.Network, Az.Storage
#
#
#      SPIDEROAK UPDATE 2020-10-21
#      - Support multiple domains
#      - Apply to multiple application gateways
#      - Test if cert needs renewed before running
#
#######################################################################################

Param(
    [string]$domainsJson,
    [string]$EmailAddress,
    [string]$STResourceGroupName,
    [string]$storageName,
    [string]$storageContainerName,
    [string]$AGResourceGroupName,
    [string]$AGNamesJson,
    [string]$AGOldCertName
)

# Ensures that no login info is saved after the runbook is done
Disable-AzContextAutosave

$renewDays = 14
$domains = $domainsJson | ConvertFrom-Json
$AGNames = $AGNamesJson | ConvertFrom-Json
[String[]] $blobNames = $NULL

# Check the SSL Certificate
$tempurl = "https://" + $domains[0]
$req = [Net.HttpWebRequest]::Create($tempurl)
# Don't die if the certificate had already expired or is a fake cert.
$req.ServerCertificateValidationCallback = { $true }
try {
    $req.GetResponse() | Out-Null
}
# Don't bail on 400 and 500 errors. We just want the certificate.
catch [System.Net.WebException]  {
    if ($null -eq $_.Exception.Response)
    {
        Throw
    }
}
[DateTime]$expiration = New-Object DateTime
[DateTime]::TryParse($req.ServicePoint.Certificate.GetExpirationDateString(), [ref]$expiration)

# If our cert not our dummy "flow" cert or the expiration is in more than $renewDays days, abort this run.
if (($req.ServicePoint.Certificate.Subject -ne "CN=flow") -and ($expiration -gt [DateTime]::Now.AddDays($renewDays))) {
    Write-Output "Certificate for $tempurl is still valid, exiting"
    Break
}

# Log in as the service principal from the Runbook
$connection = Get-AutomationConnection -Name AzureRunAsConnection
Login-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint

# Create a state object and save it to the harddrive
$state = New-ACMEState -Path $env:TEMP
$serviceName = 'LetsEncrypt-Staging'

# Fetch the service directory and save it in the state
Get-ACMEServiceDirectory $state -ServiceName $serviceName -PassThru;

# Get the first anti-replay nonce
New-ACMENonce $state;

# Create an account key. The state will make sure it's stored.
New-ACMEAccountKey $state -PassThru;

# Register the account key with the acme service. The account key will automatically be read from the state
New-ACMEAccount $state -EmailAddresses $EmailAddress -AcceptTOS;

# Load an state object to have service directory and account keys available
$state = Get-ACMEState -Path $env:TEMP;

# It might be neccessary to acquire a new nonce, so we'll just do it for the sake of the example.
New-ACMENonce $state -PassThru;

# Create the order object at the ACME service.
$order = New-ACMEOrder $state -Identifiers $domains;

# Fetch the authorizations for that order
$authZ = Get-ACMEAuthorization -State $state -Order $order;

# Select a challenge to fullfill
$challenges = $authZ | Get-ACMEChallenge -State $state -Type "http-01";

# Inspect the challenge data
$challenges.Data;

# Create the file requested by the challenge
foreach ($challenge in $challenges) {
    $fileName = $env:TMP + '\' + $challenge.Token;
    Set-Content -Path $fileName -Value $challenge.Data.Content -NoNewline;

    $blobName = ".well-known/acme-challenge/" + $challenge.Token
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $STResourceGroupName -Name $storageName
    $ctx = $storageAccount.Context
    Set-AzStorageBlobContent -File $fileName -Container $storageContainerName -Context $ctx -Blob $blobName
    $blobNames += $blobName
}

# Signal the ACME server that the challenge is ready
$challenges | Complete-ACMEChallenge $state;

# Wait a little bit and update the order, until we see the states
while($order.Status -notin ("ready","invalid")) {
    Start-Sleep -Seconds 10;
    $order | Update-ACMEOrder $state -PassThru;
}

# We should have a valid order now and should be able to complete it
# Therefore we need a certificate key
$certKey = New-ACMECertificateKey -Path "$env:TEMP\domains.key.xml";

# Complete the order - this will issue a certificate singing request
Complete-ACMEOrder $state -Order $order -CertificateKey $certKey;

# Now we wait until the ACME service provides the certificate url
while(-not $order.CertificateUrl) {
    Start-Sleep -Seconds 15
    $order | Update-Order $state -PassThru
}

# As soon as the url shows up we can create the PFX
# Random password for PFX
$password = ConvertTo-SecureString -String (-join ((65..90) + (97..122) | Get-Random -Count 12 | % {[char]$_})) -Force -AsPlainText
Export-ACMECertificate $state -Order $order -CertificateKey $certKey -Path "$env:TEMP\domains.pfx" -Password $password;

# Delete blobs used to check DNS
foreach ($blobName in $blobNames) {
    Remove-AzStorageBlob -Container $storageContainerName -Context $ctx -Blob $blobName
}

### RENEW APPLICATION GATEWAY CERTIFICATE ###
foreach ($AGName in $AGNames) {
    $appgw = Get-AzApplicationGateway -ResourceGroupName $AGResourceGroupName -Name $AGName
    Set-AzApplicationGatewaySSLCertificate -Name $AGOldCertName -ApplicationGateway $appgw -CertificateFile "$env:TEMP\domains.pfx" -Password $password
    Set-AzApplicationGateway -ApplicationGateway $appgw
}
