# Receive buffers and Zen without repeated payload copies

Status: source-backed research and proposed experiments, not implementation or
benchmark results. Inspected 2026-11-15. This supplements `performance.md`.

## Direction

Support Kubernetes deployments and edge collectors on bare metal or VMs.
Product-owner steering requires both an efficient conventional receive path
and optional hardware acceleration. Our ordinary VM-backed workers are the
primary deployment reference; specialized accelerator nodes can demonstrate
mechanisms without becoming a customer hardware requirement.

Treat AF_XDP UDP and io_uring ZC Rx TCP as explicit prototype workstreams and
the intended accelerated receive architecture. Design buffer ownership now so
the parser and normalizer do not require fresh strings at each boundary. Keep
batched UDP sockets and async TCP as supported production backends and controlled
performance comparators. Ordinary io_uring remains a candidate on kernels that
support it even when hardware receive zero-copy is unavailable.
Compio is a runtime choice; it does not itself decide whether NIC receive memory
can be shared with Zen. Verify actual operation on our target environment before
claiming support or gains; hardware age alone does not establish capability.

Do not promise end-to-end zero-copy: normalization creates new values, protobuf
encoding produces a new representation, and TLS and warehouse ingestion have
their own buffers. The useful target is to retain unchanged payload bytes
through parsing and rule evaluation, then encode once into a bounded batch.

## What Zen already provides

ServiceRadar's Cargo.lock pins zen-engine/zen-types 2.0.1 and hipstr 0.8.0.
The separately cloned gorules/zen checkout at
`9c374e1681895261102ba3384d19884e8133be1d` declares version 2.1.7. Both have the
following relevant structure; the newer checkout is not the installed version.

- `core/types/src/symbol.rs`: `Symbol = hipstr::LocalHipStr<'static>`.
  HipStr can adopt an owned String/Vec backing allocation and produce shared
  slices. Small values/slices may copy inline; this is cheap but not literally
  zero bytes copied. Static lifetime here also permits owned shared storage;
  it does not mean every value must be a string literal.
- `core/types/src/variable/mod.rs`: arrays and objects use `Rc<RefCell<...>>`.
  `Clone` delegates to `shallow_clone`; containers and long shared strings do
  not require recursively duplicating their contents. This is mutable sharing,
  not automatic copy-on-write for every operation.
- `core/engine/src/engine.rs`: evaluation accepts a native `Variable` and
  returns a native result. Compilation APIs already exist. Parse rules and
  compile the candidate snapshot outside the per-record path.

Our `elixir/serviceradar_core/native/zen_nif/src/lib.rs` currently takes JSON
text, parses a serde_json Value, deep-clones that context twice per rule,
converts into Zen Variable, converts the result back into serde_json Value,
merges, and finally emits JSON text. The consuming Value conversion in
zen-types 2.0.1 still constructs strings from `as_str()`; consuming the JSON
tree is not proof of adopting its string allocations.

## First experiment: no Zen fork

1. Parse one owned UTF-8 message with byte ranges. Adopt its allocation into
   Zen's existing Symbol representation; use shared slices for unchanged
   message, hostname and other fields. Static schema keys can use static
   symbols. Invalid UTF-8, unescaping and decompression need explicit existing
   semantics and may allocate replacement storage.
2. Construct Variable objects directly. Retain native values across the whole
   ordered ruleset; avoid serde_json Value between rules. Keep expensive text
   serialization at compatibility boundaries only.
3. Implement the existing recursive overlay semantics over native values.
   Zen's `merge`/`merge_clone` are NOT drop-in substitutes: their object merge
   removes null-valued fields, while our adapter preserves explicit nulls;
   non-object behavior also differs. Verify aliasing when a rule mutates input
   or returns a nested reference. Copy only containers requiring separation.
4. Encode the final native values into the chosen protobuf contract. Generated
   owned String messages can reintroduce a copy; compare a schema-correct
   encoder borrowing native strings against that simple baseline. The final
   protobuf byte write remains a serialization copy.
