# __PACK_NAME__ (Rust Vantage Worker)

Apache-2.0 ServiceRadar Vantage Solution Pack v2 (`__PACK_ID__`) with an
external Rust worker (`__CAPABILITY__`) built against `serviceradar-vantage-sdk`
and automatic Ramp 1 `camera_vlm` fallback.

## Quickstart

```bash
serviceradar-cli vantage validate .
serviceradar-cli vantage dev --fixture fixtures/synthetic_frame.json --json
serviceradar-cli pack build . --refresh-files
```
