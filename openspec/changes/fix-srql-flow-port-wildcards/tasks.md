## 1. Implementation

- [x] 1.1 Update SRQL flows filter handling to allow Like/NotLike for port fields by casting ports to text for wildcard matches
- [x] 1.2 Adjust filter parameter binding to accept text parameters for port wildcards while keeping integer parsing for equality/list operators
- [x] 1.3 Add SRQL flow query tests covering wildcard port filters and integer validation errors

## 2. Testing

- [x] 2.1 Run SRQL tests (`cd rust/srql && cargo test`)
- [ ] 2.2 Verify SRQL API accepts `in:flows time:last_24h dst_port:%443% sort:time:desc limit:50`
