#!/bin/bash -ex

for group in $(az group list --query "[?starts_with(name, 'testgroup')].name" -o tsv | tr -d '\r'); do
    echo "deleting $group ..."
    az group delete -g $group -y
done