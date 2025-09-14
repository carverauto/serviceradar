# SRQL OCaml Implementation - Remaining Work Checklist

## Overview
The OCaml SRQL implementation needs to reach feature parity with the existing Go implementation and provide compatible API responses for the ServiceRadar UI.

## Current State Analysis

### ✅ Completed Components
- **Proton Database Driver**: Working with TLS support
- **Basic SRQL Parser**: Lexer/Parser for basic SRQL syntax
- **Entity Mapping**: Maps entity names to table names
- **Basic Translation**: Converts SRQL AST to SQL
- **CLI Tool**: Command-line interface for testing
- **Web Server**: Basic HTTP endpoint at `/translate`

### 🔴 Missing Core Features

## 1. Query Types & Features

### 1.1 Missing Query Types
- [ ] **STREAM queries** - Not implemented in AST or translator
- [ ] **LATEST modifier** - Critical for versioned_kv streams
- [x] **ORDER BY clause** - Implemented in AST/lexer/parser/translator; tests added
- [ ] **GROUP BY clause** - Not implemented
- [ ] **HAVING clause** - Not implemented
- [ ] **JOIN support** - For complex queries
- [ ] **Time clauses** (TODAY, YESTERDAY, LAST n DAYS)
- [ ] **Function calls** (DISTINCT, COUNT with fields)

### 1.2 Missing Operators
- [ ] **BETWEEN operator** - For range queries
- [ ] **IS NULL/IS NOT NULL** - For null checks
- [ ] **NOT operator** - Logical negation

## 2. Translation Features

### 2.1 Proton-Specific SQL Generation
- [x] **table() wrapper** - FROM <tbl> auto-wrapped as FROM table(<tbl>) in Proton client translation
- [ ] **Streaming vs Historical** - Different SQL generation modes
- [ ] **Scalar aggregate detection** - Treat scalar aggregates as bounded
  - [ ] Detect simple aggregates without GROUP BY (e.g., `SELECT count() ...`) and route via non-streaming execution path
  - [ ] Extend detection beyond COUNT to `SUM/AVG/MIN/MAX` when used as single-row aggregates
  - [ ] Optionally auto-wrap `FROM <table>` with `table(<table>)` for snapshot semantics when running aggregates without `LIMIT`
  - [ ] Plumb an explicit “boundedness” flag from translator to client to avoid duplicating SQL heuristics in multiple places
  - [ ] Ensure behavior is configurable via env (e.g., `SRQL_BOUNDED=bounded|unbounded|auto`) with sensible defaults
- [ ] **ROW_NUMBER() for LATEST** - For non-versioned_kv streams
- [ ] **CTE generation** - For complex LATEST queries
- [ ] **Default filters** - Automatic filters for certain entities
  - [ ] `discovery_sources = 'sweep'` for sweep_results
  - [ ] `metric_type = 'snmp'` for SNMP entities
  - [ ] `metadata['_deleted'] != 'true'` for devices

### 2.2 Field Mappings
- [ ] **Field name translations** - Map SRQL fields to database columns
  - [ ] logs.severity → severity_text
  - [ ] otel fields mappings
- [ ] **Date function handling** - date(field) = TODAY/YESTERDAY
- [ ] **Array field detection** - Using has() for array fields

## 3. API Integration

### 3.1 Query Execution
- [x] **Execute queries against Proton** - Implemented via POST /api/query using Proton client
- [x] **Return actual data** - Endpoint returns rows as JSON objects (stringified values)
- [x] **Error handling** - Returns structured JSON errors on invalid input

### 3.2 Response Format
- [x] **QueryResponse structure** - Implemented in /api/query with results, pagination (cursors + limit), and error
  ```json
  {
    "results": [...],
    "pagination": {
      "next_cursor": "...",
      "prev_cursor": "...",
      "limit": 10
    },
    "error": "..." // if applicable
  }
  ```

### 3.3 Pagination Support
- [x] **Cursor-based pagination** - Keyset pagination via ORDER BY + boundary predicate
- [x] **Cursor encoding/decoding** - Base64-encoded JSON cursors supported in responses and requests
- [x] **Direction support** - next/prev navigation with stable ordering
- [x] **Multi-column sorting** - Supports multi-key lexicographic predicates; ensures ORDER BY fields included for SELECT
- [x] **Entity-specific sort fields** - Defaults to entity timestamp when ORDER BY absent

