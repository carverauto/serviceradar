## ADDED Requirements

### Requirement: A benchmark that is not executed is not coverage
Every benchmark committed to this repository SHALL have a build target that EXECUTES it, and CI
SHALL run those targets. Compiling a benchmark SHALL NOT be treated as running it.

Go benchmarks are the specific hazard: `go test` compiles `Benchmark*` functions and skips them
unless `-bench` is passed, so a benchmark can pass review, appear in a file listing, and rot for
months while its package's tests are green. The same applies to any benchmark whose runner is a
script nobody invokes.

A benchmark runner that matches NO benchmark SHALL fail rather than report success. Matching
nothing and running nothing produce the same empty result, and the failure mode this requirement
exists to prevent is exactly a runner that reports success while executing nothing.

#### Scenario: A benchmark exists with no runner
- **WHEN** a package contains a benchmark that no build target executes
- **THEN** that SHALL be treated as an unmet requirement, not as existing coverage

#### Scenario: A benchmark filter matches nothing
- **WHEN** a benchmark target's filter selects no benchmark
- **THEN** the target SHALL fail rather than report success

### Requirement: Benchmark results are recorded before they are gated
CI SHALL record each benchmark run's results as a retrievable artifact. CI SHALL NOT fail a build
on a performance threshold until that benchmark's observed VARIANCE on the CI fleet has been
measured and stated.

A threshold chosen before the variance is known produces failures that are not regressions. The
predictable response is to mute the check, which leaves the project worse off than having no gate:
a muted gate still looks like protection on a dashboard.

#### Scenario: A regression threshold is proposed
- **WHEN** a change proposes failing the build on a benchmark threshold
- **THEN** it SHALL cite the measured variance of that benchmark on the CI fleet
- **AND** a threshold inside the noise band SHALL be rejected

### Requirement: A benchmark states what it does not measure
A benchmark SHALL state, next to its results, the stages it includes and the stages it OMITS, and
SHALL NOT be presented as a capacity figure unless it exercises the composed path.

A staged microbenchmark and a pipeline throughput figure answer different questions. A number
that omits extraction, decompression, signature verification, or trust resolution describes the
SHAPE of a cost, not what a deployment can ingest, and a figure without its conditions is a
number people quote.

#### Scenario: A microbenchmark is read as capacity
- **WHEN** a benchmark omits stages of the production path
- **THEN** its header SHALL name those omissions
- **AND** its result SHALL NOT be published as a records-per-second capacity figure

### Requirement: A benchmark measures the production entrypoint, not a private approximation
A benchmark of an ingest path SHALL drive the SAME entrypoint production drives. It SHALL NOT
introduce benchmark-only glue that reassembles the path out of internal parts.

A benchmark that assembles its own version of ingress creates a second model of the system, and
the second model is the one nothing in production calls. It will drift, and its numbers will
describe the drift rather than the system. This is the same defect as a benchmark nobody runs,
one layer up: it looks like measurement and measures something else.

A benchmark that covers only part of the path SHALL be NAMED for what it covers. A measurement
spanning extraction, decode, validation, signature verification, decompression, body validation,
correlation and cost enumeration -- but not the network, broker, consumer or database -- is a
COMPOSED INGRESS CPU benchmark. It SHALL NOT be called end-to-end, and its result SHALL NOT be
called deployment throughput.

#### Scenario: A benchmark needs a path that is not exposed
- **WHEN** measuring would require reaching past the production entrypoint into internal parts
- **THEN** the benchmark SHALL NOT be written against those parts
- **AND** the missing entrypoint SHALL be treated as the work to do first

#### Scenario: A partial measurement is named
- **WHEN** a benchmark omits the network, broker, consumer or database hops
- **THEN** it SHALL be called a composed ingress CPU benchmark
- **AND** its numbers SHALL NOT be presented as deployment throughput

### Requirement: Pipeline throughput is measured on the composed path
A pipeline throughput benchmark SHALL drive a record through the REAL path -- agent spool, mTLS
gRPC, gateway, JetStream publish acknowledgement, EventWriter, the idempotent database
transaction, and the resulting query -- and SHALL report records per second and hosts per second
together with the hardware and fixture that produced them.

IT SHALL NOT BE BUILT BEFORE THAT PATH IS GREEN. A throughput benchmark that stubs the hops which
do not yet exist measures its own stubs. Where a real dependency is available to the test
environment it SHALL be preferred over a mock, so the number describes the system rather than the
harness.

#### Scenario: The composed path is not yet available
- **WHEN** one or more hops of the pipeline are not yet implemented end to end
- **THEN** the throughput benchmark SHALL NOT be built against stubs for the missing hops
- **AND** the dependency SHALL be recorded rather than worked around

#### Scenario: A throughput figure is published
- **WHEN** a records-per-second figure is reported
- **THEN** it SHALL name the hardware, the fixture, and every stage included in the measurement
