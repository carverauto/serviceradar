defmodule Netperf.V1.NetperfProtocol do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "netperf.v1.NetperfProtocol",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :NETPERF_PROTOCOL_UNSPECIFIED, 0
  field :NETPERF_PROTOCOL_TCP, 1
  field :NETPERF_PROTOCOL_UDP, 2
end

defmodule Netperf.V1.NetperfDirection do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "netperf.v1.NetperfDirection",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :NETPERF_DIRECTION_UNSPECIFIED, 0
  field :NETPERF_DIRECTION_UPLOAD, 1
  field :NETPERF_DIRECTION_DOWNLOAD, 2
  field :NETPERF_DIRECTION_BIDIRECTIONAL, 3
end

defmodule Netperf.V1.NetperfExecutionSource do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "netperf.v1.NetperfExecutionSource",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :NETPERF_EXECUTION_SOURCE_UNSPECIFIED, 0
  field :NETPERF_EXECUTION_SOURCE_SCHEDULED_POLICY, 1
  field :NETPERF_EXECUTION_SOURCE_ON_DEMAND, 2
end

defmodule Netperf.V1.NetperfPermitV1 do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.NetperfPermitV1",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :permit_version, 1, type: :uint32, json_name: "permitVersion"
  field :permit_id, 2, type: :string, json_name: "permitId"
  field :partition_id, 3, type: :string, json_name: "partitionId"
  field :sender_agent_id, 4, type: :string, json_name: "senderAgentId"
  field :responder_agent_id, 5, type: :string, json_name: "responderAgentId"
  field :policy_id, 6, type: :string, json_name: "policyId"
  field :max_bandwidth_bps, 7, type: :uint64, json_name: "maxBandwidthBps"
  field :max_duration_sec, 8, type: :uint32, json_name: "maxDurationSec"
  field :max_parallel, 9, type: :uint32, json_name: "maxParallel"

  field :allowed_protocols, 10,
    repeated: true,
    type: Netperf.V1.NetperfProtocol,
    json_name: "allowedProtocols",
    enum: true

  field :allowed_directions, 11,
    repeated: true,
    type: Netperf.V1.NetperfDirection,
    json_name: "allowedDirections",
    enum: true

  field :issued_at_unix, 12, type: :int64, json_name: "issuedAtUnix"
  field :expires_at_unix, 13, type: :int64, json_name: "expiresAtUnix"
  field :authority_epoch, 14, type: :uint64, json_name: "authorityEpoch"
  field :issuer_id, 15, type: :string, json_name: "issuerId"
  field :issuer_key_id, 16, type: :bytes, json_name: "issuerKeyId"
  field :algorithm, 17, type: :string
  field :signature, 18, type: :bytes
end

defmodule Netperf.V1.NetperfResponderConfig do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.NetperfResponderConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :enabled, 1, type: :bool
  field :listen_port, 2, type: :uint32, json_name: "listenPort"
  field :udp_enabled, 3, type: :bool, json_name: "udpEnabled"
  field :max_concurrent_sessions, 4, type: :uint32, json_name: "maxConcurrentSessions"
  field :max_total_bandwidth_bps, 5, type: :uint64, json_name: "maxTotalBandwidthBps"
  field :advertise_address, 6, type: :string, json_name: "advertiseAddress"
  field :min_authority_epoch, 7, type: :uint64, json_name: "minAuthorityEpoch"
end

defmodule Netperf.V1.NetperfTargetAssignment do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.NetperfTargetAssignment",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :policy_id, 1, type: :string, json_name: "policyId"
  field :policy_name, 2, type: :string, json_name: "policyName"
  field :profile_id, 3, type: :string, json_name: "profileId"
  field :profile_name, 4, type: :string, json_name: "profileName"
  field :responder_agent_id, 5, type: :string, json_name: "responderAgentId"
  field :responder_label, 6, type: :string, json_name: "responderLabel"
  field :target_address, 7, type: :string, json_name: "targetAddress"
  field :target_port, 8, type: :uint32, json_name: "targetPort"
  field :protocol, 9, type: Netperf.V1.NetperfProtocol, enum: true
  field :direction, 10, type: Netperf.V1.NetperfDirection, enum: true
  field :bandwidth_bps, 11, type: :uint64, json_name: "bandwidthBps"
  field :duration_sec, 12, type: :uint32, json_name: "durationSec"
  field :omit_sec, 13, type: :uint32, json_name: "omitSec"
  field :parallel, 14, type: :uint32
  field :packet_length, 15, type: :uint32, json_name: "packetLength"
  field :interval_seconds, 16, type: :uint32, json_name: "intervalSeconds"
  field :permit, 17, type: Netperf.V1.NetperfPermitV1