5. Keep Variable values and evaluation on bounded worker-local executors:
   Rc/RefCell values are not Send. Transfer owned input buffers before building
   local values, and Send-safe encoded batches afterward. Do not replace all
   Rc references with Arc solely to permit arbitrary task migration.

An adopted ordinary Vec is not an AF_XDP UMEM frame or an io_uring registered
receive-buffer lease. This first experiment eliminates repeated application
copies; it may still copy from a leased receive buffer into ordinary storage.

## When a Zen patch or fork makes sense

For a contiguous NIC-buffer-backed string, prototype an owner plus byte range:
the owner keeps the receive region alive, and the last reference returns that
region through its owning receive queue. Clones retain the owner; slices adjust
the range. New/modified strings use ordinary owned storage. All views must be
valid UTF-8 and remain immutable until their last use.

Zen's current static HipStr alias cannot directly express an arbitrary pool
lease and its release callback. Candidate upstream changes are external-owner
support in HipStr, or a Zen Symbol abstraction preserving existing string
operations with an additional lease-backed representation. Inspect expression,
template, comparison, hashing, serialization and JS bridges before selecting
the change. This is wider than adding one enum case in the collector.

Prefer a narrow upstreamable patch, with a temporary pinned fork if needed.
Do not start by lifetime-parameterizing the entire engine, pretending a recycled
buffer is static, or using DynamicVariable as an unverified replacement for
normal strings. Such values must preserve all existing string semantics.

Bound outstanding receive leases by bytes and count. Release them after
evaluation and encoding, before JetStream ACK waits. Long-running rules must
not exhaust the NIC's refill supply: compare a bounded copy into worker-owned
storage against retaining scarce receive leases. TCP messages spanning receive
chunks may require coalescing or a segmented parser; a single borrowed str
cannot represent discontiguous chunks. Small views can retain large regions.

## Rule-language limits

Native expressions and decision tables are the first sharing comparator.
In the inspected Zen checkout, `nodes/function/v1/script.rs` serializes function
arguments and parses a JSON response; v2's `serde.rs` builds QuickJS arrays and
objects through JsConverter. Even without JSON text, crossing into a JavaScript
heap is not automatically zero-copy. Profile deployed rule node categories
without copying live payloads into fixtures. Preserve custom-rule behavior;
do not advertise arbitrary JavaScript transformations as zero-copy.

Matching and selecting existing strings can share bytes. Case conversion,
redaction, replacement and concatenation produce new bytes. Allocate those
outputs deliberately rather than spending complexity to label all evaluation
zero-copy.

## Receive prototypes

| Path | Prototype contract | Evidence required |
| --- | --- | --- |
| AF_XDP UDP | Dedicated RX queues and UMEM; minimal XDP steering; parse packet metadata and feed bounded workers | Force XDP_ZEROCOPY and verify XDP_OPTIONS_ZEROCOPY. Native XDP alone does not establish zero-copy. |
| io_uring ZC Rx TCP | Kernel TCP stack, header/data split, dedicated steered RX queues and registered receive regions/refill ring | Confirm supported NIC/driver/kernel and IORING_OP_RECV_ZC operation; ordinary multishot recv is a different comparator. |
| Portable production path | recvmmsg UDP and async/multishot TCP using the same parser/normalizer/publisher contract | Same framing, rules, batches, durability and loss accounting. Validate on VM-backed Kubernetes workers and edge VMs. |

AF_XDP provides packets, not a UDP socket's complete semantics. Specify VLAN,
IPv4/IPv6, checksum handling and fragmentation. Unsupported packets need a
defined kernel fallback before redirect, or a correct reassembly path; jumbo
multi-buffer support is not IP fragment reassembly. Kernel TCP via ZC Rx avoids
building our own TCP stack. Neither receive mechanism removes TLS decryption
cost for encrypted inputs; qualify plaintext and TLS separately without
weakening existing transport security.

