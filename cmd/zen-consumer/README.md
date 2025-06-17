# serviceradar-zen-consumer

`serviceradar-zen-consumer` listens to a JetStream consumer and evaluates each message using the [gorules/zen](https://github.com/gorules/zen) decision engine.

## Configuration

Create a JSON file with the following fields:

```json
{
  "nats_url": "nats://127.0.0.1:4222",
  "stream_name": "events",
  "consumer_name": "zen-consumer",
  "subjects": ["events.syslog"],
  "decision_key": "example-decision",
  "agent_id": "agent-01",
  "kv_bucket": "serviceradar-kv",
  "result_subject": "events.processed"
}
```

Decision rules are loaded from the KV store using the following key pattern:

```
agents/<agent-id>/<stream-name>/<subject>/<decision_key>.json
```

Ensure the subject specified in `result_subject` is part of a JetStream stream
so processed results are persisted. For example, create a stream that includes
`events.processed` before running the consumer.

Optionally add TLS settings:

```json
{
  "nats_url": "nats://127.0.0.1:4222",
  "stream_name": "events",
  "consumer_name": "zen-consumer",
  "subjects": ["events.syslog"],
  "decision_key": "example-decision",
  "agent_id": "agent-01",
  "kv_bucket": "serviceradar-kv",
  "result_subject": "events.processed",
  "security": {
    "cert_file": "/etc/serviceradar/certs/zen-consumer.pem",
    "key_file": "/etc/serviceradar/certs/zen-consumer-key.pem",
    "ca_file": "/etc/serviceradar/certs/root.pem"
  }
}
```

## Building and Running

```bash
cargo build --release -p serviceradar-zen-consumer
./target/release/serviceradar-zen-consumer --config zen-consumer.json
```
