## 1. Implementation
- [x] 1.1 Add shared configuration for the canonical AGE graph name (default `platform_graph`) in core-elx and SRQL.
- [x] 1.2 Update core-elx AGE helpers and topology projection to use the canonical graph name.
- [x] 1.3 Update SRQL graph query path and fixtures/tests to use the canonical graph name.
- [x] 1.4 Add an Elixir migration to create the canonical graph (legacy graphs remain untouched).
- [x] 1.5 Ensure startup migrations grant USAGE/ALL privileges on the canonical graph schema to the application role.
- [x] 1.6 Add/adjust tests to confirm graph upserts succeed without schema permission errors.