Establish physical NIC access, RSS/queue steering, CPU/NUMA locality and
deployment networking in our environment first. Do not assume the default
Kubernetes veth/overlay path exposes the NIC's zero-copy facilities. Change the
deployment arrangement where necessary and document the working requirements
for customers to adopt. A broad hardware qualification program is out of scope.
Provide explicit backend selection and an automatic mode: automatic mode can
choose the portable backend with an observable reason; explicitly requested
zero-copy must fail clearly when unavailable rather than silently copying.
Packet-level fallback for protocol correctness, such as fragments, is a
separate concern from backend selection.

### Kubernetes and virtual-machine integration

Treat host NIC, guest NIC and pod networking as distinct capability boundaries.
A physical function supporting AF_XDP does not imply that a bridged virtio
guest or a pod veth exposes that capability. Inspect the hypervisor and guest
separately. Consider a dedicated passed-through port or an SR-IOV device exposed
to Kubernetes; verify the guest/VF driver supports the required operation before
choosing either. Do not detach an active hypervisor uplink to run a benchmark.
Host networking in a VM exposes guest interfaces, not the hypervisor's NICs.

Keep portable mode compatible with restricted pods where possible. Probe
io_uring syscalls under the actual seccomp policy; kernel support alone does
not establish that a container can call them. If needed, supply a reviewed
seccomp profile allowing the necessary io_uring calls while retaining other
restrictions. An unconfined diagnostic pod is not the production security
contract. AF_XDP needs a separate, explicit deployment contract for device
access, buffer locking, XDP attachment and capabilities, scoped to collectors.

Use kernel operation probes and netdev capability queries for initial discovery,
then force AF_XDP zero-copy binding and check XDP_OPTIONS_ZEROCOPY. Registration
success still does not prove packet delivery or throughput. Test packet delivery,
buffer recycling and cleanup separately. Validate MTU, multi-buffer support and
receive-queue mode together; a driver advertising zero-copy may reject a
particular buffer/queue configuration. TCP ZC Rx is a separate capability from
AF_XDP and ordinary io_uring, with its own kernel and NIC requirements.

Compio's current TcpStream API exposes zero-copy writes. That is a separate
send experiment: kernel buffer-release completion is not a JetStream durable
ACK. Existing async-nats/TLS integration must be verified before claiming that
our publisher uses it. Receive buffers should not be held through publish
retries just to avoid one output allocation.

## Measurement and decision

Compare current adapter, native shared strings, and lease-backed strings with
the same synthetic records and rules. Record allocations and copied bytes per
record, CPU cycles, throughput, tail latency and retained backing capacity.
Include pass-through, nested overlays/nulls, string rewrites and JS functions.

Compare receive backends both in isolation and through durable searchable
storage. Include small datagrams, varied frame sizes, many TCP connections,
hot flows, bursts, stalled rules and slow JetStream/storage. Measure drops at
each stage, refill starvation, in-flight bytes and recovery time. Count total
reserved cores, including polling cores. Report receive gains even when a
downstream bottleneck masks them; do not present them as end-to-end gains.

Adopt the backend that improves the stated throughput/latency/cost envelope
without changing correctness. A leased-string fork is justified when its
measured gain over one bounded ownership copy warrants its integration cost.
This investigation has not run those measurements or modified Zen.

## Primary references

- [Zen inspected commit](https://github.com/gorules/zen/tree/9c374e1681895261102ba3384d19884e8133be1d)
- [Zen 2.0.1 API](https://docs.rs/zen-engine/2.0.1/zen_engine/)
- [HipStr 0.8.0 source](https://docs.rs/crate/hipstr/0.8.0/source/src/)
- [Linux AF_XDP](https://docs.kernel.org/networking/af_xdp.html)
- [Linux io_uring zero-copy receive](https://docs.kernel.org/networking/iou-zcrx.html)
- [Compio TCP API](https://docs.rs/compio-net/latest/compio_net/struct.TcpStream.html)