end

defmodule Netperf.V1.NetperfConfig do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.NetperfConfig",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :responder, 1, type: Netperf.V1.NetperfResponderConfig
  field :targets, 2, repeated: true, type: Netperf.V1.NetperfTargetAssignment
  field :config_epoch, 3, type: :uint64, json_name: "configEpoch"
end

defmodule Netperf.V1.OpenSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.OpenSessionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :permit, 1, type: Netperf.V1.NetperfPermitV1
  field :protocol, 2, type: Netperf.V1.NetperfProtocol, enum: true
  field :direction, 3, type: Netperf.V1.NetperfDirection, enum: true
  field :bandwidth_bps, 4, type: :uint64, json_name: "bandwidthBps"
  field :duration_sec, 5, type: :uint32, json_name: "durationSec"
  field :omit_sec, 6, type: :uint32, json_name: "omitSec"
  field :parallel, 7, type: :uint32
  field :packet_length, 8, type: :uint32, json_name: "packetLength"

  field :execution_source, 9,
    type: Netperf.V1.NetperfExecutionSource,
    json_name: "executionSource",
    enum: true
end

defmodule Netperf.V1.OpenSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.OpenSessionResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :accepted, 1, type: :bool
  field :session_id, 2, type: :bytes, json_name: "sessionId"
  field :udp_session_key, 3, type: :bytes, json_name: "udpSessionKey"
  field :udp_port, 4, type: :uint32, json_name: "udpPort"
  field :retry_after_ms, 5, type: :uint32, json_name: "retryAfterMs"
  field :reject_reason, 6, type: :string, json_name: "rejectReason"
end

defmodule Netperf.V1.TestStreamChunk do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.TestStreamChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :bytes, json_name: "sessionId"
  field :stream_index, 2, type: :uint32, json_name: "streamIndex"
  field :phase, 3, type: Netperf.V1.NetperfDirection, enum: true
  field :data, 4, type: :bytes
  field :sequence, 5, type: :uint64
  field :end_of_phase, 6, type: :bool, json_name: "endOfPhase"
end

defmodule Netperf.V1.TestSummary do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.TestSummary",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :duration_seconds, 1, type: :double, json_name: "durationSeconds"
  field :duration_ns, 2, type: :uint64, json_name: "durationNs"
  field :bytes_sent, 3, type: :uint64, json_name: "bytesSent"
  field :bytes_received, 4, type: :uint64, json_name: "bytesReceived"
  field :bits_per_second, 5, type: :double, json_name: "bitsPerSecond"
  field :packets_sent, 6, type: :uint64, json_name: "packetsSent"
  field :packets_received, 7, type: :uint64, json_name: "packetsReceived"
  field :packets_lost, 8, type: :uint64, json_name: "packetsLost"
  field :out_of_order_packets, 9, type: :uint64, json_name: "outOfOrderPackets"
  field :loss_percent, 10, type: :double, json_name: "lossPercent"
  field :jitter_ms, 11, type: :double, json_name: "jitterMs"
end

defmodule Netperf.V1.CloseSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.CloseSessionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :bytes, json_name: "sessionId"
  field :sender_summary, 2, type: Netperf.V1.TestSummary, json_name: "senderSummary"
end

defmodule Netperf.V1.CloseSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "netperf.v1.CloseSessionResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  alias Netperf.V1.TestSummary

  field :responder_summary, 1, type: TestSummary, json_name: "responderSummary"
  field :upload_summary, 2, type: TestSummary, json_name: "uploadSummary"
  field :download_summary, 3, type: TestSummary, json_name: "downloadSummary"
end

defmodule Netperf.V1.NetworkPerfPeerService.Service do
  @moduledoc false

  use GRPC.Service, name: "netperf.v1.NetworkPerfPeerService", protoc_gen_elixir_version: "0.16.0"

  alias Netperf.V1.TestStreamChunk

  rpc(:OpenSession, Netperf.V1.OpenSessionRequest, Netperf.V1.OpenSessionResponse)

  rpc(:StreamTest, stream(TestStreamChunk), stream(TestStreamChunk))

  rpc(:CloseSession, Netperf.V1.CloseSessionRequest, Netperf.V1.CloseSessionResponse)
end

defmodule Netperf.V1.NetworkPerfPeerService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Netperf.V1.NetworkPerfPeerService.Service
end
