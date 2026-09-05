defmodule Remotecapture.CaptureSessionState do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "remotecapture.CaptureSessionState",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :CAPTURE_SESSION_STATE_UNSPECIFIED, 0
  field :CAPTURE_SESSION_STATE_ACTIVE, 1
  field :CAPTURE_SESSION_STATE_DURATION_CAP, 2
  field :CAPTURE_SESSION_STATE_BYTE_CAP, 3
  field :CAPTURE_SESSION_STATE_CLIENT_CANCEL, 4
  field :CAPTURE_SESSION_STATE_AGENT_DISCONNECT, 5
  field :CAPTURE_SESSION_STATE_FILTER_ERROR, 6
  field :CAPTURE_SESSION_STATE_INTERFACE_DOWN, 7
  field :CAPTURE_SESSION_STATE_UNKNOWN_REASON, 8
end

defmodule Remotecapture.RemotePacketCaptureClientMessage do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.RemotePacketCaptureClientMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:message, 0)

  field :start, 1, type: Remotecapture.StartRemoteCaptureSession, oneof: 0
  field :block, 2, type: Remotecapture.CaptureBlock, oneof: 0
  field :state, 3, type: Remotecapture.SessionStateChanged, oneof: 0
end

defmodule Remotecapture.RemotePacketCaptureServerMessage do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.RemotePacketCaptureServerMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:message, 0)

  field :ack, 1, type: Remotecapture.CaptureAck, oneof: 0
  field :cancel, 2, type: Remotecapture.CaptureCancel, oneof: 0
end

defmodule Remotecapture.StartRemoteCaptureSession do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.StartRemoteCaptureSession",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :gateway_id, 3, type: :string, json_name: "gatewayId"
  field :actor, 4, type: :string
  field :interface, 5, type: :string
  field :initial_credit_bytes, 6, type: :uint32, json_name: "initialCreditBytes"
end

defmodule Remotecapture.CaptureBlock do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.CaptureBlock",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :bytes, 2, type: :bytes
  field :sequence, 3, type: :uint64
end

defmodule Remotecapture.CaptureAck do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.CaptureAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :gateway_id, 2, type: :string, json_name: "gatewayId"
  field :last_accepted_sequence, 3, type: :uint64, json_name: "lastAcceptedSequence"
  field :credit_bytes, 4, type: :uint32, json_name: "creditBytes"
end

defmodule Remotecapture.CaptureCancel do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.CaptureCancel",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :reason, 2, type: :string
end

defmodule Remotecapture.SessionStateChanged do
  @moduledoc false

  use Protobuf,
    full_name: "remotecapture.SessionStateChanged",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :session_id, 1, type: :string, json_name: "sessionId"
  field :state, 2, type: Remotecapture.CaptureSessionState, enum: true
  field :packets_captured, 3, type: :uint64, json_name: "packetsCaptured"
  field :packets_dropped, 4, type: :uint64, json_name: "packetsDropped"
  field :bytes_streamed, 5, type: :uint64, json_name: "bytesStreamed"
  field :complete, 6, type: :bool
  field :unmapped_reason, 7, type: :string, json_name: "unmappedReason"
end

defmodule Remotecapture.RemotePacketCaptureService.Service do
  @moduledoc false

  use GRPC.Service,
    name: "remotecapture.RemotePacketCaptureService",
    protoc_gen_elixir_version: "0.16.0"

  rpc(
    :StreamCapture,
    stream(Remotecapture.RemotePacketCaptureClientMessage),
    stream(Remotecapture.RemotePacketCaptureServerMessage)
  )
end

defmodule Remotecapture.RemotePacketCaptureService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Remotecapture.RemotePacketCaptureService.Service
end
