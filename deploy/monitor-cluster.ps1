<#
 .SYNOPSIS
  Shows the cluster dashboard.

 .DESCRIPTION
  If needed deploys the dashboard to the cluster and opens a browser
  to the proxied dashboard page.  The script requires AzureCLI (AZ)
  and Kubectl to be installed.

 .PARAMETER ResourceGroup
  The Name of the resource group

 .PARAMETER Cluster
  The optional cluster name if there are more than one.
   
 .PARAMETER Context
  An existing Azure connectivity context to use instead of connecting.
  If provided, overrides the provided environment name or tenant id.
#>
param(
    [Parameter(Mandatory = $true)] [string] $ResourceGroup,
    [string] $Cluster = $null
)

# -------------------------------------------------------------------------------

$script:ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------------
# Log into azure
az login --identity

# --------------------------------------------------------------------------------------

if ([string]::IsNullOrEmpty($script:Cluster)) {
    aksCluster=$(az aks list -g $resourcegroup \
        --query [0].name -o tsv | tr -d '\r')
    if ([string]::IsNullOrEmpty($script:Cluster)) {
        Write-Warning "ERROR: Unable to determine aks cluster name."
        Write-Warning "ERROR: Ensure one was created in resource group $resourcegroup."
        throw "Unable to determine cluster name"
    }
}

# Go to home.

kubectl version --client > /dev/null 2>&1
if (!) {
    Write-Warning "Install kubectl..."
     az aks install-cli ; then 
    if (Error) {
        throw "ERROR: Failed to install kubectl."
    }
}

# Get AKS credentials
az aks get-credentials --resource-group $resourcegroup --name $script:Cluster--admin
            
# install dashboard into the cluster
$tag="v2.1.0" # v2.0.0, master, etc.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/$tag/aio/deploy/recommended.yaml
# start proxy and open browser
$job = Start-Job { kubectl proxy }
$url="http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
Start-Process -FilePath $url
Receive-Job -Job $Job -Wait -AutoRemoveJob

# --------------------------------------------------------------------------------------
