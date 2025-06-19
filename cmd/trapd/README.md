# serviceradar-trapd

`serviceradar-trapd` is an asynchronous SNMP trap receiver for the ServiceRadar platform. It listens for traps and publishes them to NATS JetStream in JSON format.

## Configuration

Create a JSON file with the following fields:

```json
{
  "listen_addr": "0.0.0.0:162",
  "nats_url": "nats://127.0.0.1:4222",
  "subject": "snmp.traps"
}
```

Optionally enable TLS by adding a `security` section:

```json
{
  "listen_addr": "0.0.0.0:162",
  "nats_url": "nats://127.0.0.1:4222",
  "subject": "snmp.traps",
  "security": {
    "cert_file": "/etc/serviceradar/certs/trapd.pem",
    "key_file": "/etc/serviceradar/certs/trapd-key.pem",
    "ca_file": "/etc/serviceradar/certs/root.pem"
  }
}
```

Run the service with:

```sh
serviceradar-trapd --config trapd.json
```
