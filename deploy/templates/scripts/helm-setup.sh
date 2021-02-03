#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --namespace, -n            Namespace to use to install into.
    --resourcegroup, -g        Resource group in which the cluster resides.
    --help                     Shows this help.
'
    exit 1
}

# must be run as sudo
if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] && [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 2
fi

CWD=$(pwd)
RESOURCE_GROUP=
NAMESPACE=
AKS_CLUSTER=
ROLE=
LOAD_BALANCER_IP=
PUBLIC_IP_DNS_LABEL=
HELM_REPO_URL=
HELM_CHART_NAME=
HELM_CHART_VERSION=
IMAGES_TAG=
IMAGES_NAMESPACE=
DOCKER_SERVER=
DOCKER_USER=
TENANT_ID=
USER_EMAIL=
USER_ID=
KEY_VAULT_URI=
MANAGED_IDENTITY_ID=
MANAGED_IDENTITY_NAME=
MANAGED_IDENTITY_CLIENT_ID=
SERVICES_HOSTNAME=
SERVICES_APP_ID=

#SERVICES_APP_SECRET= # allow passing from environment
#DOCKER_PASSWORD= # allow passing from environment

[ $# -eq 0 ] && usage
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help)                     usage ;;
        --namespace)                NAMESPACE="$2" ;;
        -n)                         NAMESPACE="$2" ;;
        --resourcegroup)            RESOURCE_GROUP="$2" ;;
        -g)                         RESOURCE_GROUP="$2" ;;
        # automation...
        --aksCluster)               AKS_CLUSTER="$2" ;;
        --email)                    USER_EMAIL="$2" ;;
        --user)                     USER_ID="$2" ;;
        --loadBalancerIp)           LOAD_BALANCER_IP="$2" ;;
        --publicIpDnsLabel)         PUBLIC_IP_DNS_LABEL="$2" ;;
        --helmRepoUrl)              HELM_REPO_URL="$2" ;;
        --helmChartName)            HELM_CHART_NAME="$2" ;;
        --helmChartVersion)         HELM_CHART_VERSION="$2" ;;
        --imagesNamespace)          IMAGES_NAMESPACE="$2" ;;
        --imagesTag)                IMAGES_TAG="$2" ;;
        --dockerServer)             DOCKER_SERVER="$2" ;;
        --dockerUser)               DOCKER_USER="$2" ;;
        --dockerPassword)           DOCKER_PASSWORD="$2" ;;
        --managedIdentityId)        MANAGED_IDENTITY_ID="$2" ;;
        --managedIdentityName)      MANAGED_IDENTITY_NAME="$2" ;;
        --managedIdentityClientId)  MANAGED_IDENTITY_CLIENT_ID="$2" ;;
        --tenant)                   TENANT_ID="$2" ;;
        --keyVaultUri)              KEY_VAULT_URI="$2" ;;
        --servicesHostname)         SERVICES_HOSTNAME="$2" ;;
        --role)                     ROLE="$2" ;;
        --servicesAppId)            SERVICES_APP_ID="$2" ;;
        --servicesAppSecret)        SERVICES_APP_SECRET="$2" ;;
    esac
    shift
done

# --------------------------------------------------------------------------------------

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    az login --identity
fi

if [[ -z "$NAMESPACE" ]]; then
    echo "ERROR: Missing namespace name. You must use --namespace parameter."
    usage
fi
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "ERROR: Missing resource group name.  Use --resourcegroup parameter."
    usage
