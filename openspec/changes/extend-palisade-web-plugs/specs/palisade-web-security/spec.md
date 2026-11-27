## ADDED Requirements

### Requirement: Palisade provides configurable security headers
`palisade` SHALL provide a plug that sets the following headers from explicit options, without reading application environment:
- a content security policy, in enforce or report-only mode
- HSTS, on HTTPS requests or when forced
- `Permissions-Policy`
- `Referrer-Policy`
- `X-Content-Type-Options`
- `X-Frame-Options`

Its default content security policy SHALL allow only same-origin resources and SHALL deny framing.

#### Scenario: Default policy
- **WHEN** an application uses the plug with no options
- **THEN** responses carry a policy with `default-src 'none'`, same-origin script, style, image, font, and connect sources, and `frame-ancestors 'none'`

#### Scenario: Report-only mode
- **WHEN** report-only mode is configured
- **THEN** the policy is sent as `content-security-policy-report-only` and the enforcing header is absent

### Requirement: Client addresses trust forwarding headers only from trusted proxies
`palisade` SHALL resolve the client address from the socket peer. It SHALL use `X-Forwarded-For` only when the peer address lies within configured trusted CIDRs. Header parsing SHALL be bounded in byte length, address count, and header count. The same resolution SHALL be available for LiveView connect info.

#### Scenario: Untrusted peer sends a forwarding header
- **WHEN** a peer outside the trusted CIDRs sends `X-Forwarded-For: 203.0.113.9`
- **THEN** the resolved client address is the peer address

#### Scenario: Oversized header
- **WHEN** a trusted proxy forwards an `X-Forwarded-For` header that exceeds the bounds
- **THEN** the header is ignored and the peer address is used

### Requirement: Rate limiting has a pluggable backend with a safe single-node default
`palisade` SHALL define a rate-limit behaviour and provide a single-node ETS backend. The ETS backend SHALL bound its table size and SHALL deny requests when the table is full. The rate-limit plug SHALL support named buckets keyed by client address or a custom key. It SHALL set rate-limit response headers, and it SHALL answer denied requests with 429 and `retry-after`.

#### Scenario: Limit exceeded
- **WHEN** a client exceeds a bucket's limit within its window
- **THEN** the response is 429 with `retry-after`, and other clients in the same bucket are unaffected

#### Scenario: Table full
- **WHEN** the ETS backend reaches its configured entry bound
- **THEN** new keys are denied rather than admitted without limit

### Requirement: Long-lived connections are admitted against caps
`palisade` SHALL provide a connection limiter. It SHALL cap active connections and admission rate globally and per key, and SHALL release a slot when the owning process exits.

#### Scenario: Per-client cap reached
- **WHEN** a client already holds the maximum number of active connections
- **THEN** a further admission is refused until one of its connection processes exits

### Requirement: Malformed requests are rejected early
`palisade` SHALL provide a request guard plug. It SHALL reject GET and HEAD requests that carry a body or transfer encoding. It SHALL reject query strings longer than the configured limit and requests with more than the configured number of headers. When a per-route query-parameter allow-list is configured, it SHALL reject parameters outside that list.

#### Scenario: GET with a body
- **WHEN** a client sends a GET request with a body
- **THEN** the request is rejected before reaching the router

### Requirement: Network address policy offers CIDR helpers
`Palisade.NetworkAddressPolicy` SHALL provide `ip_in_any_cidr?/2` and `cidr_contains?/2` for IPv4 and IPv6, and SHALL handle IPv4-mapped IPv6 addresses. In-repository consumers SHALL delegate to these helpers rather than keep their own copies.

#### Scenario: IPv4-mapped address
- **WHEN** `ip_in_any_cidr?/2` is called with `::ffff:10.0.0.5` and the CIDR `10.0.0.0/8`
- **THEN** it returns true
