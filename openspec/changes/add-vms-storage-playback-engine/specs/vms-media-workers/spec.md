## ADDED Requirements

### Requirement: Isolated optional media workers
The system SHALL keep accelerated analysis and derived-media work outside the recording critical path and admit only capability-verified bounded worker jobs.

#### Scenario: GPU unavailable or exhausted
- **WHEN** the requested model/codec/backend is unsupported or worker capacity is exhausted
- **THEN** optional work SHALL queue within its budget or fail explicitly
- **AND** SHALL not trigger unbounded CPU fallback or interrupt ordinary recording/live viewing

### Requirement: Durable idempotent media work
The system SHALL deliver asynchronous media jobs through bounded durable messaging with deadlines, attempt limits, recoverable admission and idempotent result publication.

#### Scenario: Worker dies after output before acknowledgement
- **WHEN** a completed job is redelivered
- **THEN** the worker/result consumer SHALL reconcile verified output using the stable job identity
- **AND** SHALL expose at most one accepted result and clean up orphan attempts

#### Scenario: Retry exhaustion or cancellation
- **WHEN** a job reaches its delivery/runtime limit or is cancelled
- **THEN** the system SHALL record an explicit terminal state and release capacity
- **AND** SHALL reconcile retained messages and temporary outputs instead of retrying indefinitely

### Requirement: Authorized worker media capabilities
Workers SHALL receive only scoped job/input/output capabilities and SHALL publish results through the owned messaging consumer rather than directly accessing application databases.

#### Scenario: Forged reference or expired capability
- **WHEN** a job names an unauthorized object/range/environment or its access expires
- **THEN** the worker SHALL refuse access or request an authorized renewal
- **AND** SHALL not use broad bucket credentials or arbitrary URLs as a fallback

### Requirement: Capture-time labels and explicit annotated derivatives
The system SHALL support authorized camera/location/time player overlays and distinguish them from opt-in burned-in derived outputs, preserving immutable originals and historical label provenance.

#### Scenario: Camera renamed after capture
- **WHEN** historical footage is viewed or rendered
- **THEN** the label SHALL resolve the metadata revision valid at capture time or show unknown history
- **AND** SHALL not silently substitute a current label as historical fact

#### Scenario: Burned-in annotation requested
- **WHEN** an operator requests text, branding or composition inside an exported video
- **THEN** the request SHALL consume a bounded render/encode budget and record its inputs/settings
- **AND** labels SHALL be escaped and originals SHALL remain unchanged

### Requirement: Authorized time-aligned searchable derivatives
The system SHALL keep transcript text and optional embeddings linked to authorized media intervals, model/provenance versions and explicit retention, with implementation gated on a dedicated P3 search contract.

#### Scenario: Semantic transcript search
- **WHEN** an authorized user searches transcript content
- **THEN** results SHALL return only permitted snippets and seekable source intervals
- **AND** embeddings SHALL supplement canonical transcript text rather than replace it

#### Scenario: Source expires or inference is uncertain
- **WHEN** source media is deleted, access changes or speech processing is partial
- **THEN** search projections SHALL reconcile retention/access and expose processing uncertainty
- **AND** model reprocessing SHALL not resurrect unauthorized or deleted content
