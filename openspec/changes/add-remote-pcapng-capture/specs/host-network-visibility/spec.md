## ADDED Requirements

### Requirement: Capture uses AF_PACKET and diverts no traffic

`serviceradar-netprobe` SHALL capture packets for remote capture sessions
through an `AF_PACKET` socket with a `PACKET_MMAP` ring, bound to the
target interface. Capture MUST NOT depend on the AF_XDP redirect path,
which consumes the frame and is consequently refused on any interface
carrying the host default route, and MUST NOT require a libpcap capture
handle.

Capture MUST be bidirectional: a session requesting both directions
observes transmitted frames as well as received ones.

#### Scenario: Capture runs on the host's primary interface
- **WHEN** a capture session targets an allowlisted interface that
  carries the host default route
- **THEN** the session captures packets
- **AND** host connectivity through that interface is unaffected for the
  duration of the session

#### Scenario: Both directions are captured
- **WHEN** a session captures with the filter `icmp` while the host both
  sends and receives ICMP echo traffic on the target interface
- **THEN** the captured stream contains both the echo requests and the
  echo replies

### Requirement: Filtering is kernel-enforced before the copy

`serviceradar-netprobe` SHALL attach the session's filter to the capture
socket with `SO_ATTACH_FILTER` before any frame can be queued, so that no
unfiltered packet is ever placed in the ring. Non-matching frames MUST
NOT reach userspace, so a session's cost is bounded by what the operator
requested rather than by total interface traffic.

#### Scenario: The filter is attached before the first frame
- **WHEN** a capture session starts
- **THEN** the filter is attached before the socket is able to queue
  frames
- **AND** no packet captured by the session falls outside the filter

#### Scenario: Non-matching traffic costs nothing to copy
- **WHEN** a session with a narrow filter runs on an interface carrying
  substantial non-matching traffic
- **THEN** only matching frames are copied into the capture ring
- **AND** the session's `byte_cap` bounds the captured output rather than
  merely truncating a larger stream

### Requirement: Capture does not disturb passive observation

The capture socket SHALL be independent of the AF_XDP, TC and kprobe
paths that serve DPI, fingerprinting, the passive device census and flow
attribution. Starting or stopping a capture session MUST NOT attach,
detach or reconfigure any eBPF program.

#### Scenario: Passive observation is unaffected by a capture session
- **WHEN** capture sessions start and stop repeatedly on an interface
- **THEN** the set of attached eBPF programs on that interface is
  unchanged from before the first session
- **AND** DPI, fingerprinting, census and flow attribution continue
  uninterrupted
