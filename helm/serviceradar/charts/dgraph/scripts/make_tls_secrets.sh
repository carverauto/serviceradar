#!/usr/bin/env bash

######
# main - runs the script
##########################
main() {
  check_environment
  parse_command $@
  create_certificates
  create_secret_value_file
}

######
# usage - print friendly usage statement
##########################
usage() {
  cat <<-USAGE 1>&2
Make TLS Secrets

Usage:
  $0 [FLAGS] --release [CHART_RELEASE_NAME]

Flags:
 -c, --client              Client certificate username, e.g. dgraphuser, backupuser
     --domain              Kubernetes internal domain name (default "cluster.local")
 -d, --debug               Enable debug in output
 -e, --extra               Additional domain names to support, e.g. external DNS name for an ingress
 -h, --help                Help for $0
 -n, --namespace           Kubernetes namespace (default "default")
 -r, --release             Helm Chart Release Name (required)
     --replicas            Number of Kubernetes replicas (default "3")
     --tls_dir             Path to top level TLS directory (default "./dgraph_tls")
 -z, --zero                Create certificates for zero as well
USAGE
}

######
# check_environment - verify dgraph binary exists
##########################
check_environment() {
  ## Check for dgraph command
  command -v dgraph > /dev/null || \
    { echo "[ERROR]: 'dgraph' command not not found" 1>&2; exit 1; }
}

######
# get_getopt - find GNU getopt or print error message
##########################
get_getopt() {
 unset GETOPT_CMD

 ## Check for GNU getopt compatibility
 if [[ "$(getopt --version)" =~ "--" ]]; then
   local SYSTEM="$(uname -s)"
   if [[ "${SYSTEM,,}" == "freebsd" ]]; then
     ## Check FreeBSD install location
     if [[ -f "/usr/local/bin/getopt" ]]; then
        GETOPT_CMD="/usr/local/bin/getopt"
     else
       ## Save FreeBSD Instructions
       local MESSAGE="On FreeBSD, compatible getopt can be installed with 'sudo pkg install getopt'"
     fi
   elif [[ "${SYSTEM,,}" == "darwin" ]]; then
     ## Check HomeBrew install location
     if [[ -f "/usr/local/opt/gnu-getopt/bin/getopt" ]]; then
        GETOPT_CMD="/usr/local/opt/gnu-getopt/bin/getopt"
     ## Check MacPorts install location
     elif [[ -f "/opt/local/bin/getopt" ]]; then
        GETOPT_CMD="/opt/local/bin/getopt"
     else
        ## Save MacPorts or HomeBrew Instructions
        if command -v brew > /dev/null; then
          local MESSAGE="On macOS, gnu-getopt can be installed with 'brew install gnu-getopt'\n"
        elif command -v port > /dev/null; then
          local MESSAGE="On macOS, getopt can be installed with 'sudo port install getopt'\n"
        fi
     fi
   fi
 else
   GETOPT_CMD="$(command -v getopt)"
 fi

 ## Error if no suitable getopt command found
 if [[ -z $GETOPT_CMD ]]; then
   printf "ERROR: GNU getopt not found.  Please install GNU compatible 'getopt'\n\n%s" "$MESSAGE" 1>&2
   exit 1
 fi
}


######
# parse_command - parse command line options using GNU getopt
##########################
parse_command() {
  get_getopt

  ## Parse Arguments with GNU getopt
  PARSED_ARGUMENTS=$(
    $GETOPT_CMD -o c:de:hn:r:z \
    --long client:,domain:,debug,extra:,help,namespace:,release:,replicas:,tls_dir:,zero \
    -n 'make_tls_secrets.sh' -- "$@"
  )
  if [ $? != 0 ] ; then usage; exit 1 ; fi
  eval set -- "$PARSED_ARGUMENTS"

  ## Defaults
  DEBUG="false"
  ZERO_ENABLED="false"
  NAMESPACE="default"
  REPLICAS=3
  TLS_DIR=dgraph_tls
  LOCAL_DOMAIN="cluster.local"

  ## Process Arguments
  while true; do
    case "$1" in
      -c | --client) CLIENT_NAME="$2"; shift 2 ;;
      --domain) LOCAL_DOMAIN="$2"; shift 2 ;;
      -d | --debug) DEBUG=true; shift ;;
      -e | --extra) EXTRA_LIST="$2"; shift 2 ;;
      -h | --help) usage; exit;;
      -n | --namespace) NAMESPACE="$2"; shift 2 ;;
      -r | --release) RELEASE="$2"; shift 2 ;;
      --replicas) REPLICAS="$2"; shift 2;;
      --tls_dir) TLS_DIR="$2"; shift 2 ;;
      -z | --zero) ZERO_ENABLED=true; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  ## Check required variable was set
  if [[ -z "$RELEASE" ]]; then
    printf "ERROR: Helm chart release name was not specified!!\n\n"
    usage
    exit 1
  fi
}

