#First define your environment variables
$TenantID="91ceb514-5ead-468c-a6ae-048e103d57f0"
$subscriptionID="ed6a63cc-c71c-4bfa-8bf7-c1510b559c72"
$DisplayNameOfMSI="AADDS-Client03"
$ResourceGroup="AADDS"
$VMResourceGroup="AADDS"
$VM="AADDS-Client03"

#If your User Assigned Identity doesnt exist yet, create it now
New-AzUserAssignedIdentity -ResourceGroupName $ResourceGroup -Name $DisplayNameOfMSI

#Now use the AzureAD Powershell module to grant the role
Connect-AzureAD -TenantId $TenantID #Connected as GA
$MSI = (Get-AzureADServicePrincipal -Filter "displayName eq '$DisplayNameOfMSI'")
Start-Sleep -Seconds 10
$GraphAppId = "00000002-0000-0000-c000-000000000000" #Windows Azure Active Directory aka graph.windows.net, this is legacy AAD graph and slated to be deprecated
$MSGraphAppId = "00000003-0000-0000-c000-000000000000" #Microsoft Graph aka graph.microsoft.com, this is the one you want more than likely.
$GraphServicePrincipal = Get-AzureADServicePrincipal -Filter "appId eq '$MSGraphAppId'"
$PermissionName = "Directory.Read.All"
$AppRole = $GraphServicePrincipal.AppRoles | Where-Object {$_.Value -eq $PermissionName -and $_.AllowedMemberTypes -contains "Application"}
New-AzureAdServiceAppRoleAssignment -ObjectId $MSI.ObjectId -PrincipalId $MSI.ObjectId -ResourceId $GraphServicePrincipal.ObjectId -Id $AppRole.Id  

#NOTE: The above assignment may indicate bad request or indicate failure but it has been noted that the permission assignment still succeeds and you can verify with the following command
Get-AzureADServiceAppRoleAssignment -ObjectId $GraphServicePrincipal.ObjectId | Where-Object {$_.PrincipalDisplayName -eq $DisplayNameOfMSI} | fl