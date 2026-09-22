# Schema template manifest v1

`//build/schema_template:manifest` generates the declared artifact
`build/schema_template/manifest.json`. Consumers depend on that label through
`data` or a rule input, then resolve it in runfiles. Do not read the Bazel output
tree or check in a generated copy. No runtime consumer is switched by this target.

The generator uses Python's standard library and reads only paths passed by the
Starlark action. The action separates migrations, baseline SQL, baseline metadata,
application helpers, and construction inputs. Input paths in the JSON are relative
to the repository, never physical action paths. Branches, credentials, run IDs,
timestamps, and ambient environment values are not inputs.

## Wire contract

The artifact is UTF-8 JSON with sorted object keys, compact separators, ASCII
escaping, and no trailing newline. Its fields are:

- `version`: integer `1`.
- `inputs`: objects containing `path` and lowercase hexadecimal `sha256`, sorted
  by path. Each hash covers the complete, unchanged file bytes.
- `migration_versions`: unique positive signed-64-bit integers, numerically sorted.
- `covered_migrations`: `included_through` from baseline metadata and `digest` of
  only the migration input pairs at or below that version.
- `digest`: lowercase hexadecimal SHA-256 of the framing below.
- `database`: `sr_tpl_` followed by the first 48 characters of `digest` (55 total).

Digest verification does **not** serialize JSON again. Feed SHA-256 these bytes:

1. ASCII `serviceradar.schema-template.v1` followed by one NUL byte.
2. Input count encoded as an unsigned 64-bit big-endian integer.
3. For each input pair sorted by path: UTF-8 path byte length as an unsigned
   64-bit big-endian integer, the path bytes, and its hash decoded to 32 raw bytes.

`covered_migrations.digest` uses exactly the same framing and the selected
migration pairs, but domain `serviceradar.schema-template.covered-migrations.v1`
followed by NUL. An empty covered set still hashes its domain and zero count.
Paths are restricted to ASCII letters, digits, underscore, hyphen, period, and
slash; absolute paths and empty, `.` or `..` components are rejected. Thus path
ordering has identical bytewise semantics across Python, Rust, and Elixir.

Cross-language test vectors (synthetic inputs):

- Main domain, no inputs:
  `81cf2ce0dad0ea71bb66e395fb5844be25d5a4f7356af833a3e25aaf4cdf30a4`.
- Main domain, one pair with path `a` and SHA-256 hex `ab` repeated 32 times:
  `8aca3ff3506190cb915fa9319e4c949747914d368cb3acaadc9258b70bfecc4d`.
- Covered domain, no inputs:
  `3698701e9671da686440c4c88fefeb9353a9fd0c649130ca7bb62b2b578ed630`.

The main digest commits to every input's path and contents. Migration versions
and baseline coverage are derived from those inputs. The v1 domain binds this
interpretation. The manifest's own output is never one of its inputs. The
generator source and rule are construction inputs so changing construction or
identity logic invalidates reuse.

## Input ownership and limits

Core owns additive `schema_template_baseline_sql`,
`schema_template_baseline_metadata`, `schema_template_helpers`, and
`schema_template_configuration` filegroups. Its existing `migrations` group owns
the migration inventory. The helper inventory explicitly includes SchemaBootstrap,
SchemaSql, Repo, startup/Mix entry points, and lifecycle loaders. Migrations use
Ecto and Oban with dependency versions captured in the core `mix.lock`. New
application helpers called by migrations must be added to the helper inventory.

Rust owns `//rust/integration-db:schema_template_construction_inputs`, including
its registry SQL and construction sources. This must be a source-only filegroup:
depending on the manifest from it would form a cycle. Main owns `policy.json`,
whose construction mode and compatibility policy are hashed verbatim. The
manifest generator does not interpret that policy or inspect a running fixture;
runtime consumers must validate it before reuse. Root Cargo manifests and lockfile
capture Rust construction dependency changes conservatively.

The existing baseline supplies an SQL checksum and `included_through`, but no
historical migration content provenance. The generator validates the declared SQL
against that checksum. It does not prove migration equivalence or assert that an
edited covered migration was executed in the baseline. The covered digest records
current source identity for future registry comparisons only. Cold construction
uses the separately owned policy's `full_replay` mode; baseline bytes still
invalidate identity. Publication must compare the full digest, not merely the
truncated database name, to reject identifier collisions.

## Tests

`bazel test -c opt --config=remote //build/schema_template:manifest_test
//build/schema_template:manifest_artifact_test` runs synthetic unit contracts and
a declared-artifact/runfiles contract without opening a database. All unit fixtures
are invented in temporary directories. The artifact test exercises the actual
Starlark action and requires the source-only construction inventory and policy.
