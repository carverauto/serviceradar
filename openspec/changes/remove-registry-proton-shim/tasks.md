## 1. Registry compatibility removal
- [x] 1.1 Inventory `pkg/registry` usages of `db.Conn` (Query/QueryRow/Exec/PrepareBatch) and outline the SQL that needs `$n` placeholder rewrites.
- [x] 1.2 Introduce CNPG helpers in `pkg/db` (e.g., `InsertServiceRegistrationEvent`, `QueryRegistryRows`) so registry callers can share batching/error handling without rolling their own `pgx` plumbing.
- [x] 1.3 Update every registry query/write to call the new helpers (or `ExecCNPG`/`QueryCNPGRows`) with `$n` placeholders, ensuring tests cover the new code paths.
- [x] 1.4 Delete `DB.Conn`, `CompatConn`, and the associated shim errors; regenerate mocks so the `Service` interface no longer exposes Proton-era methods.

## 2. Documentation/tests
- [x] 2.1 Refresh `pkg/db/interfaces.go` comments (and any developer docs) to describe the CNPG responsibilities instead of Timeplus Proton.
- [x] 2.2 Extend registry unit tests (and integration tests if needed) to validate the pgx-based implementations, including service event inserts and purge/delete flows.
