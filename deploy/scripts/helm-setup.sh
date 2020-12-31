#!/usr/bin/env bash

################################################################################
#
# The script does the following:
#   1. Install Azure CLI
#   2. Install kubectl
#   3. Install Helm
#   4. Install ingress-nginx/ingress-nginx Helm chart
#   5. Install jetstack/cert-manager Helm chart
#   6. Install aad-pod-identity Helm chart
#   6. Install <repo>/azure-industrial-iot Helm chart
#
################################################################################

set -e
set -x

CWD=$(pwd)

RESOURCE_GROUP=
NAMESPACE=azure-industrial-iot
AKS_CLUSTER=
ROLE=
LOAD_BALANCER_IP=
PUBLIC_IP_DNS_LABEL=
HELM_REPO_URL=
HELM_CHART_VERSION=
IMAGE_TAG=
IMAGE_NS=
TENANT_ID=
KEY_VAULT_URI=
SERVICES_HOSTNAME=

# ==============================================================================

while [ "$#" -gt 0 ]; do
    case "$1" in
        --namespace)                    NAMESPACE="$2" ;;
        --resource_group)               RESOURCE_GROUP="$2" ;;
        --aks_cluster)                  AKS_CLUSTER="$2" ;;
        --role)                         ROLE="$2" ;;
        --load_balancer_ip)             LOAD_BALANCER_IP="$2" ;;
        --public_ip_dns_label)          PUBLIC_IP_DNS_LABEL="$2" ;;
        --helm_repo_url)                HELM_REPO_URL="$2" ;;
        --helm_chart_version)           HELM_CHART_VERSION="$2" ;;
        --image_tag)                    IMAGE_TAG="$2" ;;
        --image_ns)                     IMAGE_NS="$2" ;;
        --tenant_id)                    TENANT_ID="$2" ;;
        --key_vault_uri)                KEY_VAULT_URI="$2" ;;
        --services_hostname)            SERVICES_HOSTNAME="$2" ;;
    esac
    shift
done

# ==============================================================================

# Go to home.
cd ~

# Install utilities
apk update
apk add gettext

# Install kubectl
az aks install-cli

# Install Helm
az acr helm install-cli --client-version "3.3.4" -y

# Install `kubectl` and connect to the AKS cluster
az aks install-cli

# Get AKS admin credentials
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER --overwrite-existing --admin 

# Configure omsagent
kubectl apply -f "$CWD/omsagent.yaml"

# Add Helm repos
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add aad-pod-identity https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts
helm repo add aiiot $HELM_REPO_URL
helm repo update

# Create ingress-nginx namespace
kubectl create namespace ingress-nginx

# Install ingress-nginx/ingress-nginx Helm chart
helm install --atomic ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --version 3.12.0 --timeout 30m0s \
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

# Create cert-manager namespace
kubectl create namespace cert-manager

# Install jetstack/cert-manager Helm chart
helm install --atomic cert-manager jetstack/cert-manager --namespace cert-manager --version v1.1.0 --timeout 30m0s \
    --set installCRDs=true

# Create Let's Encrypt ClusterIssuer
n=0
iterations=20
until [[ $n -ge $iterations ]]
do
    kubectl apply -f "$CWD/letsencrypt.yaml" && break
    n=$[$n+1]

    echo "Trying to create Let's Encrypt ClusterIssuer again in 15 seconds"
    sleep 15
done

if [[ $n -eq $iterations ]]; then
    echo "Failed to create Let's Encrypt ClusterIssuer"
    exit 1
fi

# Create $NAMESPACE namespace
kubectl create namespace $NAMESPACE

# Install per-pod identities into the namespace
helm install aad-pod-identity aad-pod-identity/aad-pod-identity --namespace $NAMESPACE

# Install aiiot/azure-industrial-iot Helm chart
helm install --atomic azure-industrial-iot aiiot/azure-industrial-iot --namespace $NAMESPACE --version $HELM_CHART_VERSION --timeout 30m0s \
    --set image.tag=$IMAGE_TAG \
    --set loadConfFromKeyVault=true \
    --set azure.tenantId=$TENANT_ID \
    --set azure.keyVault.uri=$KEY_VAULT_URI \
    --set externalServiceUrl="https://$SERVICES_HOSTNAME" \
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
