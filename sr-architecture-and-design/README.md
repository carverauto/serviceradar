![NATS](large-logo.png)

# ServiceRadar Architecture And Design

This repository captures Architecture, Design Specifications and Feature Guidance for the NATS ecosystem.
## 1.0.27

| Index                   | Tags                             | Description                     |
|-------------------------|----------------------------------|---------------------------------|
| [ADR-01](adr/ADR-01.md) | serviceradar, kv, config, 1.0.28 | KV-based Configuration          |

## When to write an ADR

We use this repository in a few ways:

1. Design specifications where a single document captures everything about a feature, examples are ADR-1, ...
1. Guidance on conventions and design such as ADR-6 which documents all the valid naming rules
1. Capturing design that might impact many areas of the system such as ADR-2 (Missing)

We want to move away from using these to document individual minor decisions, moving instead to spec like documents that are living documents and can change over time. Each capturing revisions and history.

## Template

Please see the [template](adr-template.md). The template body is a guideline. Feel free to add sections as you feel appropriate. Look at the other ADRs for examples. However, the initial Table of metadata and header format is required to match.

After editing / adding a ADR please run `go run main.go > README.md` to update the embedded index. This will also validate the header part of your ADR.