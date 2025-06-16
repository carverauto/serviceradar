# serviceradar-trapd

`serviceradar-trapd` is an asynchronous SNMP trap receiver for the ServiceRadar platform. It listens for traps and publishes them to NATS JetStream in JSON format.

## Configuration

Create a JSON file with the following fields:

```json
{
  "listen_addr": "0.0.0.0:162",
  "nats_url": "nats://localhost:4222",
  "subject": "snmp.traps"
}
```

Run the service with:

```sh
serviceradar-trapd --config trapd.json
```
