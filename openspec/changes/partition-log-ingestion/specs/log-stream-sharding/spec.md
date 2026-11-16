## ADDED Requirements

### Requirement: Independent stream ownership
Partitioned ingestion SHALL use independently led JetStream streams with non-overlapping subjects and explicit aggregate capacity/replication budgets.

#### Scenario: A proposed shard overlaps an existing stream
- **WHEN** the proposed shard subject is covered by another stream
- **THEN** topology activation fails with an ownership conflict
- **AND** existing streams are not silently rewritten or deleted

### Requirement: Deterministic versioned routing
Collectors SHALL route canonical source identities deterministically within an immutable epoch before batching and SHALL retain original routes and identities on retry.

#### Scenario: Routing changes during an ACK retry
- **WHEN** a new epoch becomes active while a batch awaits acknowledgment
- **THEN** the retry uses the original subject, stream, message ID and bytes
- **AND** newly formed batches use the new epoch

### Requirement: Shared bounded persistence consumers
EventWriter workers SHALL share one persistence durable per shard, bound demand and storage admission, and acknowledge only after successful persistence.

#### Scenario: Another worker replica starts
- **WHEN** a worker joins an existing shard's persistence durable
- **THEN** it shares pending work rather than creating a new independent copy of the stream

### Requirement: Safe epoch migration
Resharding SHALL create a new epoch and preserve old routes and consumers until they drain under an explicit retention policy.

#### Scenario: Shard count changes
- **WHEN** an operator changes the configured shard count
- **THEN** the new layout receives a new epoch
- **AND** in-flight and retained old-epoch records remain consumable
- **AND** no strict cross-epoch processing order is implied
