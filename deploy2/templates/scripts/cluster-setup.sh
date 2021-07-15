#!/bin/bash

# -------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --namespace, -n            Namespace to use to install into.
    --resourcegroup, -g        Resource group in which the cluster resides.
    --subscription, -s         Changes default subscription to this one.
    --help                     Shows this help.
'
    exit 1
}

# must be run as sudo
if [[ -z "$AZ_SCRIPTS_OUTPUT_PATH" ]] && [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 2
fi

CWD=$(pwd)
resourcegroup=
subscription=
namespace=
aksCluster=
roleName=
loadBalancerIp=
publicIpDnsLabel=
helmRepoUrl=
helmChartName=
helmChartVersion=
imagesTag=
dockerServer=
dockerUser=
userEmail=
userId=
keyVaultUri=
managedIdentityId=
managedIdentityName=
managedIdentityClientId=
managedIdentityTenantId=
servicesHostname=
servicesAppId=
engineeringTool=true
telemetryProcessor=true

#servicesAppSecret= # allow passing from environment
#dockerPassword= # allow passing from environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace|-n)             namespace="$2"; shift ;;
        --resourcegroup|-g)         resourcegroup="$2"; shift ;;
        --subscription|-s)          subscription="$2"; shift ;;
        --help)                     usage ;;
        # automation...
        --aksCluster)               aksCluster="$2"; shift ;;
        --noEngineeringTool)        engineeringTool=false ;;
        --noTelemetryProcessor)     telemetryProcessor=false ;;
        --email)                    userEmail="$2"; shift ;;
        --user)                     userId="$2"; shift ;;
        --loadBalancerIp)           loadBalancerIp="$2"; shift ;;
        --publicIpDnsLabel)         publicIpDnsLabel="$2"; shift ;;
        --helmRepoUrl)              helmRepoUrl="$2"; shift ;;
        --helmChartName)            helmChartName="$2"; shift ;;
        --helmChartVersion)         helmChartVersion="$2"; shift ;;
        --imagesTag)                imagesTag="$2"; shift ;;
        --dockerServer)             dockerServer="$2"; shift ;;
        --dockerUser)               dockerUser="$2"; shift ;;
        --dockerPassword)           dockerPassword="$2"; shift ;;
        --managedIdentityId)        managedIdentityId="$2"; shift ;;
        --managedIdentityName)      managedIdentityName="$2"; shift ;;
        --managedIdentityClientId)  managedIdentityClientId="$2"; shift ;;
        --tenant)                   managedIdentityTenantId="$2"; shift ;;
        --keyVaultUri)              keyVaultUri="$2"; shift ;;
        --servicesHostname)         servicesHostname="$2"; shift ;;
        --role)                     roleName="$2"; shift ;;
        --servicesAppId)            servicesAppId="$2"; shift ;;
        --servicesAppSecret)        servicesAppSecret="$2"; shift ;;
        *)                          usage ;;
    esac
    shift
done

# -------------------------------------------------------------------------

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    if ! az login --identity ; then 
        echo "ERROR: Failed to log in using managed identity."
        exit 1
    fi
elif ! az account show > /dev/null 2>&1 ; then
    if ! az login ; then 
        echo "ERROR: Failed to log in."
        exit 1
    fi
fi

if [[ -z "$resourcegroup" ]]; then
    echo "ERROR: Missing resource group name.  Use --resourcegroup parameter."
    usage
fi
if [[ -z "$namespace" ]]; then
    namespace=$resourcegroup
    echo "WARNING: Using namespace $namespace."
fi
if [[ -n "$subscription" ]]; then
    az account set -s $subscription