fi
if [[ -z "$AKS_CLUSTER" ]]; then
    AKS_CLUSTER=$(az aks list -g $RESOURCE_GROUP \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$AKS_CLUSTER" ]]; then
        echo "ERROR: Missing aks cluster name."
        echo "ERROR: Ensure one was created in resource group $RESOURCE_GROUP."
        exit 1
    fi
fi
if [[ -z "$KEY_VAULT_URI" ]]; then
    KEY_VAULT_URI=$(az keyvault list  -g $RESOURCE_GROUP \
        --query [0].properties.vaultUri -o tsv | tr -d '\r')
    if [[ -z "$KEY_VAULT_URI" ]]; then
        echo "ERROR: Unable to retrieve platform keyvault uri."
        echo "ERROR: Ensure it was created in '$RESOURCE_GROUP' group."
        exit 1
    fi
fi
if [[ -z "$MANAGED_IDENTITY_ID" ]] ; then
    MANAGED_IDENTITY_ID=$(az identity list -g $RESOURCE_GROUP \
        --query "[?starts_with(name, 'services-')].id" -o tsv | tr -d '\r')
    if [[ -z "$MANAGED_IDENTITY_ID" ]] ; then
        echo "ERROR: Unable to find platform msi in '$RESOURCE_GROUP' group."
        echo "ERROR: Ensure it was created before running this script."
        exit 1
    fi
fi
if [[ -z "$MANAGED_IDENTITY_CLIENT_ID" ]] || \
   [[ -z "$TENANT_ID" ]] ; then
    IFS=$'\n'; msi=($(az identity show --ids $MANAGED_IDENTITY_ID \
        --query "[name, clientId, tenantId, principalId]" \
        -o tsv | tr -d '\r')); unset IFS;

    MANAGED_IDENTITY_NAME=${msi[0]}
    MANAGED_IDENTITY_CLIENT_ID=${msi[1]}
    TENANT_ID=${msi[2]}
    if [[ -z "$MANAGED_IDENTITY_CLIENT_ID" ]]; then
        echo "ERROR: Unable to get properties from msi $msiId."
        exit 1
    fi
fi

# Get public ip information if not provided 
if [[ -z "$LOAD_BALANCER_IP" ]] || \
   [[ -z "$PUBLIC_IP_DNS_LABEL" ]] || \
   [[ -z "$SERVICES_HOSTNAME" ]] ; then
    # public ip domain label should be namespace name
    publicIpId=$(az network public-ip list \
        --query "[?dnsSettings.domainNameLabel=='$NAMESPACE'].id" \
        -o tsv | tr -d '\r')
    if [[ -z "$publicIpId" ]] ; then
        # If not then public ip name starts with resource group name
        publicIpId=$(az network public-ip list \
            --query "[?starts_with(name, '$RESOURCE_GROUP')].id" \
            -o tsv | tr -d '\r')
    fi
    if [[ -z "$publicIpId" ]] ; then
        echo "Unable to find public ip for '$NAMESPACE' label."
        echo "Ensure it exists in the node resource group of the cluster."
        exit 1
    fi
    IFS=$'\n'; publicIp=($(az network public-ip show --ids $publicIpId \
        --query "[dnsSettings.fqdn, ipAddress, dnsSettings.domainNameLabel]" \
        -o tsv | tr -d '\r')); unset IFS;

    SERVICES_HOSTNAME=${publicIp[0]}
    LOAD_BALANCER_IP=${publicIp[1]}
    PUBLIC_IP_DNS_LABEL=${publicIp[2]}
    if [[ -z "$SERVICES_HOSTNAME" ]] ; then
        echo "ERROR: Unable to get public ip properties from $publicIpId."
        exit 1
    fi
fi
if [[ -z "$USER_EMAIL" ]] || \
   [[ -z "$USER_ID" ]] ; then
    IFS=$'\n'; user=($(az ad signed-in-user show \
        --query "[objectId, mail]" -o tsv | tr -d '\r')); unset IFS;
    if [[ -z "$USER_ID" ]]; then
        USER_ID=${user[0]}
    fi
    if [[ -z "$USER_EMAIL" ]]; then
        USER_EMAIL=${user[1]}
    fi
fi

if [[ -n "$SERVICES_APP_ID" ]]; then
    if [[ -z "$SERVICES_APP_SECRET" ]]; then
        echo "ERROR: Missing service app secret. "
        echo "ERROR: Must be provided if app id is provided"
        exit 1
    fi
fi
if [[ -z "$HELM_CHART_NAME" ]]; then
    HELM_CHART_NAME="azure-industrial-iot"
fi
if [[ -z "$HELM_CHART_VERSION" ]]; then
    if [[ -n "$HELM_REPO_URL" ]]; then
        HELM_CHART_VERSION="0.4.0"
        if [[ -z "$IMAGES_TAG" ]]; then
            IMAGES_TAG="2.7"
        fi
        if [[ -z "$DOCKER_SERVER" ]]; then
            DOCKER_SERVER="mcr.microsoft.com"
        fi
    else
        if [[ -z "$IMAGES_TAG" ]]; then
            IMAGES_TAG="preview"
        fi
        HELM_CHART_VERSION="preview"
        if [[ -z "$DOCKER_SERVER" ]]; then
            DOCKER_SERVER="industrialiotdev.azurecr.io"
        fi
    fi
fi
if [[ -z "$ROLE" ]]; then
    ROLE="AzureKubernetesServiceClusterUserRole"
fi

echo ""
echo "RESOURCE_GROUP=$RESOURCE_GROUP"
echo "NAMESPACE=$NAMESPACE"
echo "AKS_CLUSTER=$AKS_CLUSTER"
echo "ROLE=$ROLE"
echo "LOAD_BALANCER_IP=$LOAD_BALANCER_IP"
echo "PUBLIC_IP_DNS_LABEL=$PUBLIC_IP_DNS_LABEL"
echo "HELM_REPO_URL=$HELM_REPO_URL"
echo "HELM_CHART_VERSION=$HELM_CHART_VERSION"
echo "IMAGES_TAG=$IMAGES_TAG"
echo "IMAGES_NAMESPACE=$IMAGES_NAMESPACE"
echo "DOCKER_SERVER=$DOCKER_SERVER"
echo "DOCKER_USER=$DOCKER_SERVER"
echo "TENANT_ID=$TENANT_ID"
echo "KEY_VAULT_URI=$KEY_VAULT_URI"
echo "MANAGED_IDENTITY_ID=$MANAGED_IDENTITY_ID"
echo "MANAGED_IDENTITY_NAME=$MANAGED_IDENTITY_NAME"
echo "MANAGED_IDENTITY_CLIENT_ID=$MANAGED_IDENTITY_CLIENT_ID"
echo "SERVICES_HOSTNAME=$SERVICES_HOSTNAME"
echo "SERVICES_APP_ID=$SERVICES_APP_ID"
echo "USER_ID=$USER_ID"
echo "USER_EMAIL=$USER_EMAIL"
echo ""

# echo "DOCKER_PASSWORD=$DOCKER_PASSWORD"
# echo "SERVICES_APP_SECRET=$SERVICES_APP_SECRET"

# --------------------------------------------------------------------------------------
# Add user as member to admin group to get access
if [[ -z "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    if [[ -n "$USER_ID" ]] ; then
        source $CWD/group-setup.sh \
--description "Administrator group for $AKS_CLUSTER in resource group $RESOURCE_GROUP" \
            --display "$AKS_CLUSTER Administrators" \
            --member "$USER_ID" \
            --name "$AKS_CLUSTER" 
    fi
fi
# Go to home.
cd ~
if ! kubectl version > /dev/null 2>&1 ; then
    echo "Install kubectl..."
    if ! az aks install-cli > /dev/null 2>&1; then 
        echo "ERROR: Failed to install kubectl."
        exit 1
    fi
fi
if ! helm version > /dev/null 2>&1 ; then
    echo "Install Helm..."
    if ! az acr helm install-cli --client-version "3.3.4" -y > /dev/null 2>&1; then
        echo "ERROR: Failed to install helm. "
        exit 1
    fi
fi
echo "Prerequisites installed - getting credentials for the cluster..."

# Get AKS credentials
if [[ "$ROLE" -eq "AzureKubernetesServiceClusterAdminRole" ]]; then
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER --admin
else
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER
fi
echo "Credentials for AKS cluster acquired."

# --------------------------------------------------------------------------------------
# Configure omsagent
if [[ -f "$CWD/omsagent.yaml" ]];then
    if ! kubectl apply -f "$CWD/omsagent.yaml" ; then
        echo "ERROR: Failed to install OMS agent."
    else
        echo "Azure monitor OMS agent support installed."
    fi
else
    echo "WARNING: Missing omsagent.yml configuration."
    echo "WARNING: Skipping installation of OMS agent."
fi

# --------------------------------------------------------------------------------------

# Add Helm repos
if ! helm repo add jetstack https://charts.jetstack.io 
then
    echo "ERROR: Failed to add jetstack repo."
    exit 1
fi
if ! helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 
then
    echo "ERROR: Failed to add ingress-nginx repo."
    exit 1
fi
if ! helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts 
then
    echo "ERROR: Failed to add aad-pod-identity repo."
    exit 1
fi

if [[ -z "$HELM_REPO_URL" ]] ; then
    export HELM_EXPERIMENTAL_OCI=1
    # docker server is the oci registry from where to consume the helm chart
    # the repo is the path and name of the chart
    chart="$DOCKER_SERVER/$HELM_CHART_NAME:$HELM_CHART_VERSION"
    helm chart remove $chart && echo "No charts to remove."
    # lpg into the server
    if [[ -n "$DOCKER_USER" ]] && [[ -n "$DOCKER_PASSWORD" ]] ; then
        if ! helm registry login -u "$DOCKER_USER" -p "$DOCKER_PASSWORD" ; then
            echo "ERROR: Failed to log into registry using user and password"
            exit 1
        fi
    fi
    echo "Download $chart..."
    if ! helm chart pull $chart ; then
        echo "ERROR: Failed to download chart $chart."
        exit 1
    fi
    helm chart export $chart --destination ./aiiot
    helm_chart_location="./aiiot/$HELM_CHART_NAME"
    echo "Downloaded Helm chart $chart will be installed..."
else
    # add the repo
    echo "Configure Helm chart repository configured..."
    if ! helm repo add aiiot $HELM_REPO_URL ; then
        echo "ERROR: Failed to add azure-industrial-iot repo."
        exit 1
    fi
    helm_chart_location="aiiot/$HELM_CHART_NAME --version $HELM_CHART_VERSION"
    echo "Helm chart from $HELM_REPO_URL/$HELM_CHART_NAME will be installed..."
fi
helm repo update

# --------------------------------------------------------------------------------------

# Install jetstack/cert-manager Helm chart if not already installed
echo ""
releases=($(helm ls -f cert-manager -A -q))
if [[ -z "$releases" ]]; then
    echo "Installing jetstack/cert-manager Helm chart..."
    helm install --atomic cert-manager jetstack/cert-manager \
        --version v1.1.0 --timeout 30m0s \
        --set installCRDs=true \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Installed jetstack/cert-manager Helm chart."
    else
        echo "ERROR: Failed to install jetstack/cert-manager Helm chart."
        if ! kubectl get crds issuers.cert-manager.io > /dev/null 2>&1; then
            exit 1
        fi
        echo "WARNING: Found issuer crd, trying without installation ..."
    fi
else
    helm upgrade --atomic cert-manager jetstack/cert-manager \
        --version v1.1.0 --timeout 30m0s --reuse-values \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Upgraded jetstack/cert-manager cert-manager release."
    else
        echo "ERROR: Failed to upgrade cert-manager release."
        echo "WARNING: Trying to continue without upgrade..."
        # exit 1
    fi
fi

# install per pod identity if it is not yet installed
echo ""
releases=($(helm ls -f aad-pod-identity -A -q))
if [[ -z "$releases" ]]; then
    echo "Installing aad-pod-identity Helm chart into default namespace..."
    helm install --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
        --version 3.0.0 --timeout 30m0s --set forceNamespaced="true" \
        > /dev/null 2>&1
        # -set nmi.allowNetworkPluginKubenet=true
    if [ $? -eq 0 ]; then
        echo "Installed aad-pod-identity Helm chart ."
    else
        echo "ERROR: Failed to install aad-pod-identity Helm chart."
        if ! kubectl get crds azureidentities.aadpodidentity.k8s.io > /dev/null 2>&1; then
            exit 1
        fi
        echo "WARNING: Found azureidentities crd, trying without installation ..."
    fi
else
    helm upgrade --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
        --version 3.0.0 --timeout 30m0s --reuse-values \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Upgraded aad-pod-identity/aad-pod-identity aad-pod-identity release."
    else
        echo "ERROR: Failed to upgrade aad-pod-identity release."
        echo "WARNING: Trying to continue without upgrade..."
        # exit 1
    fi
fi

extra_settings=""
if [[ -n "$SERVICES_APP_ID" ]] ; then
    extra_settings=$extra_settings' --set azure.auth.servicesApp.appId="'$SERVICES_APP_ID'"'
    extra_settings=$extra_settings' --set azure.auth.servicesApp.secret="'$SERVICES_APP_SECRET'"'
fi

# --------------------------------------------------------------------------------------

# Create namespace to deploy into
if ! kubectl create namespace $NAMESPACE > /dev/null 2>&1 ; then
    echo "Namespace $NAMESPACE already exists..."
fi

# Create identity for the supplied managed service identity and
# a binding to the scheduled pods if it does not yet exist.
if ! kubectl get AzureIdentity $MANAGED_IDENTITY_NAME -A -o=name > /dev/null 2>&1 ; then
    echo "Creating managed identity $MANAGED_IDENTITY_NAME..."

    cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: $MANAGED_IDENTITY_NAME
  namespace: $NAMESPACE
  annotations:
    aadpodidentity.k8s.io/Behavior: namespaced
spec:
  type: 0
  resourceID: $MANAGED_IDENTITY_ID
  clientID: $MANAGED_IDENTITY_CLIENT_ID
---
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: $MANAGED_IDENTITY_NAME-binding
  namespace: $NAMESPACE
spec:
  azureIdentity: $MANAGED_IDENTITY_NAME
  selector: $MANAGED_IDENTITY_NAME
EOF

    if [ $? -eq 0 ]; then
        echo "Per pod identity $MANAGED_IDENTITY_NAME installed."
    else
        echo "ERROR: Failed to install identity $MANAGED_IDENTITY_NAME."
        exit 1
    fi
else
    echo "Per pod identity $MANAGED_IDENTITY_NAME exists."
fi

# https://kubernetes.github.io/ingress-nginx/user-guide/multiple-ingress/#multiple-ingress-nginx-controllers
# Install ingress-nginx/ingress-nginx Helm chart into the namespace giving it a class name that applies 
# to the public ip.
echo ""
controller_name=${PUBLIC_IP_DNS_LABEL:0:25}
releases=($(helm ls -f $controller_name -A -q))
if [[ -z "$releases" ]]; then
    echo "Installing nginx-ingress $controller_name with class nginx-$NAMESPACE for $LOAD_BALANCER_IP into $NAMESPACE..."
    helm install --atomic $controller_name ingress-nginx/ingress-nginx \
        --namespace $NAMESPACE --version 3.20.1 --timeout 30m0s \
        --set controller.ingressClass=nginx-$NAMESPACE \
        --set controller.replicaCount=2 \
        --set controller.podLabels.aadpodidbinding=$MANAGED_IDENTITY_NAME \
        --set controller.nodeSelector."beta\.kubernetes\.io\/os"=linux \
        --set controller.service.loadBalancerIP=$LOAD_BALANCER_IP \
        --set controller.service.annotations."service\.beta\.kubernetes\.io\/azure-dns-label-name"=$PUBLIC_IP_DNS_LABEL \
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
        echo "Completed installation of nginx-ingress controller $controller_name with class nginx-$NAMESPACE."
    else
        echo "ERROR: Failed to install Ingress controller $controller_name into $NAMESPACE."
        exit 1
    fi
else
    releases=($(helm ls -f $controller_name -A -o table))
    ns=${releases[9]} # the namespace of the first line in the table
    if [[ "$ns" != "$NAMESPACE" ]] ; then 
        echo "Updating release $controller_name release in $ns with ingress class nginx-$NAMESPACE."
        helm upgrade--atomic $controller_name ingress-nginx/ingress-nginx \
            --namespace $ns --version 3.20.1 --timeout 30m0s --reuse-values \
            --set controller.ingressClass=nginx-$NAMESPACE \
            > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            echo "Upgraded $controller_name to ingress class nginx-$NAMESPACE."
            echo "WARNING: $ns will not work anymore until updated back."
        else
            echo "ERROR: Failed to upgrade $controller_name release."
            echo "ERROR: Use a new, seperate public ip for namespace $NAMESPACE."
            exit 1
        fi
    fi
fi

# Create Let's encrypt issuer in the namespace if it does not exist.
# issuer must be in the same namespace as the Ingress for which the certificate is retrieved.
if ! kubectl get Issuer letsencrypt-$NAMESPACE -o=name > /dev/null 2>&1 ; then
    echo ""
    echo "Create Let's Encrypt Issuer for $NAMESPACE..."
    email=""
    if [[ -n "$USER_EMAIL" ]] ; then
        email="    email: $USER_EMAIL"
    fi
    n=0
    iterations=40
    until [[ $n -ge $iterations ]] ; do
        cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  namespace: $NAMESPACE
  name: letsencrypt-$NAMESPACE
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
$email
    privateKeySecretRef:
      name: letsencrypt-$NAMESPACE
    solvers:
    - selector: {}
      http01:
        ingress:
          class: nginx-$NAMESPACE
EOF

        if [ $? -eq 0 ]; then
            break
        fi
        n=$[$n+1]
        echo "Trying again in 15 seconds..."
        sleep 15
    done
    if [[ $n -eq $iterations ]]; then
        echo "ERROR: Failed to create Let's Encrypt Issuer for $NAMESPACE."
        exit 1
    else
        echo "Let's Encrypt issuer created in $NAMESPACE."
    fi
fi

# Install aiiot/azure-industrial-iot Helm chart
echo ""
releases=($(helm ls -f azure-industrial-iot --namespace $NAMESPACE -q))
if [[ -z "$releases" ]]; then
    echo "Installing Helm chart from $helm_chart_location into $NAMESPACE..."
    helm install --atomic azure-industrial-iot $helm_chart_location \
        --namespace $NAMESPACE --timeout 30m0s $extra_settings \
        --set image.tag=$IMAGES_TAG \
        --set image.registry=$DOCKER_SERVER \
        --set azure.managedIdentity.name=$MANAGED_IDENTITY_NAME \
        --set azure.managedIdentity.clientId=$MANAGED_IDENTITY_CLIENT_ID \
        --set azure.managedIdentity.tenantId=$TENANT_ID \
        --set azure.keyVault.uri=$KEY_VAULT_URI \
        --set azure.tenantId=$TENANT_ID \
        --set loadConfFromKeyVault=true \
        --set externalServiceUrl="https://$SERVICES_HOSTNAME" \
        --set deployment.microServices.engineeringTool.enabled=true \
        --set deployment.ingress.enabled=true \
        --set deployment.ingress.annotations."kubernetes\.io\/ingress\.class"=nginx-$NAMESPACE \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/affinity"=cookie \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-name"=affinity \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-expires"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-max-age"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-read-timeout"=3600 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-send-timeout"=3600 \
        --set deployment.ingress.annotations."cert-manager\.io\/issuer"=letsencrypt-$NAMESPACE \
        --set deployment.ingress.tls[0].hosts[0]=$SERVICES_HOSTNAME \
        --set deployment.ingress.tls[0].secretName=tls-secret \
        --set deployment.ingress.hostName=$SERVICES_HOSTNAME \
        > /dev/null 2>&1
    if [ $? -eq 0 ] ; then
        echo "Helm chart from $helm_chart_location installed into $NAMESPACE as azure-industrial-iot."
    else
        echo "ERROR: Failed to install helm chart from $helm_chart_location."
        exit 1
    fi
else
    helm upgrade --atomic azure-industrial-iot $helm_chart_location \
        --namespace $NAMESPACE --timeout 30m0s --reuse-values $extra_settings \
        --set image.tag=$IMAGES_TAG \
        --set azure.managedIdentity.name=$MANAGED_IDENTITY_NAME \
        --set azure.managedIdentity.clientId=$MANAGED_IDENTITY_CLIENT_ID \
        --set azure.managedIdentity.tenantId=$TENANT_ID \
        --set azure.keyVault.uri=$KEY_VAULT_URI \
        --set azure.tenantId=$TENANT_ID \
        --set loadConfFromKeyVault=true \
        --set deployment.microServices.engineeringTool.enabled=true \
        --set deployment.ingress.annotations."kubernetes\.io\/ingress\.class"=nginx-$NAMESPACE \
        --set deployment.ingress.hostName=$SERVICES_HOSTNAME \
        > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "Upgraded release azure-industrial-iot from $helm_chart_location."
    else
        echo "ERROR: Failed to upgrade azure-industrial-iot release."
        exit 1
    fi
fi

# --------------------------------------------------------------------------------------
