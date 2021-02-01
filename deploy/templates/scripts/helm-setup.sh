#!/usr/bin/env bash

# -------------------------------------------------------------------------------
if [[ -n "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then set -ex; else set -e; fi

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
        --query "[?starts_with(name, 'services-')].id)" -o tsv | tr -d '\r')
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
        --query "[?dnsSettings.domainNameLabel=='$NAMESPACE']" \
        -o tsv | tr -d '\r')
    if [[ -z "$publicIpId" ]] ; then
        # If not then public ip name starts with resource group name
        publicIpId=$(az network public-ip list \
            --query "[?starts_with(name, '$RESOURCE_GROUP')]" \
            -o tsv | tr -d '\r')
    fi
    if [[ -z "$publicIpId" ]] ; then
        echo "Unable to find public ip for '$NAMESPACE' label."
        echo "Ensure it exists in the node resource group of the cluster."
        exit 1
    fi
    IFS=$'\n'; publicIp=($(az network public-ip show --ids $publicIpId \
        --query "[dnsSettings.fqdn, ipAddress, domainNameLabel]" \
        -o tsv | tr -d '\r')); unset IFS;

    SERVICES_HOSTNAME=${publicIp[0]}
    LOAD_BALANCER_IP=${publicIp[1]}
    PUBLIC_IP_DNS_LABEL=${publicIp[2]}
    if [[ -z "$SERVICES_HOSTNAME" ]] ; then
        echo "Unable to get public ip properties from $publicIpId."
        exit 1
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
echo ""

# echo "DOCKER_PASSWORD=$DOCKER_PASSWORD"
# echo "SERVICES_APP_SECRET=$SERVICES_APP_SECRET"

# -------------------------------------------------------------------------------
# Go to home.
cd ~

# Install utilities
apk update
apk add gettext
echo "Install kubectl..."
az aks install-cli
echo "Install Helm..."
az acr helm install-cli --client-version "3.3.4" -y
echo "Prerequisites installed - getting credentials..."

# Add user as member to admin group to get access
if [[ -z "$AZ_SCRIPTS_OUTPUT_PATH" ]] ; then
    principalId=$(az ad signed-in-user show --query objectId -o tsv | tr -d '\r')
    ./group-setup.sh \
--description "Administrator group for $AKS_CLUSTER in resource group $RESOURCE_GROUP" \
        --display "$AKS_CLUSTER Administrators" \
        --member $principalId \
        --name "$AKS_CLUSTER" 
fi
# Get AKS credentials
if [[ "$ROLE" -eq "AzureKubernetesServiceClusterAdminRole" ]]; then
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER --admin
else
    az aks get-credentials --resource-group $RESOURCE_GROUP \
        --name $AKS_CLUSTER
fi
echo "Credentials acquired."

# -------------------------------------------------------------------------------
# Configure omsagent
kubectl apply -f "$CWD/omsagent.yaml"
echo "OMS installed."

# -------------------------------------------------------------------------------
# Add Helm repos
helm repo add ingress-nginx \
    https://kubernetes.github.io/ingress-nginx
helm repo add jetstack \
    https://charts.jetstack.io
helm repo add aad-pod-identity \
    https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm repo update
echo "Repos updated."

# -------------------------------------------------------------------------------
# Create ingress-nginx namespace
if ! kubectl create namespace $NAMESPACE-ingress-nginx ; then
    echo "Ingress controller namespace exists."
    # todo: Upgrade
else
    echo "Install ingress-nginx/ingress-nginx Helm chart..."
    # Install ingress-nginx/ingress-nginx Helm chart
    helm install --atomic ingress-nginx ingress-nginx/ingress-nginx \
        --namespace $NAMESPACE-ingress-nginx \
        --version 3.20.1 --timeout 30m0s \
        --set controller.replicaCount=2 \
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
    echo "Ingress controller installed."
fi

# -------------------------------------------------------------------------------
# Create cert-manager namespace
if ! kubectl create namespace $NAMESPACE-cert-manager ; then
    echo "Cert manager namespace already exists."
    # todo: Upgrade
