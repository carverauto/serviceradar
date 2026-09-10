"""Guard the current, non-persisting edge-record admission boundary (task 1.5-k).

Scope: Go edgerecord/projection and all non-generated core Elixir modules. A
direct record reference or decoder consumer in core outside the audited set
requires accounting review. The current Go boundary consists of validators;
neither it nor the projection rule has database dependencies or mutation calls.

This is a lexical change detector, not a whole-program effect proof. Reflection,
dynamic dispatch, callbacks supplied by a future caller, aliases hiding a type,
new Go ingress packages and other services are outside its reach. Runtime
integration MUST extend this guard and account for its synchronous transaction;
the absence of that integration is not evidence that future ledger/outbox rows
are free. Existing event_writer processors use a different contract and are not
counted here. All inspected files are declared Bazel inputs.
"""

from pathlib import Path
import re


GO_ROOTS = [Path("go/pkg/edge/edgerecord"), Path("go/pkg/edge/projection")]
ELIXIR_ROOT = Path("elixir/serviceradar_core/lib")
AUDITED_CORE = {
    "serviceradar/edge/wire_decode.ex",
    "serviceradar/edge/compression.ex",
    "serviceradar/edge/semantic_digest.ex",
    "serviceradar/edge/semantic_validate.ex",
    "serviceradar/edge/sweep_correlate.ex",
    "serviceradar/edge/record_validate.ex",
}
RECORD_REFERENCE = re.compile(r"\bEdgeRecordV1\b|\bdecode_record\s*\(")
DATABASE_DEPENDENCY = re.compile(
    r'"(?:database/sql|github\.com/(?:jackc|lib/pq|jmoiron/sqlx)[^"\n]*)"'
    r"|\b(?:Ecto|Postgrex|ServiceRadar\.Repo)\b"
)
MUTATION_CALL = re.compile(
    r"\b(?:Repo|Ash)\.(?:insert|insert_all|update|update_all|delete|delete_all|create|destroy|bulk_create|bulk_update|bulk_destroy|transaction)\b"
    r"|\.(?:ExecContext|Exec|BeginTx)\s*\("
)


def main():
    failures = []
    inspected = []
    for root in GO_ROOTS:
        files = sorted(p for p in root.glob("*.go") if not p.name.endswith("_test.go"))
        if not files:
            failures.append(f"missing declared source inputs: {root}")
        inspected.extend(files)

    core_files = sorted(
        p
        for p in ELIXIR_ROOT.rglob("*.ex")
        if "proto" not in p.parts and "event_writer" not in p.parts
    )
    if not core_files:
        failures.append("missing declared core source inputs")
    actual_core = set()
    for path in core_files:
        if RECORD_REFERENCE.search(path.read_text()):
            actual_core.add(str(path.relative_to(ELIXIR_ROOT)))
            inspected.append(path)
    if actual_core != AUDITED_CORE:
        failures.append(
            f"record admission inventory changed: added={actual_core - AUDITED_CORE}, "
            f"removed={AUDITED_CORE - actual_core}; audit synchronous row accounting"
        )

    # The projection peer itself must remain a pure enumerator, too.
    peer = ELIXIR_ROOT / "serviceradar/edge/projection_rows.ex"
    if not peer.is_file():
        failures.append(f"missing declared projection peer: {peer}")
    else:
        inspected.append(peer)
    for path in inspected:
        source = path.read_text()
        if DATABASE_DEPENDENCY.search(source) or MUTATION_CALL.search(source):
            failures.append(f"database dependency/mutation entered {path}; enumerate its rows")

    if failures:
        raise SystemExit("\n".join(failures))
    print(f"Audited {len(inspected)} source files: no direct database dependencies or mutation calls detected.")


if __name__ == "__main__":
    main()
