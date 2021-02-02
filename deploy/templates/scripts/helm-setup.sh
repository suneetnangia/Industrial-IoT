#!/bin/bash

# must be run as sudo
# -------------------------------------------------------------------------------
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

# -------------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace)                NAMESPACE="$2" ;;
        -n)                         NAMESPACE="$2" ;;
        --resourceGroup)            RESOURCE_GROUP="$2" ;;
        -g)                         RESOURCE_GROUP="$2" ;;
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

# -------------------------------------------------------------------------------

if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    az login --identity
fi

if [[ -z "$NAMESPACE" ]]; then
    echo "Missing namespace name."
    exit 1
fi
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "Missing resource group name."
    exit 1
fi
if [[ -z "$AKS_CLUSTER" ]]; then
    AKS_CLUSTER=$(az aks list -g $RESOURCE_GROUP \
        --query [0].name -o tsv | tr -d '\r')
    if [[ -z "$AKS_CLUSTER" ]]; then
        echo "Missing aks cluster name."
        echo "Ensure one was created in resource group $RESOURCE_GROUP."
        exit 1
    fi
fi
if [[ -z "$KEY_VAULT_URI" ]]; then
    KEY_VAULT_URI=$(az keyvault list  -g $RESOURCE_GROUP \
        --query [0].properties.vaultUri -o tsv | tr -d '\r')
    if [[ -z "$KEY_VAULT_URI" ]]; then
        echo "Unable to retrieve platform keyvault uri."
        echo "Ensure it was created in '$RESOURCE_GROUP' group."
        exit 1
    fi
fi
if [[ -z "$MANAGED_IDENTITY_ID" ]] ; then
    MANAGED_IDENTITY_ID=$(az identity list -g $RESOURCE_GROUP \
        --query "[?starts_with(name, 'services-')].id" -o tsv | tr -d '\r')
    if [[ -z "$MANAGED_IDENTITY_ID" ]] ; then
        echo "Unable to find platform msi in '$RESOURCE_GROUP' group."
        echo "Ensure it was created before running this script."
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
        echo "Unable to get properties from msi $msiId."
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
        echo "Unable to get public ip properties from $publicIpId."
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
        echo "Missing service app secret. "
        echo "Must be provided if app id is provided"
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

# -------------------------------------------------------------------------------
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
        echo "Failed to install kubectl.  Are you running as sudo?"
        exit 1
    fi
fi
if ! helm version > /dev/null 2>&1 ; then
    echo "Install Helm..."
    if ! az acr helm install-cli --client-version "3.3.4" -y > /dev/null 2>&1; then
        echo "Failed to install helm.  Are you running as sudo?"
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

# -------------------------------------------------------------------------------
# Configure omsagent
if [[ -f "$CWD/omsagent.yaml" ]];then
    if ! kubectl apply -f "$CWD/omsagent.yaml" ; then
        echo "Failed to install OMS agent."
    else
        echo "Azure monitor OMS agent support installed."
    fi
else
    echo "Missing omsagent.yml configuration."
    echo "Skipping installation of OMS agent."
fi

# -------------------------------------------------------------------------------
# Add Helm repos
if ! helm repo add jetstack \
    https://charts.jetstack.io ; then
    echo "Failed to add jetstack repo."
    exit 1
fi
if ! helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx ; then
    echo "Failed to add ingress-nginx repo."
    exit 1
fi
if ! helm repo add aad-pod-identity \
    https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts ; then
    echo "Failed to add aad-pod-identity repo."
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
            echo "Failed to log into registry using user and password"
            exit 1
        fi
    fi
    echo "Download $chart..."
    if ! helm chart pull $chart ; then
        echo "Failed to download $chart."
        exit 1
    fi
    helm chart export $chart --destination ./aiiot
    helm_chart_location="./aiiot/$HELM_CHART_NAME"
    echo "Downloaded Helm chart $chart will be installed..."
else
    # add the repo
    echo "Configure Helm chart repository configured..."
    if ! helm repo add aiiot $HELM_REPO_URL ; then
        echo "Failed to add azure-industrial-iot repo."
        exit 1
    fi
    helm_chart_location="aiiot/$HELM_CHART_NAME --version $HELM_CHART_VERSION"
    echo "Helm chart from $HELM_REPO_URL/$HELM_CHART_NAME will be installed..."
fi
helm repo update

# -------------------------------------------------------------------------------
# Install ingress controller and azure iiot services chart

extra_settings=""
if [[ -n "$SERVICES_APP_ID" ]] ; then
    extra_settings=$extra_settings' --set azure.auth.servicesApp.appId="'$SERVICES_APP_ID'"'
    extra_settings=$extra_settings' --set azure.auth.servicesApp.secret="'$SERVICES_APP_SECRET'"'
