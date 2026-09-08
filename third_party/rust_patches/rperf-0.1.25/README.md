# rperf

[![Crates.io](https://img.shields.io/crates/v/rperf)](https://crates.io/crates/rperf)
[![Documentation](https://docs.rs/rperf/badge.svg)](https://docs.rs/rperf)

_rperf_ is a Rust-based [_iperf_](https://github.com/esnet/iperf) alternative
developed by [3D-P](https://3d-p.com/), aiming to avoid some reliability and
consistency issues found in _iperf3_, while simultaneously providing richer
metrics data, with a focus on operation in a loss-tolerant, more IoT-like
environment. While it can be used as a near-drop-in replacement for _iperf_, and
there may be benefits to doing so, its focus is on periodic data-collection in a
monitoring capacity in a closed network, meaning it is not suitable for all
domains that _iperf_ can serve.

## development ##

_rperf_ is an independent implementation, referencing the algorithms of _iperf3_
and [_zapwireless_](https://github.com/ryanchapman/zapwireless) to assess
correctness and derive suitable corrections, but copying no code from either.


In particular, the most significant issues addressed from _iperf3_ follow:

* Multiple concurrent clients are supported by any given server.

* _rperf_'s implementation of
  [RFC 1889](https://tools.ietf.org/html/rfc1889#appendix-A.8) for streaming
  jitter calculation starts by assuming a delta between the first and second
  packets in a sequence and gaps in a sequence trigger a reset of the count.
  Comparatively, _iperf3_ begins with 0, which creates artificially low values,
  and in case of a gap, it just continues naively, which creates artificially
  high values.
  
* Duplicate packets are accounted for in UDP exchanges and out-of-order packets
  are counted as independent events.
  
* All traffic can be emitted proportionally at regular sub-second intervals,
  allowing for configurations that more accurately reflect real data
  transmission and sending algorithms.
  
  * This addresses a commonly seen case in embedded-like systems where a piece
    of equipment has a very small send- or receive-buffer that the OS does not
    know about and it will just drop packets when receiving a huge mass of
    data in a single burst, incorrectly under-reporting network capacity.
    
* Stream-configuration and results are exchanged via a dedicated connection and
  every data-path has clearly defined timeout, completion and failure semantics,
  so execution doesn't hang indefinitely on either side of a test when key
  packets are lost.

* _rperf_'s JSON output is structurally legal. No unquoted strings, repeated
  keys, or dangling commas, all of which require pre-processing before
  consumption or cause unexpected errors.


In contrast to _zapwireless_, the following improvements are realised:

* _rperf_ uses a classic client-server architecture, so there's no need to
  maintain a running process on devices that waits for a test-execution request.

* Jitter is calculated.

* IPv6 is supported.

* Multiple streams may be run in parallel as part of a test.

* An `omit` option is available to discard TCP ramp-up time from results.

* Output is available in JSON for easier telemetry-harvesting.

## platforms ##

_rperf_ should build and work on all major platforms, though its development and
usage focus is on Linux-based systems, so that is where it will be most
feature-complete.

Pull-requests for implementations of equivalent features for other systems are
welcome.


## usage

Everything is outlined in the output of `--help` and most users familiar with similar tools should feel comfortable immediately.

_rperf_ works much like _iperf3_, sharing a lot of concepts and even command-line flags. One key area where it differs is that the client drives all of the configuration process while the server just complies to the best of its ability and provides a stream of results. This means that the server will not present test-results directly via its interface and also that TCP and UDP tests can be run against the same instance, potentially by many clients simultaneously.

In its normal mode of operation, the client will upload data to the server; when the `reverse` flag is set, the client will receive data.

Unlike _iperf3_, _rperf_ does not make use of a reserved port-range by default. This is so it can support an arbitrary number of clients in parallel without resource contention on what can only practically be a small number of contiguous ports. In its intended capacity, this shouldn't be a problem, but where non-permissive firewalls and NAT setups are concerned, the `--tcp[6]-port-pool` and `--udp[6]-port-pool` options may be used to allocate non-continguous ports to the set that will be used to receive traffic.

There also isn't a concept of testing throughput relative to a fixed quantity of data. Rather, the sole focus is on measuring throughput over a roughly known period of time.

Also of relevance is that, if the server is running in IPv6 mode and its host supports IPv4-mapping in a dual-stack configuration, both IPv4 and IPv6 clients can connect to the same instance.


## building

_rperf_ uses [_cargo_](https://doc.rust-lang.org/cargo/).
The typical process will simply be `cargo build --release`.

[_cargo-deb_](https://github.com/mmstick/cargo-deb) is also supported and will
produce a usable Debian package that installs a disabled-by-default `rperf`
_systemd_ service. When started, it runs as `nobody:nogroup`, assuming IPv6
support by default.


## theory of operation

Like its contemporaries, _rperf_'s core concept is firing a stream of TCP or
UDP data at an IP target at a pre-arranged target speed. The amount of data
actually received is observed and used to gauge the capacity of a network link.

Within those domains, additional data about the quality of the exchange is
gathered and made available for review.

Architecturally, _rperf_ has clients establish a TCP connection to the server,
after which the client sends details about the test to be performed and the
server obliges, reporting observation results to the client during the entire
testing process.

The client may request that multiple parallel streams be used for testing, which
is facilitated by establishing multiple TCP connections or UDP sockets with
their own dedicated thread on either side, which may be further pinned to a
single logical CPU core to reduce the impact of page-faults on the
data-exchange.


### implementation details

The client-server relationship is treated as a very central aspect of this
design, in contrast to _iperf3_, where they're more like peers, and
_zapwireless_, where each participant runs its own daemon and a third process
orchestrates communication.

Notably, all data-gathering, calculation, and display happens client-side, with
the server simply returning what it observed. This can lead to some drift in
recordings, particularly where time is concerned (server intervals being a
handful of milliseconds longer than their corresponding client values is not
at all uncommon). Assuming the connection wasn't lost, however, totals for data
observed will match up in all modes of operation.

The server uses three layers of threading: one for the main thread, one for each
client being served, and one more for each stream that communicates with the
client. On the client side, the main thread is used to communicate with the
server and it spawns an additional thread for each stream that communicates with
the server.

When the server receives a request from a client, it spawns a thread that
handles that client's specific request; internally, each stream for the test
produces an iterator-like handler on either side. Both the client and server run
these iterator-analogues against each other asynchronously until the test period
ends, at which point the sender indicates completion within its stream.

To reliably handle the possibility of disconnects at the stream level, a
keepalive mechanism in the client-server stream, over which test-results are
sent from the server at regular intervals, will terminate outstanding
connections after a few seconds of inactivity.

The host OS's TCP and UDP mechanisms are used for all actual traffic exchanged,
with some tuning parameters exposed. This approach was chosen over a userspace
implementation on top of layer-2 or layer-3 because it most accurately
represents the way real-world applications will behave.

#### considerations ####

The "timestamp" values visible in JSON-serialised interval data are
host-relative, so unless your environment has very high system-clock accuracy,
send-timestamps should only be compared to other send-timestamps and likewise
for receive-timestamps. In general, this data is not useful outside of
correctness-validation, however.

During each exchange interval, an attempt is made to send `length` bytes at a
time, until the amount written to the stream meets or exceeds the bandwdith
target, at which point the sender goes silent until the start of the next
interval; the data sent within an interval should be uniformly distributed over
the period.

Stream indexes start at `0`, not `1`. This probably won't surprise anyone, but
seeing "stream 0" in a report is not cause for concern.


## copyright and distribution ##

_rperf_ is distributed by Evtech Solutions, Ltd., dba 3D-P, under the
[GNU GPL version 3](https://www.gnu.org/licenses/gpl-3.0.en.html), the text of
which may be found in `COPYING`.

Authorship details, copyright specifics, and transferability notes are present
within the source code itself.
