#!/bin/bash
mkdir certs
cd certs

openssl req -x509 -out localhost.crt -keyout localhost.key \
  -newkey rsa:4096 -nodes -sha256 \
  -subj '/CN=localhost' -extensions EXT -config <( \
    printf "[dn]\nCN=localhost\n[req]\ndistinguished_name = dn\n[EXT]\nsubjectAltName=IP:127.0.0.1\nkeyUsage=digitalSignature\nextendedKeyUsage=serverAuth")
