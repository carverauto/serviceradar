## 1. API + Elixir extraction
- [ ] 1.1 Define the carrier API + header-key contract (shared doc/fixtures)
- [ ] 1.2 Extract ServiceRadar.Otel.Propagation into the Elixir SDK package
      (hex-publishable); core-elx consumes it
## 2. Go + Rust packages
- [ ] 2.1 Go package (inject/extract + NATS adapter + semconv span helpers);
      platform Go services adopt it
- [ ] 2.2 Rust crate; rust/addon-sdk re-export; agent/add-ons adopt for
      self-telemetry hops
## 3. Conformance + publishing
- [ ] 3.1 Cross-language conformance fixtures (inject in A, extract in B)
- [ ] 3.2 Publishing pipelines (hex, crates.io, Go module tags) per existing
      SDK publishing patterns
- [ ] 3.3 Docs + examples preconfigured for ServiceRadar endpoints
## 4. Kafka follow-on (separate approval before implementation)
- [ ] 4.1 Kafka adapter on the same carrier API (headers-based)
