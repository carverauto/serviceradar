---
title: SRQL Runtime
---

# SRQL Runtime

SRQL is embedded in `web-ng` and runs in-process via Rust (Rustler/NIF). There is no separate SRQL microservice to deploy.

## Operational Notes

- SRQL queries execute within the web runtime and read from CNPG.
- SRQL streaming endpoints are served by `web-ng` (make sure your ingress/proxy supports WebSockets and large responses).

For the language syntax and examples, see [SRQL Reference](./srql-language-reference.md).

