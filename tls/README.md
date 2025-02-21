# gRPC mTLS setup

## Install cfssl

It's used for generating X509 certificates

```
go install github.com/cloudflare/cfssl/cmd/...@latest
```

## Create root CA

```
cfssl selfsign -config cfssl.json --profile rootca "Dev Testing CA" csr.json | cfssljson -bare root
```

you will get 3 files:

- root.csr ROOT CA CSR(you may don't need it)
- root-key.pem ROOT CA key
- root.pem ROOT CA certificate

the `cfssl.json` here is a configuration file for cfssl, if you would like use your own `cfssl.json` and `csr.json`, 
please check out the [cfssl](https://github.com/cloudflare/cfssl) documentation for more details.

## Create certificates for server and client

```
cfssl genkey csr.json | cfssljson -bare server
cfssl genkey csr.json | cfssljson -bare client
```

you will get 4 files:

- server.csr Server CSR
- server-key.pem Server key
- client.csr Client CSR
- client-key.pem Client key

the CSR files will be used for signing a new certificate

## Sign the certificates

```
cfssl sign -ca root.pem -ca-key root-key.pem -config cfssl.json -profile server server.csr | cfssljson -bare server
cfssl sign -ca root.pem -ca-key root-key.pem -config cfssl.json -profile client client.csr | cfssljson -bare client
```

you will get server and client certificates

- server.pem
- client.pem

TODO: finish