else
    echo "Install jetstack/cert-manager Helm chart..."
    # Install jetstack/cert-manager Helm chart
    helm install --atomic cert-manager jetstack/cert-manager \
        --namespace $NAMESPACE-cert-manager \
        --version v1.1.0 --timeout 30m0s \
        --set installCRDs=true

    # Create Let's Encrypt ClusterIssuer
    n=0
    iterations=20
    until [[ $n -ge $iterations ]]; do
        kubectl apply -f "$CWD/letsencrypt.yaml" && break
        n=$[$n+1]

        echo "Trying to create Let's Encrypt ClusterIssuer again in 15 seconds"
        sleep 15
    done
    if [[ $n -eq $iterations ]]; then
        echo "Failed to create Let's Encrypt ClusterIssuer"
        exit 1
    fi
    echo "Cert manager installed."
fi

# -------------------------------------------------------------------------------
# Install azure iiot services chart

if [[ -z "$HELM_REPO_URL" ]] ; then
    export HELM_EXPERIMENTAL_OCI=1
    # docker server is the oci registry from where to consume the helm chart
    # the repo is the path and name of the chart
    chart="$DOCKER_SERVER/$HELM_CHART_NAME:$HELM_CHART_VERSION"
    helm chart remove $chart
    # lpg into the server
    if [[ -n "$DOCKER_USER" ]] && [[ -n "$DOCKER_PASSWORD" ]] ; then
        if ! helm registry login -u "$DOCKER_USER" -p "$DOCKER_PASSWORD" ; then
            echo "Failed to log into registry using user and password"
            exit 1
        fi
    fi
    echo "Download $chart..."
    helm chart pull $chart
    helm chart export $chart --destination ./aiiot
    helm_chart_location="./aiiot/$HELM_CHART_NAME"
    echo "Helm chart $chart downloaded."
else
    # add the repo
    echo "Configure Helm chart repository configured..."
    helm repo add aiiot $HELM_REPO_URL
    helm repo update
    helm_chart_location="aiiot/$HELM_CHART_NAME --version $HELM_CHART_VERSION"
    echo "Install $HELM_REPO_URL/$HELM_CHART_NAME Helm chart..."
fi

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
if ! kubectl create namespace $NAMESPACE ; then
    echo "Namespace already exists.  Performing upgrade"
    # todo: Upgrade
else
    if [[ -n "$MANAGED_IDENTITY_ID" ]] ; then
        echo "Install aad-pod-identity Helm chart..."
        # Install per-pod identities into the namespace
        helm install --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
            --namespace $NAMESPACE
        echo "Per pod identity support installed."
    fi

    # Install aiiot/azure-industrial-iot Helm chart
    echo "Install Helm chart from $helm_chart_location into $NAMESPACE..."
    helm install --atomic azure-industrial-iot $helm_chart_location \
        --namespace $NAMESPACE \
        --timeout 30m0s $extra_settings \
        --set image.tag=$IMAGES_TAG \
        --set loadConfFromKeyVault=true \
        --set azure.keyVault.uri=$KEY_VAULT_URI \
        --set azure.tenantId=$TENANT_ID \
        --set externalServiceUrl="https://$SERVICES_HOSTNAME" \
        --set deployment.microServices.engineeringTool.enabled=false \
        --set deployment.microServices.telemetryCdmProcessor.enabled=false \
        --set deployment.ingress.enabled=true \
        --set deployment.ingress.annotations."kubernetes\.io\/ingress\.class"=nginx \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/affinity"=cookie \
        --set deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-name"=affinity \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-expires"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/session-cookie-max-age"=14400 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-read-timeout"=3600 \
        --set-string deployment.ingress.annotations."nginx\.ingress\.kubernetes\.io\/proxy-send-timeout"=3600 \
        --set deployment.ingress.annotations."cert-manager\.io\/cluster-issuer"=letsencrypt-prod \
        --set deployment.ingress.tls[0].hosts[0]=$SERVICES_HOSTNAME \
        --set deployment.ingress.tls[0].secretName=tls-secret \
        --set deployment.ingress.hostName=$SERVICES_HOSTNAME
fi

echo "Done"
# -------------------------------------------------------------------------------