######
# get_node_list - create list of domain names for nodes based on replicas
##########################
get_node_list() {
  local LIST=()

  TYPE=${1:-"alpha"}

  [[ -z "$REPLICAS" ]] && \
    { echo "[ERROR]: Env var 'REPLICAS' not defined" 1>&2; exit 1; }
  [[ -z "$RELEASE" ]] && \
    { echo "[ERROR]: Env var 'RELEASE' not defined" 1>&2; exit 1; }
  [[ -z "$NAMESPACE" ]] && \
    { echo "[ERROR]: Env var 'NAMESPACE' not defined" 1>&2; exit 1; }
  [[ -z "$LOCAL_DOMAIN" ]] && \
    { echo "[ERROR]: Env var 'DOMAIN' not defined" 1>&2; exit 1; }

  ## Build List
  for (( IDX=0; IDX<REPLICAS; IDX++ )); do
    ## Add service FQDN for each dgraph pod
    LIST+=("$RELEASE-dgraph-$TYPE-$IDX.$RELEASE-dgraph-$TYPE-headless.$NAMESPACE.svc.$LOCAL_DOMAIN")
  done

  ## Add service FQDN for service
  LIST+=("$RELEASE-dgraph-$TYPE-headless.$NAMESPACE.svc.$LOCAL_DOMAIN")

  ## Output Comma Separated List
  local IFS=,; echo "${LIST[*]}"
}

######
# create_certificates - create TLS certs/keys for Alpha and optionally Zero for K8S system
##########################
create_certificates() {
  [[ -z "$TLS_DIR" ]] && \
    { echo "[ERROR]: Env var 'TLS_DIR' not defined" 1>&2; exit 1; }

  if [[ $DEBUG == "true" ]]; then
    set -ex
  else
    set -e
  fi

  ## Add optional client certificate for MutualTLS
  if ! [[ -z $CLIENT_NAME ]]; then
    CLIENT_OPT="--client $CLIENT_NAME"
  fi

  ## Build List of Zero nodes and Alpha nodes
  ALPHA_LIST=localhost,$(get_node_list alpha)
  ZERO_LIST=localhost,$(get_node_list zero)
  ## Append list of extra specified addresses
  if ! [[ -z $EXTRA_LIST ]]; then
    ALPHA_LIST=$ALPHA_LIST,$EXTRA_LIST
    ZERO_LIST=$ZERO_LIST,$EXTRA_LIST
  fi

  # Make Alpah Keys/Certs
  mkdir -p $TLS_DIR/alpha
  dgraph cert --nodes $ALPHA_LIST $CLIENT_OPT --dir $TLS_DIR/alpha

  # Make Zero Keys/Certs with rootCA and client keys/certs from Alpha dir
  if [[ $ZERO_ENABLED == "true" ]]; then
    mkdir -p $TLS_DIR/zero
    ## Copy Root CA to zero
    cp -f $TLS_DIR/alpha/ca.* $TLS_DIR/zero
    ## Copy Client Cert/Key to zero if client cert name specified
    [[ -z $CLIENT_NAME ]] || cp -f $TLS_DIR/alpha/client.${CLIENT_NAME}.* $TLS_DIR/zero
    ## Make Zero Keys/Cert
    dgraph cert --nodes $ZERO_LIST --dir $TLS_DIR/zero
  fi
}

######
# create_certificates - create TLS certs/keys for Alpha and optionally Zero for K8S system
##########################
create_secret_value_file() {
  [[ -z "$TLS_DIR" ]] && \
    { echo "[ERROR]: Env var 'TLS_DIR' not defined" 1>&2; exit 1; }


  cat <<-EOF > $TLS_DIR/secrets.yaml
alpha:
  tls:
    files:
$(for F in $TLS_DIR/alpha/*; do echo "      ${F##*/}: `cat $F | base64 | tr -d '\n'`"; done)
EOF

  if [[ $ZERO_ENABLED == "true" ]]; then
    cat <<-EOF >> $TLS_DIR/secrets.yaml
zero:
  tls:
    files:
$(for F in $TLS_DIR/zero/*; do echo "      ${F##*/}: `cat $F | base64 | tr -d '\n'`"; done)
EOF
  fi
}

main $@
