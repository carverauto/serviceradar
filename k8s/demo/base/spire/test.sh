#!/bin/bash

set -e

bold=$(tput bold)
norm=$(tput sgr0)
red=$(tput setaf 1)
green=$(tput setaf 2)
yellow=$(tput setaf 3)

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

MINIKUBEPROFILE="SPIRE-SYSTEMS-TEST"
MINIKUBECMD="minikube -p ${MINIKUBEPROFILE}"
CHECKINTERVAL=1
if [ -n "${GITHUB_WORKFLOW}" ]; then
	CHECKINTERVAL=5
fi
TMPDIR=$(mktemp -d)
SERVERLOGS=${TMPDIR}/spire-server-logs.log

start_minikube() {
	# GH actions will start up minikube
	if [ -z "${GITHUB_WORKFLOW}" ]; then
		echo "${bold}Starting minikube... ${norm}"
		${MINIKUBECMD} start
		eval $(${MINIKUBECMD} docker-env)
	fi
}

tear_down_config() {
	kubectl delete namespace spire > /dev/null || true
}

stop_minikube() {
	# Don't stop the minikube inside of GH actions
	if [ -z "${GITHUB_WORKFLOW}" ]; then
		${MINIKUBECMD} stop > /dev/null || true
	fi
}

cleanup() {
	echo -n "${bold}Cleaning up... ${norm}"
	if [ ! -z "${SUCCESS}" ]; then
		# success. remove the tmp dir.
		rm -rf ${TMPDIR}
	fi
	tear_down_config
	stop_minikube
	echo "${green}ok${norm}."
}

# apply the k8s configuration
apply_server_config() {
	echo -n "${bold}Applying SPIRE server k8s configuration... ${norm}"
	kubectl apply -f ${DIR}/spire-namespace.yaml > /dev/null
	kubectl apply -f ${DIR}/server-account.yaml > /dev/null
	kubectl apply -f ${DIR}/server-cluster-role.yaml > /dev/null
	kubectl apply -f ${DIR}/server-configmap.yaml > /dev/null
	kubectl apply -f ${DIR}/spire-bundle-configmap.yaml > /dev/null
	kubectl apply -f ${DIR}/server-statefulset.yaml > /dev/null
	kubectl apply -f ${DIR}/server-service.yaml > /dev/null
	echo "${green}ok.${norm}"
}

apply_agent_config() {
	echo -n "${bold}Applying SPIRE agent k8s configuration... ${norm}"
	kubectl apply -f ${DIR}/agent-account.yaml > /dev/null
	kubectl apply -f ${DIR}/agent-cluster-role.yaml > /dev/null
	kubectl apply -f ${DIR}/agent-configmap.yaml > /dev/null
	kubectl apply -f ${DIR}/agent-daemonset.yaml > /dev/null
	echo "${green}ok.${norm}"
}

wait_for_pod() {
	local prefix=$1
	local outvar=$2
	for i in $(seq 60); do
		echo -n "${bold}Checking ${prefix} pod status... ${norm}"
		local getpods=$(kubectl -n spire get pods 2>/dev/null | grep ${prefix} || true)
		if [ -z "${getpods}" ]; then
			echo "${yellow}NotFound${norm}."
			sleep ${CHECKINTERVAL}
			continue
		fi
		local podname=$(echo ${getpods} | awk '{print $1}')
		local podstatus=$(echo ${getpods} | awk '{print $3}')
		if [ "${podstatus}" != "Running" ]; then
			echo "${yellow}${podstatus}${norm}."
			sleep ${CHECKINTERVAL}
			continue
		fi
		echo "${green}Running (${podname})${norm}."
		# I'd rather use name binding, but macOS ships with Bash 3. Silly macOS.
		eval $outvar=\${podname}
		return
	done

	echo "${red}failed${norm}."
	echo "${red}FAILED: ${prefix} pod not running in time${norm}"
	exit -1
}

wait_for_server() {
	wait_for_pod spire-server SPIRE_SERVER_POD_NAME
}

wait_for_agent() {
	wait_for_pod spire-agent SPIRE_AGENT_POD_NAME
}

check_for_node_attestation() {
	# spin for 60 seconds, checking to see if the agent attests
	for i in $(seq 60); do
		sleep ${CHECKINTERVAL}
		echo -n "${bold}Checking for node attestation... ${norm}"
		kubectl -n spire logs ${SPIRE_SERVER_POD_NAME} > ${SERVERLOGS} || true
		if  grep -sxq -e ".*Agent attestation request completed.*k8s_sat.*" ${SERVERLOGS}; then
			echo "${green}ok${norm}."
			return
		fi
		echo "${yellow}nope${norm}."
	done

	echo "${red}FAILED: node attestation did not succeed in time.${norm}" >&2
	echo "${yellow}Log at ${SERVERLOGS}${norm}" >&2
	exit -1
}

trap cleanup EXIT
start_minikube
apply_server_config
wait_for_server
apply_agent_config
wait_for_agent
check_for_node_attestation

echo "${bold}Success.${norm}"
