#!/usr/bin/env bash

# -------------------------------------------------------------------------------
set -e
# set -x

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
SERVICES_HOSTNAME=
SERVICES_APP_ID=
#SERVICES_APP_SECRET= # allow passing from environment
#DOCKER_PASSWORD= # allow passing from environment

# -------------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace)            NAMESPACE="$2" ;;
        --aksCluster)           AKS_CLUSTER="$2" ;;
        --resourceGroup)        RESOURCE_GROUP="$2" ;;
        --loadBalancerIp)       LOAD_BALANCER_IP="$2" ;;
        --publicIpDnsLabel)     PUBLIC_IP_DNS_LABEL="$2" ;;
        --helmRepoUrl)          HELM_REPO_URL="$2" ;;
        --helmChartName)        HELM_CHART_NAME="$2" ;;
        --helmChartVersion)     HELM_CHART_VERSION="$2" ;;
        --imagesNamespace)      IMAGES_NAMESPACE="$2" ;;
        --imagesTag)            IMAGES_TAG="$2" ;;
        --dockerServer)         DOCKER_SERVER="$2" ;;
        --dockerUser)           DOCKER_USER="$2" ;;
        --dockerPassword)       DOCKER_PASSWORD="$2" ;;
        --keyVaultUri)          KEY_VAULT_URI="$2" ;;
        --servicesHostname)     SERVICES_HOSTNAME="$2" ;;
        --tenant)               TENANT_ID="$2" ;;
        --role)                 ROLE="$2" ;;
        --servicesAppId)        SERVICES_APP_ID="$2" ;;
        --servicesAppSecret)    SERVICES_APP_SECRET="$2" ;;
    esac
    shift
done

# -------------------------------------------------------------------------------
if [[ -n "$HELM_CHART_NAME" ]]; then
    HELM_CHART_NAME="azure-industrial-iot"
fi
if [[ -n "$ROLE" ]]; then
    ROLE="AzureKubernetesServiceClusterUserRole"
fi
if [[ -n "$NAMESPACE" ]]; then
    NAMESPACE="azure-industrial-iot"
fi

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
echo "SERVICES_HOSTNAME=$SERVICES_HOSTNAME"
echo "SERVICES_APP_ID=$SERVICES_APP_ID"

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
echo "Install ingress-nginx/ingress-nginx Helm chart..."
kubectl create namespace ingress-nginx

# Install ingress-nginx/ingress-nginx Helm chart
helm install --atomic ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
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

# -------------------------------------------------------------------------------
# Create cert-manager namespace
echo "Install jetstack/cert-manager Helm chart..."
kubectl create namespace cert-manager

# Install jetstack/cert-manager Helm chart
helm install --atomic cert-manager jetstack/cert-manager \
    --namespace cert-manager \
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

# -------------------------------------------------------------------------------
# Create namespace
echo "Install aad-pod-identity Helm chart..."
kubectl create namespace $NAMESPACE

# Install per-pod identities into the namespace
helm install --atomic aad-pod-identity aad-pod-identity/aad-pod-identity \
    --namespace $NAMESPACE
echo "Per pod identity support installed."

# -------------------------------------------------------------------------------
# Install azure iiot services chart

if [[ -z "$HELM_REPO_URL" ]] ; then
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
    helm_chart_location="./aiiot"
    echo "Helm chart $chart downloaded."
else
    # add the repo
    echo "Configure Helm chart repository configured..."
    helm repo add aiiot $HELM_REPO_URL
    helm repo update
    helm_chart_location="aiiot/$HELM_CHART_NAME"
    echo "Install $HELM_REPO_URL/$HELM_CHART_NAME Helm chart..."
fi

extra_settings=""
if [[ -n "$SERVICES_APP_ID" ]] ; then
    extra_settings=$extra_settings' --set azure.auth.servicesApp.appId="'$SERVICES_APP_ID'"'
    extra_settings=$extra_settings' --set azure.auth.servicesApp.secret="'$SERVICES_APP_SECRET'"'
fi

# Install aiiot/azure-industrial-iot Helm chart
helm install --atomic azure-industrial-iot $helm_chart_location  \
    --namespace $NAMESPACE \
    --version $HELM_CHART_VERSION --timeout 30m0s $extra_settings \
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

echo "Done"
# -------------------------------------------------------------------------------