fi
if [[ -n "$MANAGED_IDENTITY_CLIENT_ID" ]] ; then
    extra_settings=$extra_settings' --set azure.managedIdentity.clientId="'$MANAGED_IDENTITY_CLIENT_ID'"'
    extra_settings=$extra_settings' --set azure.managedIdentity.tenantId="'$TENANT_ID'"'
fi

# Create namespace
if ! kubectl create namespace $NAMESPACE > /dev/null 2>&1 ; then
    echo "Namespace $NAMESPACE already exists.  Performing upgrade..."
    # todo: Upgrade
    # todo: Upgrade
    # todo: Upgrade
    # todo: Upgrade
else
    echo ""
    echo "Installing aad-pod-identity Helm chart..."
    # Install per-pod identities into the namespace
    helm install --atomic $NAMESPACE-identity aad-pod-identity/aad-pod-identity \
        --namespace $NAMESPACE --version 3.0.0 --timeout 30m0s \
        --set forceNamespaced="true"
    if [ $? -eq 0 ]; then
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
EOF
        cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: $MANAGED_IDENTITY_NAME-binding
  namespace: $NAMESPACE
spec:
  azureIdentity: $MANAGED_IDENTITY_NAME
  selector: $NAMESPACE-identity
EOF
        # -set nmi.allowNetworkPluginKubenet=true
        echo "Per pod identity support installed into $NAMESPACE."
    else
        echo "Failed to install per-pod identity support into $NAMESPACE."
        kubectl delete namespaces $NAMESPACE > /dev/null 2>&1
        exit 1
    fi

    # Install jetstack/cert-manager Helm chart and create Let's encrypt issuer
    echo ""
    echo "Installing jetstack/cert-manager Helm chart..."
    helm install --atomic $NAMESPACE-cert-manager jetstack/cert-manager \
        --namespace $NAMESPACE --version v1.1.0 --timeout 30m0s \
        --set installCRDs=true 
    n=0
    iterations=0
    if [ $? -eq 0 ]; then
        echo "Create Let's Encrypt Issuer in $NAMESPACE..."
        email=""
        if [[ -n "$USER_EMAIL" ]] ; then
            email="    email: $USER_EMAIL"
        fi
        iterations=20
        until [[ $n -ge $iterations ]] ; do
            cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-$NAMESPACE
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
$email
    privateKeySecretRef:
      name: letsencrypt-$NAMESPACE
    solvers:
    - http01:
        ingress:
          class: nginx-$NAMESPACE
EOF

            if [ $? -eq 0 ]; then
                break
            fi
            n=$[$n+1]
            echo "Trying to create Let's Encrypt Issuer again in 15 seconds"
            sleep 15
        done
    fi
    if [[ $n -eq $iterations ]]; then
        echo "Failed to install Let's Encrypt issuer into $NAMESPACE."
        kubectl delete namespaces $NAMESPACE > /dev/null 2>&1
        exit 1
    else
        echo "Let's Encrypt issuer installed into $NAMESPACE."
    fi

    # Install ingress-nginx/ingress-nginx Helm chart
    echo ""
    echo "Installing ingress controller class nginx-$NAMESPACE for $LOAD_BALANCER_IP..."
    helm install --atomic $NAMESPACE-ingress ingress-nginx/ingress-nginx \
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
        --set defaultBackend.nodeSelector."beta\.kubernetes\.io\/os"=linux 
      # --set controller.service.annotations."service\.beta\.kubernetes\.io\/azure-load-balancer-internal"=true \
    if [ $? -eq 0 ]; then
        echo "Ingress controller class nginx-$NAMESPACE installed."
    else
        echo "Failed to install ingress controller into $NAMESPACE."
        kubectl delete namespaces $NAMESPACE > /dev/null 2>&1
        exit 1
    fi

    # Install aiiot/azure-industrial-iot Helm chart
    echo ""
    echo "Installing Helm chart from $helm_chart_location into $NAMESPACE..."
    helm install --atomic azure-industrial-iot $helm_chart_location \
        --namespace $NAMESPACE --timeout 30m0s $extra_settings \
        --set image.tag=$IMAGES_TAG \
        --set loadConfFromKeyVault=true \
        --set azure.keyVault.uri=$KEY_VAULT_URI \
        --set azure.tenantId=$TENANT_ID \
        --set externalServiceUrl="https://$SERVICES_HOSTNAME" \
        --set deployment.microServices.engineeringTool.enabled=false \
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
        --set deployment.ingress.hostName=$SERVICES_HOSTNAME
    if [ $? -eq 0 ]; then
        echo "Helm chart from $helm_chart_location installed into $NAMESPACE."
    else
        echo "Failed to install helm chart from $helm_chart_location."
        kubectl delete namespaces $NAMESPACE > /dev/null 2>&1
        exit 1
    fi
fi
echo "Done"
# -------------------------------------------------------------------------------
