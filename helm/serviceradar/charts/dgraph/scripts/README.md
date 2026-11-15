# Scripts

Here are some scripts that may be useful for generating helm chart values for use with `dgraph` helm chart.

## make_tls_secrets.sh

For intructions run `./make_tls_secrets.sh --help`

As an example:

```bash
./make_tls_secrets.sh \
  --release "my-release" \
  --namespace "default" \
  --replicas 3 \
  --extra "ratel.example.com,alpha.example.com" \
  --client "dgraphuser" \
  --zero
```

You can verify Dgraph Alpha certificates and keys with:

```bash
## verify certificates and keys
dgraph cert ls --dir ./dgraph_tls/alpha
## verify list of addresses supported
dgraph cert ls --dir ./dgraph_tls/alpha | awk -F: '/Hosts/{gsub(/\[ ]+/, "", $2); print $2}' | tr , '\n'
```

You can verify Dgraph Zero certificates and keys with:

```bash
## verify certificates and keys
dgraph cert ls --dir ./dgraph_tls/zero
## verify list of addresses supported
dgraph cert ls --dir ./dgraph_tls/zero | awk -F: '/Hosts/{gsub(/\[ ]+/, "", $2); print $2}' | tr , '\n'
```
