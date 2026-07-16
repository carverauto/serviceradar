#!/bin/bash
set -e
umask 077

cat /etc/postgresql/certs/ca.crt > $PGDATA/ca.crt
cat /etc/postgresql/certs/server.crt > $PGDATA/server.crt
cat /etc/postgresql/certs/server.key > $PGDATA/server.key

cat >> "$PGDATA/postgresql.conf" <<-EOCONF
port = 5433
ssl = on
ssl_ca_file = 'ca.crt'
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
EOCONF

cat > "$PGDATA/pg_hba.conf" <<-EOCONF
# TYPE     DATABASE    USER           ADDRESS      METHOD           OPTIONS
local      all         $POSTGRES_USER              trust
host       all         startup_probe  0.0.0.0/0    trust
host       all         startup_probe  ::0/0        trust
hostssl    all         scram_user     0.0.0.0/0    scram-sha-256
hostssl    all         scram_user     ::0/0        scram-sha-256
hostssl    all         ssl_user       0.0.0.0/0    cert             clientcert=verify-full
hostssl    all         ssl_user       ::0/0        cert             clientcert=verify-full
host       all         scram_user     0.0.0.0/0    reject
host       all         scram_user     ::0/0        reject
host       all         ssl_user       0.0.0.0/0    reject
host       all         ssl_user       ::0/0        reject
EOCONF

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    SET password_encryption TO 'scram-sha-256';
    CREATE ROLE scram_user PASSWORD 'password' LOGIN;
    CREATE ROLE ssl_user LOGIN;
    CREATE ROLE startup_probe LOGIN;
EOSQL