fi
if [[ -z "$aksCluster" ]]; then
    aksCluster=$(az aks list -g $resourcegroup \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$aksCluster" ]]; then
        echo "ERROR: Missing aks cluster name."
        echo "ERROR: Ensure one was created in resource group $resourcegroup."
        exit 1
    fi
fi
if [[ -z "$keyVaultUri" ]]; then
    keyVaultUri=$(az keyvault list  -g $resourcegroup \
        --query [0].properties.vaultUri -o tsv | tr -d '\r')
    if [[ -z "$keyVaultUri" ]]; then
        echo "ERROR: Unable to retrieve platform keyvault uri."
        echo "ERROR: Ensure it was created in '$resourcegroup' group."
        exit 1
    fi
fi
if [[ -z "$managedIdentityId" ]] ; then
    managedIdentityId=$(az identity list -g $resourcegroup \
        --query "[?starts_with(name, 'services-')].id" -o tsv | tr -d '\r')
    if [[ -z "$managedIdentityId" ]] ; then
        echo "ERROR: Unable to find platform msi in '$resourcegroup' group."
        echo "ERROR: Ensure it was created before running this script."
        exit 1
    fi
fi
if [[ -z "$managedIdentityClientId" ]] || \
   [[ -z "$managedIdentityTenantId" ]] ; then
    IFS=$'\n'; msi=($(az identity show --ids $managedIdentityId \
        --query "[name, clientId, tenantId, principalId]" \
        -o tsv | tr -d '\r')); unset IFS;

    managedIdentityName=${msi[0]}
    managedIdentityClientId=${msi[1]}
    managedIdentityTenantId=${msi[2]}
    if [[ -z "$managedIdentityClientId" ]]; then
        echo "ERROR: Unable to get properties from msi $msiId."
        exit 1
    fi
fi

# Get public ip information if not provided 
if [[ -z "$loadBalancerIp" ]] || \
   [[ -z "$publicIpDnsLabel" ]] || \
   [[ -z "$servicesHostname" ]] ; then
    # public ip domain label should be namespace name
    publicIpId=$(az network public-ip list \
        --query "[?dnsSettings.domainNameLabel=='$namespace'].id" \
        -o tsv | tr -d '\r')
    if [[ -z "$publicIpId" ]] ; then
        # If not then public ip name starts with resource group name
        publicIpId=$(az network public-ip list \
            --query "[?starts_with(name, '$resourcegroup')].id" \
            -o tsv | tr -d '\r')
    fi
    if [[ -z "$publicIpId" ]] ; then
        echo "Unable to find public ip for '$namespace' label."
        echo "Ensure it exists in the node resource group of the cluster."
        exit 1
    fi
    IFS=$'\n'; publicIp=($(az network public-ip show --ids $publicIpId \
        --query "[dnsSettings.fqdn, ipAddress, dnsSettings.domainNameLabel]" \
        -o tsv | tr -d '\r')); unset IFS;

    servicesHostname=${publicIp[0]}
    loadBalancerIp=${publicIp[1]}
    publicIpDnsLabel=${publicIp[2]}
    if [[ -z "$servicesHostname" ]] ; then
        echo "ERROR: Unable to get public ip properties from $publicIpId."
        exit 1
    fi
fi

if [[ -z "$userEmail" ]] || \
   [[ -z "$userId" ]] ; then
    IFS=$'\n'; user=($(az ad signed-in-user show \
        --query "[objectId, mail]" -o tsv 2>/dev/null \
            | tr -d '\r')); unset IFS;
    if [[ -z "$userId" ]]; then
        userId=${user[0]}
    fi
    if [[ -z "$userEmail" ]]; then
        userEmail=${user[1]}
    fi
fi

if [[ -n "$servicesAppId" ]]; then
    if [[ -z "$servicesAppSecret" ]]; then
        echo "ERROR: Missing service app secret. "
        echo "ERROR: Must be provided if app id is provided"
        exit 1
    fi
fi

if [[ -n "$helmRepoUrl" ]]; then
    if [[ -z "$helmChartName" ]]; then
        helmChartName="azure-industrial-iot"
    fi
    if [[ -z "$imagesTag" ]]; then
        imagesTag="2.8"
    fi
    if [[ -z "$helmChartVersion" ]]; then
        helmChartVersion="0.4.0"
    fi
    if [[ -z "$dockerServer" ]]; then
        dockerServer="mcr.microsoft.com"
    fi
else
    if [[ -z "$helmChartName" ]]; then
        helmChartName="iot/azure-industrial-iot"
    fi
    if [[ -z "$dockerServer" ]]; then
        # See if there is a registry in the resource group 
        IFS=$'\n'; registry=($(az acr list -g $resourcegroup \
            --query "[[0].name,[0].loginServer]" \
            -o tsv | tr -d '\r')); unset IFS;
        dockerServer=${registry[1]}
        # pick the first if there is and get credentials.
        if [[ -n "$dockerServer" ]] ; then
            IFS=$'\n'; creds=($(az acr credential show \
                --name ${registry[0]} -g $resourcegroup \
                --query "[username, passwords[0].value]" \
                -o tsv | tr -d '\r')); unset IFS;
            dockerUser=${creds[0]}
            dockerPassword=${creds[1]}
            if [[ -z "$imagesTag" ]]; then
                imagesTag="latest"
            fi
            echo "Using $imagesTag images from $dockerServer."
        else 
            # if there is not, use default registry
            if [[ -z "$imagesTag" ]]; then
                imagesTag="2.8"
            fi
            dockerServer="mcr.microsoft.com"
        fi
    fi
    if [[ -z "$helmChartVersion" ]]; then
        helmChartVersion=$imagesTag
    fi
fi

if [[ -z "$roleName" ]]; then
    roleName="AzureKubernetesServiceClusterUserRole"
fi

echo ""
echo "  resourcegroup=$resourcegroup"
echo "  namespace=$namespace"
echo "  engineeringTool=$engineeringTool"
echo "  telemetryProcessor=$telemetryProcessor"
echo "  aksCluster=$aksCluster"
echo "  roleName=$roleName"
echo "  loadBalancerIp=$loadBalancerIp"
echo "  publicIpDnsLabel=$publicIpDnsLabel"
echo "  helmRepoUrl=$helmRepoUrl"
echo "  helmChartVersion=$helmChartVersion"
echo "  imagesTag=$imagesTag"
echo "  dockerServer=$dockerServer"
echo "  dockerUser=$dockerUser"
if [[ -n "$dockerPassword" ]] ; then 
echo "  dockerPassword=********"
else
echo "  dockerPassword="
fi
echo "  keyVaultUri=$keyVaultUri"
echo "  managedIdentityId=$managedIdentityId"
echo "  managedIdentityName=$managedIdentityName"
echo "  managedIdentityClientId=$managedIdentityClientId"
echo "  managedIdentityTenantId=$managedIdentityTenantId"
echo "  servicesHostname=$servicesHostname"
echo "  servicesAppId=$servicesAppId"
if [[ -n "$servicesAppSecret" ]] ; then 
echo "  servicesAppSecret=********"
else
echo "  servicesAppSecret="
fi
echo "  userId=$userId"
echo "  userEmail=$userEmail"
echo ""

# -------------------------------------------------------------------------
# Add user as member to admin group to get access
if [[ -z "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    if [[ -n "$userId" ]] ; then
        source $CWD/group-setup.sh \
--description "Administrator group for $aksCluster in resource group $resourcegroup" \
            --display "$aksCluster Administrators" \
            --member "$userId" \
            --name "$aksCluster" 
    fi
fi
# Go to home.
cd ~

if ! kubectl version --client=true > /dev/null 2>&1 ; then
    echo "Install kubectl..."
    az aks install-cli --install-location /usr/local/bin/kubectl > /dev/null 2>&1
    if ! kubectl version --client=true > /dev/null 2>&1 ; then 
        echo "ERROR: Failed to install kubectl."
        exit 1
    fi
fi
if ! helm version > /dev/null 2>&1 ; then
    echo "Install Helm..."
    az acr helm install-cli --client-version "3.3.4" -y > /dev/null 2>&1
    if ! helm version > /dev/null 2>&1 ; then
        echo "ERROR: Failed to install helm. "
        exit 1
    fi
fi
echo "Prerequisites installed - getting credentials for the cluster..."

# Get AKS credentials
if [[ "$roleName" -eq "AzureKubernetesServiceClusterAdminRole" ]]; then
    az aks get-credentials --resource-group $resourcegroup \
        --name $aksCluster --admin
else
    az aks get-credentials --resource-group $resourcegroup \
        --name $aksCluster
fi
echo "Credentials for AKS cluster acquired."

# -------------------------------------------------------------------------

# Add Helm repos
if ! helm repo add jetstack \
    https://charts.jetstack.io 
then
    echo "ERROR: Failed to add jetstack repo."
    exit 1
fi
if ! helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx 
then
    echo "ERROR: Failed to add ingress-nginx repo."
    exit 1
fi
if ! helm repo add aad-pod-identity \
    https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts 
then
    echo "ERROR: Failed to add aad-pod-identity repo."
    exit 1
fi
# see if the app is in oci helm or traditional chart repo - should be in oci
if [[ -z "$helmRepoUrl" ]] ; then
    export HELM_EXPERIMENTAL_OCI=1
    # docker server is the oci registry from where to consume the helm chart
    # the repo is the path and name of the chart
    chart="$dockerServer/$helmChartName:$helmChartVersion"
    helm chart remove $chart > /dev/null 2>&1 && echo "No charts to remove."
    # lpg into the server
    if [[ -n "$dockerUser" ]] && [[ -n "$dockerPassword" ]] ; then
        echo $dockerPassword | helm registry login $dockerServer \
            -u "$dockerUser" --password-stdin
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to log into registry using user and password"
            exit 1
        fi
    fi
    echo "Downloading $chart locally..."
    if ! helm chart pull $chart ; then
        echo "ERROR: Failed to download chart $chart."
        exit 1
    fi
    helm chart export $chart --destination ./aiiot
    helmChartLocation="./aiiot/$helmChartName"
    echo "Downloaded Helm chart $chart will be installed..."
else
    # add the repo
    echo "Configure Helm chart repository configured..."
    if ! helm repo add aiiot $helmRepoUrl ; then
        echo "ERROR: Failed to add azure-industrial-iot repo."
        exit 1
    fi
    helmChartLocation="aiiot/$helmChartName --version $helmChartVersion"
    echo "Helm chart from $helmRepoUrl/$helmChartName will be installed..."
fi
helm repo update

# -------------------------------------------------------------------------
# Install omsagent configuration if not already installed.
echo ""
echo "Configure Azure monitor..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: container-azm-ms-agentconfig
  namespace: kube-system
data:
  schema-version:
    v1
  config-version:
    ver1
  log-data-collection-settings: |-
    [log_collection_settings]
       [log_collection_settings.stdout]
          enabled = true
          exclude_namespaces = ["kube-system"]
       [log_collection_settings.stderr]
          enabled = true
          exclude_namespaces = ["kube-system"]
       [log_collection_settings.env_var]
          enabled = true
       [log_collection_settings.enrich_container_logs]
          enabled = false
  prometheus-data-collection-settings: |-
    [prometheus_data_collection_settings.cluster]
        interval = "10s"
        monitor_kubernetes_pods = true
    [prometheus_data_collection_settings.node]
        interval = "1m"
EOF

if [ $? -eq 0 ]; then
    echo "Azure monitor agent configuration updated."
else
    echo "ERROR: Failed to update Azure Monitor agent configuration."
fi

# Install jetstack/cert-manager Helm chart if not already installed
echo ""
releases=($(helm ls -f cert-manager -A))
ns=${releases[9]}
if [[ -z "$ns" ]]; then
    ns=cert-manager
    echo "Installing jetstack/cert-manager Helm chart into namespace $ns..."
    if ! kubectl create namespace $ns > /dev/null 2>&1 ; then
        echo "Namespace $ns already exists..."
    fi
    helm install --atomic cert-manager jetstack/cert-manager \
        --version v1.1.0 --timeout 30m0s --namespace $ns \
        --set installCRDs=true \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Installed jetstack/cert-manager Helm chart in namespace $ns."
    else
        echo "ERROR: Failed to install jetstack/cert-manager Helm chart in namespace $ns."
        if ! kubectl get crds issuers.cert-manager.io > /dev/null 2>&1; then
            exit 1
        fi
        echo "WARNING: Found issuer crd, trying without installation ..."
    fi
else
    helm upgrade --atomic cert-manager jetstack/cert-manager \
        --version v1.1.0 --timeout 30m0s --reuse-values --namespace $ns \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Upgraded jetstack/cert-manager cert-manager release in namespace $ns."
    else
        echo "ERROR: Failed to upgrade cert-manager release in namespace $ns."
        echo "WARNING: Trying to continue without upgrade..."
        # exit 1
    fi
fi

# install per pod identity if it is not yet installed
echo ""
releases=($(helm ls -f aad-pod-identity -A))
ns=${releases[9]}
if [[ -z "$ns" ]]; then
    ns=aad-pod-identity
    echo "Installing aad-pod-identity Helm chart into in namespace $ns..."
    if ! kubectl create namespace $ns > /dev/null 2>&1 ; then
        echo "Namespace $ns already exists..."
    fi
    helm install --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
        --version 3.0.3 --timeout 30m0s --set forceNamespaced="true" \
        > /dev/null 2>&1
        # -set nmi.allowNetworkPluginKubenet=true
    if [ $? -eq 0 ]; then
        echo "Installed aad-pod-identity Helm chart in namespace $ns."
    else
        echo "ERROR: Failed to install aad-pod-identity Helm chart in namespace $ns."
        if ! kubectl get crds azureidentities.aadpodidentity.k8s.io > /dev/null 2>&1; then
            exit 1
        fi
        echo "WARNING: Found azureidentities crd, trying without installation ..."
    fi
else
    helm upgrade --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
        --version 3.0.3 --timeout 30m0s --reuse-values --namespace $ns \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
echo "Upgraded aad-pod-identity/aad-pod-identity aad-pod-identity release in namespace $ns."
    else
        echo "ERROR: Failed to upgrade aad-pod-identity release in namespace $ns."
        echo "WARNING: Trying to continue without upgrade..."
        # exit 1
    fi
fi

# -------------------------------------------------------------------------
# Install services into cluster 
echo "Installing services into namespace $namespace of cluster $aksCluster..."

# Create namespace to deploy into
if ! kubectl create namespace $namespace > /dev/null 2>&1 ; then
    echo "Namespace $namespace already exists..."
fi

# Create or update identity for the supplied managed service identity and
# a binding to the scheduled pods.
echo "Creating or updating managed identity $managedIdentityName..."

cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: $managedIdentityName
  namespace: $namespace
  annotations:
    aadpodidentity.k8s.io/Behavior: namespaced
spec:
  type: 0
  resourceID: $managedIdentityId
  clientID: $managedIdentityClientId
---
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: $managedIdentityName-binding
  namespace: $namespace
spec:
  azureIdentity: $managedIdentityName
  selector: $managedIdentityName
EOF

if [ $? -eq 0 ]; then
    echo "Per pod identity $managedIdentityName created or updated."
else
    echo "ERROR: Failed to create or update identity $managedIdentityName."
    exit 1
fi

# https://kubernetes.github.io/ingress-nginx/user-guide/multiple-ingress/#multiple-ingress-nginx-controllers
# Install ingress-nginx/ingress-nginx Helm chart into the namespace giving it a class name that applies 
# to the public ip.
echo ""
controller_name=${publicIpDnsLabel:0:25}
releases=($(helm ls -f $controller_name -A -q))
if [[ -z "$releases" ]]; then
    echo "Installing nginx-ingress $controller_name with class nginx-$namespace for $loadBalancerIp into $namespace..."
    helm install --atomic $controller_name ingress-nginx/ingress-nginx \
        --namespace $namespace --version 3.34.0 --timeout 30m0s \
        --set controller.ingressClass=nginx-$namespace \
        --set controller.replicaCount=2 \
        --set controller.podLabels.aadpodidbinding=$managedIdentityName \
        --set controller.nodeSelector."beta\.kubernetes\.io\/os"=linux \
        --set controller.service.loadBalancerIP=$loadBalancerIp \
        --set controller.service.annotations."service\.beta\.kubernetes\.io\/azure-dns-label-name"=$publicIpDnsLabel \
        --set controller.config.compute-full-forward-for='"true"' \
        --set controller.config.use-forward-headers='"true"' \
        --set controller.config.proxy-buffer-size='"32k"' \
        --set controller.config.client-header-buffer-size='"32k"' \
        --set controller.metrics.enabled=true \
        --set defaultBackend.enabled=true \
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io\/os"=linux \
        > /dev/null 2>&1
    # --set controller.service.annotations."service\.beta\.kubernetes\.io\/azure-load-balancer-internal"=true \
    if [ $? -eq 0 ]; then
        echo "Completed installation of nginx-ingress controller $controller_name with class nginx-$namespace."
    else
        echo "ERROR: Failed to install Ingress controller $controller_name into $namespace."
        exit 1
    fi
else
    releases=($(helm ls -f $controller_name -A -o table))
    ns=${releases[9]} # the namespace of the first line in the table
    if [[ "$ns" != "$namespace" ]] ; then 
        echo "Updating release $controller_name release in $ns with ingress class nginx-$namespace."
        helm upgrade--atomic $controller_name ingress-nginx/ingress-nginx \
            --namespace $ns --version 3.34.0 --timeout 30m0s --reuse-values \
            --set controller.ingressClass=nginx-$namespace \
            > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "Upgraded $controller_name to ingress class nginx-$namespace."
            echo "WARNING: $ns will not work anymore until updated back."
        else
            echo "ERROR: Failed to upgrade $controller_name release."
            echo "ERROR: Use a new, seperate public ip for namespace $namespace."
            exit 1
        fi
    fi
fi

# Create Let's encrypt issuer in the namespace if it does not exist.
# issuer must be in the same namespace as the Ingress for which the 
# certificate is retrieved.
if ! kubectl get Issuer letsencrypt-$namespace -o=name > /dev/null 2>&1 ; then
    echo ""
    echo "Create Let's Encrypt Issuer for $namespace..."
    email=""
    if [[ -n "$userEmail" ]] ; then
        email="    email: $userEmail"
    fi
    n=0
    iterations=40
    until [[ $n -ge $iterations ]] ; do
        cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  namespace: $namespace
  name: letsencrypt-$namespace
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
$email
    privateKeySecretRef:
      name: letsencrypt-$namespace
    solvers:
    - selector: {}
      http01:
        ingress:
          class: nginx-$namespace
EOF

        if [ $? -eq 0 ]; then
            break
        fi
        n=$[$n+1]
        echo "Trying again in 15 seconds..."
        sleep 15
    done
    if [[ $n -eq $iterations ]]; then
        echo "ERROR: Failed to create Let's Encrypt Issuer for $namespace."
        exit 1
    else
        echo "Let's Encrypt issuer created in $namespace."
    fi
fi

# Install aiiot/azure-industrial-iot Helm chart
echo ""
extra_settings=""
if [[ -n "$servicesAppId" ]] ; then
    extra_settings="$extra_settings --set azure.auth.servicesApp.appId=$servicesAppId"
    extra_settings="$extra_settings --set azure.auth.servicesApp.secret=$servicesAppSecret"
    extra_settings="$extra_settings --set azure.tenantId=$managedIdentityTenantId"
fi
if [[ -n "$dockerUser" ]] && [[ -n "$dockerPassword" ]]; then
    if ! kubectl get secret $dockerUser -n $namespace -o=name > /dev/null 2>&1 ; then
        echo "Create docker registry secret $dockerUser to use for image pull..."
        kubectl create secret docker-registry $dockerUser --docker-server=$dockerServer \
            --docker-username=$dockerUser --docker-password=$dockerPassword \
            -n $namespace
        if [ $? -ne 0 ]; then
            echo "ERROR: Failed to create secret for image pull."
            exit 1
        fi
    else
        echo "WARNING: Using existing secret $dockerUser for image pull."
        echo "WARNING: Manually update the secret if the password changed."
    fi
    extra_settings="$extra_settings --set image.pullSecrets[0].name=$dockerUser"
fi

releases=($(helm ls -f azure-industrial-iot --namespace $namespace -q))
if [[ -z "$releases" ]] ; then
    echo "Installing Helm chart from $helmChartLocation into $namespace..."
    set -x
    helm install --atomic azure-industrial-iot $helmChartLocation \
        --namespace $namespace --timeout 30m0s $extra_settings \
        --set image.tag="$imagesTag" \
        --set image.registry="$dockerServer" \
        --set azure.managedIdentity.name="$managedIdentityName" \
        --set azure.managedIdentity.clientId="$managedIdentityClientId" \
        --set azure.managedIdentity.tenantId="$managedIdentityTenantId" \
        --set azure.keyVault.uri=$keyVaultUri \
        --set loadConfFromKeyVault=true \
        --set externalServiceUrl="https://$servicesHostname" \
        --set deployment.microServices.engineeringTool.enabled=$engineeringTool \
        --set deployment.microServices.telemetryProcessor.enabled=$telemetryProcessor \
        --set deployment.ingress.enabled=true \
        --set deployment.ingress.annotations."kubernetes\.io\/ingress\.class"=nginx-$namespace \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/affinity"=cookie \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-name"=affinity \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-expires"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-max-age"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-read-timeout"=3600 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-send-timeout"=3600 \
        --set deployment.ingress.annotations."cert-manager\.io\/issuer"=letsencrypt-$namespace \
        --set deployment.ingress.tls[0].hosts[0]=$servicesHostname \
        --set deployment.ingress.tls[0].secretName=tls-secret \
        --set deployment.ingress.hostName=$servicesHostname

    set +x
    if [ $? -eq 0 ] ; then
        echo "Helm chart from $helmChartLocation installed into $namespace."
    else
        echo "ERROR: Failed to install helm chart from $helmChartLocation."
        exit 1
    fi
else
    helm upgrade --atomic azure-industrial-iot $helmChartLocation \
        --namespace $namespace --timeout 30m0s --reuse-values $extra_settings \
        --set image.tag="$imagesTag" \
        --set image.registry="$dockerServer" \
        --set azure.managedIdentity.name="$managedIdentityName" \
        --set azure.managedIdentity.clientId="$managedIdentityClientId" \
        --set azure.managedIdentity.tenantId="$managedIdentityTenantId" \
        --set azure.keyVault.uri=$keyVaultUri \
        --set azure.tenantId="$managedIdentityTenantId" \
        --set loadConfFromKeyVault=true \
        --set deployment.microServices.engineeringTool.enabled=$engineeringTool \
        --set deployment.microServices.telemetryProcessor.enabled=$telemetryProcessor \
        --set deployment.ingress.annotations."kubernetes\.io\/ingress\.class"=nginx-$namespace \
        --set deployment.ingress.hostName=$servicesHostname > /dev/null 2>&1

    if [ $? -eq 0 ] ; then
        echo "Upgraded release azure-industrial-iot from $helmChartLocation in $namespace."
    else
        echo "ERROR: Failed to upgrade azure-industrial-iot release."
        exit 1
    fi
fi

echo "Installed all services into namespace $namespace of cluster $aksCluster."
# todo - test access at https endpoint
# -------------------------------------------------------------------------