## 4. Post-Processing

### 4.1 Device Results Processing
- [ ] **Parse discovery_sources** - Convert from JSON/array
- [ ] **Parse metadata field** - Handle different formats
- [ ] **Parse hostname/mac** - Handle nullable fields
- [ ] **Integration type replacement** - Replace generic "integration"
- [ ] **Remove raw JSON fields** - Clean up response

### 4.2 Type Conversions
- [x] **Time formatting** - RFC3339 for DateTime/DateTime64 in API results
- [x] **Boolean handling** - Proper true/false based on column type
- [x] **Null handling** - Emits JSON null for Nullable types
- [x] **Numeric promotion** - Int/UInt/Float rendered as JSON numbers when possible
- [x] **Structured types** - Arrays, Maps, Tuples returned as structured JSON; Enums as strings

## 5. HTTP API Endpoints

### 5.1 Main Query Endpoint
- [x] **POST /api/query** - Main SRQL query endpoint
  - [x] Accept QueryRequest JSON
  - [x] Validate request parameters
  - [x] Execute query
  - [x] Return QueryResponse (results + pagination stub + error)

### 5.2 Supporting Endpoints
- [x] **GET /health**
- [ ] **Authentication** - API key validation
- [ ] **CORS support** - For browser-based access

## 6. Configuration & Connection Management

### 6.1 Database Configuration
- [x] **Environment-based config** - Read from env vars (host/port/db/user/password/TLS/compression)
- [ ] **Connection pooling** - Reuse Proton connections
- [ ] **Connection retry logic** - Handle failures

### 6.2 Security
- [ ] **TLS configuration** - Certificate management
- [ ] **Authentication** - Username/password support
- [ ] **Query sanitization** - Prevent injection

## 7. Testing & Validation

### 7.1 Unit Tests
- [ ] **Parser tests** - All SRQL syntax variations
- [x] **Translator tests** - SQL generation correctness (added ORDER BY coverage)
- [x] **JSON conversion tests** - Typed API value conversion and structured types
- [ ] **Post-processor tests** - Data transformation

### 7.2 Integration Tests
- [ ] **End-to-end query tests** - Full query execution
- [ ] **Pagination tests** - Cursor navigation
- [ ] **Error handling tests** - Invalid queries

### 7.3 Compatibility Tests
- [ ] **Response format validation** - Matches Go implementation
- [ ] **UI compatibility** - Works with existing frontend

## Implementation Priority

### Phase 1: Core Query Support (Critical)
1. Add ORDER BY, LIMIT to AST and parser — DONE (ORDER BY); LIMIT already supported
2. Implement table() wrapper for Proton — DONE (Proton client auto-wrap)
3. Execute queries and return real data — DONE (/api/query executes against Proton)
4. Basic response formatting — DONE (QueryResponse with results, pagination, error)

### Phase 2: Pagination (High Priority)
1. Implement cursor-based pagination
2. Add multi-column sorting
3. Entity-specific sort fields

### Phase 3: Advanced Features (Medium Priority)
1. LATEST modifier support
2. Time clauses (TODAY, YESTERDAY)
3. GROUP BY and aggregations
4. STREAM queries

### Phase 4: Post-Processing (Medium Priority)
1. Device result processing
2. Field name mappings
3. Type conversions

### Phase 5: Production Ready (Low Priority)
1. Connection pooling
2. Authentication
3. Comprehensive testing
4. Performance optimization

## Success Criteria
- [ ] All existing UI queries work without modification
- [ ] Response format matches Go implementation exactly
- [ ] Performance comparable to Go implementation
- [ ] Error messages are clear and actionable
- [ ] Pagination works seamlessly
- [ ] All entity types are supported

## Technical Debt Considerations
- Consider using ppx_deriving_yojson for automatic JSON serialization
- Evaluate using Caqti for database abstraction if Proton driver proves limiting
- Consider code generation for entity mappings from a schema file
- Implement query plan caching for frequently used queries

## Notes
- The Go implementation heavily uses models.Query struct which the OCaml version needs to mirror
- Pagination is complex with multi-field keyset pagination logic
- Post-processing is entity-specific and requires careful attention to maintain compatibility
- The translator needs both streaming and historical query modes
