# Migration Guide: Schema-Scoped Instance

This guide explains how to update code for the final schema-scoped model. Isolation
is enforced by PostgreSQL search_path; no schema context is passed in
application code.

## Overview

- Remove explicit schema context options from Ash operations.
- Remove schema enumeration helpers and any cross-schema iteration.
- Use `SystemActor.system/1` for background operations.
- Control Plane owns account provisioning and cross-account operations.

## Pattern 1: Schema-Scoped Ash Operations

```elixir
actor = SystemActor.system(:collector_controller)
packages = Ash.read!(query, actor: actor)
```

## Pattern 2: Cross-Schema Operations

Delete cross-schema helpers. Instances operate only on their own schema.
Cross-account operations live in the Control Plane.

## Pattern 3: AshAuthentication JWT Verification

AshAuthentication may still use internal schema handling for token verification.
Do not add any new explicit schema context handling in application code.
