#!/bin/bash

# Define the version of the packages
VERSION=${VERSION:-1.0.18}

# Define the list of remote machines
MACHINES=("192.168.2.10" "192.168.2.11" "192.168.2.12")

# Define the list of packages to be deployed
PACKAGES=("serviceradar-agent" "serviceradar-poller")

# Loop through each machine and deploy the packages
for MACHINE in "${MACHINES[@]}"; do
    echo "Deploying to $MACHINE..."

    # SCP the packages to the remote machine
    for PACKAGE in "${PACKAGES[@]}"; do
        scp "release-artifacts/${PACKAGE}_${VERSION}.deb" root@$MACHINE:~/
    done

    # SSH into the machine and install the packages
    for PACKAGE in "${PACKAGES[@]}"; do
        ssh root@$MACHINE "dpkg -i ~/${PACKAGE}_${VERSION}.deb"
    done

    echo "Deployment to $MACHINE completed."
done

echo "All deployments completed."
