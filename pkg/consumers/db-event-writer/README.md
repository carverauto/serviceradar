# db-event-writer

`db-event-writer` consumes processed event messages from NATS JetStream and writes them to a Timeplus Proton table. The consumer expects CloudEvents formatted JSON and stores the `_remote_addr` value as the device ID.

```
serviceradar-db-event-writer --config db-event-writer.json
```
