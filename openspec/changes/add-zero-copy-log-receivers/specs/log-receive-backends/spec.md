## ADDED Requirements

### Requirement: Portable production receive
The collector SHALL support conventional UDP/TCP receive in Kubernetes, bare-metal and VM deployments with the same normalization, provenance and publication contract as accelerated backends.

#### Scenario: Hardware acceleration is absent
- **WHEN** automatic selection finds no usable receive zero-copy backend
- **THEN** a supported conventional backend operates
- **AND** the chosen backend and fallback reason are observable

### Requirement: Verified acceleration
Explicit AF_XDP or ZC Rx configuration SHALL verify the required kernel/device operation and SHALL fail clearly if the selected zero-copy mechanism cannot operate.

#### Scenario: A driver advertises unsupported configuration
- **WHEN** zero-copy registration or binding fails despite a capability flag
- **THEN** explicit zero-copy startup fails rather than silently using copying mode

### Requirement: Bounded receive-buffer lifetime
Receive leases SHALL remain valid while referenced by parsing or normalization and SHALL be released after encoding without waiting for durable publish retries.

#### Scenario: JetStream stops acknowledging
- **WHEN** encoded batches await publish ACKs
- **THEN** their original receive-buffer leases are not retained solely for those retries
- **AND** bounded admission exposes backpressure or UDP loss

### Requirement: Scoped Kubernetes privileges
The deployment SHALL declare per-backend device, capability and seccomp needs without relaxing security for unrelated workloads.

#### Scenario: A restricted pod denies io_uring
- **WHEN** the kernel supports io_uring but the pod policy denies its syscalls
- **THEN** diagnosis distinguishes policy denial from missing kernel support
- **AND** any policy change is scoped to the collector deployment
