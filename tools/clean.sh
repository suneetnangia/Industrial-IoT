#!/bin/bash -ex

for group in $(az group list --query "[?starts_with(name, 'testgroup')].name" -o tsv | tr -d '\r'); do
    echo "deleting resourcegroup $group ..."
    az group delete -g $group -y
done

for vault in $(az keyvault list-deleted --query "[?contains(properties.vaultId, 'resourceGroups/testgroup')].name" -o tsv | tr -d '\r'); do
    echo "deleting keyvault $vault ..."
    az keyvault purge --name $vault
done

