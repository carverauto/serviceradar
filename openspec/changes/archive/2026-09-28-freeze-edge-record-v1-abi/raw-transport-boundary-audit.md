# Raw transport boundary audit

Tasks 1.7-a and 1.7-b, inspected after `af0a2151fd`.

The repository does not register an `EdgeRecordIngestService` implementation.
The generated service declaration in `proto/edge/v1/record.proto` does not create
an endpoint. The agent gateway's `Endpoint` registers the agent gateway, camera,
desktop and remote capture servers, and none exposes the edge-ingest stream.
No Go registration of the generated edge-ingest service exists either.

Consequently there is no deployed edge-ingest transport receive bound to report
from this branch. The generic Go lifecycle server defaults to 4 MiB and accepts
`GRPC_MAX_RECV_MSG_SIZE` overrides (`go/pkg/lifecycle/server.go`); that is not an
edge ABI enforcement site. Before this increment, `MaxClientMessageBytes` and its
error existed without an edge decoder using them. Elixir already applied the
ceiling in `WireDecode.decode_client_message/1`.

`edgerecord.DecodeClientMessage` now checks 540680 received bytes before any wire
scan, requires exactly one outer payload, checks the exact nested frame's
relational envelope and absolute frame limits before generated decode, and
refuses retained unknown fields. `DecodeFrame` composes the existing raw frame
budget with decode and retained-field rejection. These are raw admission APIs;
semantic lane/frame checks and the opaque record's separate decoder remain
subsequent stages. No live ingress attachment is claimed.

The shared `raw_bounds_corpus.txt` pins N accepted and N+1 refused for record
(524288), non-record envelope (16384), frame (540672), and client (540680).
Malformed N+1 witnesses for the three absolute byte limits must report the size
error, proving the decoder is not reached first. These are wire-stage controls:
large padding in a declared bytes field does not claim valid semantic identity,
nonce length or capability authorization.

The relational corpus isolates the envelope budget: a one-byte opaque record
plus repeated sequence fields has overhead 16384 or 16385, while the canonical
frame is at most eight bytes and both received messages are far below the frame
and client ceilings. The same bytes are tested directly and inside a client
message, so a wrapper cannot bypass the pre-decode relational check.

Evidence owners are `proto/edge/v1/raw_bounds_corpus_test.go` and
`elixir/serviceradar_core/test/serviceradar/edge/raw_bounds_corpus_test.exs`.
