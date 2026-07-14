A serde wrapper that can be used to serialize durations as nanoseconds.
It's often useful together with serde_json to communicate with JSON protocols.

# Example

```rust
use std::time::Duration;

pub struct Message {
    #[serde(with = "serde_nanos")]
    expires_in: Duration,
}
```
