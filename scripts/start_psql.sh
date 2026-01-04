#!/bin/sh

set -a; source ~/serviceradar/.env; set +a

export PGHOSTADDR=127.0.0.1
export PGHOST=cnpg
export PGPORT=$CNPG_PORT
export PGDATABASE=$CNPG_DATABASE
export PGUSER=$CNPG_USERNAME
export PGPASSWORD=$CNPG_PASSWORD
export PGSSLMODE=verify-full
export PGSSLROOTCERT=$CNPG_CERT_DIR/root.pem
export PGSSLCERT=$CNPG_CERT_FILE
export PGSSLKEY=$CNPG_KEY_FILE

psql
