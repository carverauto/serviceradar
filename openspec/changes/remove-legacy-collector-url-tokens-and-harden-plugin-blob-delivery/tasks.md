## 1. Implementation
- [x] 1.1 Remove the legacy collector enrollment GET routes and query-token controller flow.
- [x] 1.2 Move plugin blob upload/download endpoints to header/body token transport and update helper APIs.
- [x] 1.3 Remove bearer plugin blob URLs from generated agent config and any related UI surfaces.
- [x] 1.4 Update affected docs and operator/developer instructions.

## 2. Verification
- [x] 2.1 Add or update focused tests for collector route removal and plugin blob token transport.
- [x] 2.2 Run relevant Go/Elixir compile and targeted test commands.
