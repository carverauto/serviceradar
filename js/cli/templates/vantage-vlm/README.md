# __PACK_NAME__

Apache-2.0 ServiceRadar Vantage Solution Pack v2 (`__PACK_ID__`) using the
Ramp 1 declarative `camera_vlm` runner for synthetic camera `Gate West 01`
(plates `SR-0100`, `TEST-742`).

## Quickstart

```bash
serviceradar-cli vantage validate .
serviceradar-cli vantage dev --fixture fixtures/synthetic_frame.json --json
serviceradar-cli pack build . --refresh-files
```
