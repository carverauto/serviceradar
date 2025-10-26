#!/bin/bash

set -e

bb=$(tput bold)
nn=$(tput sgr0)


NAMESPACE=${SPIRE_NAMESPACE:-demo}

echo "${bb}Creating registration entry for the node in namespace ${NAMESPACE}...${nn}"
kubectl exec -n "${NAMESPACE}" spire-server-0 -- \
    /opt/spire/bin/spire-server entry create \
    -node  \
    -spiffeID "spiffe://carverauto.dev/ns/${NAMESPACE}/sa/spire-agent" \
    -selector k8s_sat:cluster:carverauto-cluster \
    -selector "k8s_sat:agent_ns:${NAMESPACE}" \
    -selector k8s_sat:agent_sa:spire-agent
