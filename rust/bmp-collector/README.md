# serviceradar-bmp-collector

`serviceradar-bmp-collector` is the ServiceRadar BMP ingress collector built on top of
`arancini-lib`.

Pipeline:

`routers (BMP TCP) -> serviceradar-bmp-collector -> NATS JetStream (arancini.updates.>)`

The collector:
- accepts live BMP TCP sessions,
- decodes messages via `arancini-lib::process_bmp_message`,
- publishes JSON updates on `arancini.updates.<router>.<peer_asn>.<afi_safi>`.

## Config

Default config path: `rust/bmp-collector/bmp-collector.json`

Key settings:
- `listen_addr`: BMP TCP listener (`0.0.0.0:4000`)
- `nats_url`: NATS server URL
- `nats_creds_file`: optional `.creds` file path
- `stream_name`: JetStream stream (default `ARANCINI_CAUSAL`)
- `subject_prefix`: publish prefix (default `arancini.updates`)

## Run

```bash
cargo run -p serviceradar-bmp-collector -- --config rust/bmp-collector/bmp-collector.json
```
