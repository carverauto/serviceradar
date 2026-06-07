defmodule Desktopmedia.OpenDesktopMediaSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.OpenDesktopMediaSessionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :target_id, 5, type: :string, json_name: "targetId"
  field :route_id, 6, type: :string, json_name: "routeId"
  field :lease_token, 7, type: :string, json_name: "leaseToken"

  field :requested_initial_credit_bytes, 8,
    type: :uint32,
    json_name: "requestedInitialCreditBytes"

  field :requested_max_chunk_bytes, 9, type: :uint32, json_name: "requestedMaxChunkBytes"
  field :encoding_hint, 10, type: :string, json_name: "encodingHint"
end

defmodule Desktopmedia.OpenDesktopMediaSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.OpenDesktopMediaSessionResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :accepted, 1, type: :bool
  field :message, 2, type: :string
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :media_session_id, 4, type: :string, json_name: "mediaSessionId"
  field :initial_credit_bytes, 5, type: :uint32, json_name: "initialCreditBytes"
  field :max_chunk_bytes, 6, type: :uint32, json_name: "maxChunkBytes"
  field :max_ack_credit_bytes, 7, type: :uint32, json_name: "maxAckCreditBytes"
  field :lease_expires_at_unix, 8, type: :int64, json_name: "leaseExpiresAtUnix"
end

defmodule Desktopmedia.DesktopMediaClientMessage do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaClientMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:message, 0)

  field :frame, 1, type: Desktopmedia.DesktopMediaFrameChunk, oneof: 0
  field :close, 2, type: Desktopmedia.DesktopMediaStreamClose, oneof: 0
  field :heartbeat, 3, type: Desktopmedia.DesktopMediaHeartbeat, oneof: 0
end

defmodule Desktopmedia.DesktopMediaServerMessage do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaServerMessage",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  oneof(:message, 0)

  field :ack, 1, type: Desktopmedia.DesktopMediaAck, oneof: 0
  field :close, 2, type: Desktopmedia.DesktopMediaStreamClose, oneof: 0
  field :heartbeat, 3, type: Desktopmedia.DesktopMediaHeartbeatAck, oneof: 0
end

defmodule Desktopmedia.DesktopMediaFrameChunk do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaFrameChunk",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :agent_id, 4, type: :string, json_name: "agentId"
  field :sequence, 5, type: :uint64
  field :timestamp_unix_nano, 6, type: :int64, json_name: "timestampUnixNano"
  field :width, 7, type: :uint32
  field :height, 8, type: :uint32
  field :payload_family, 9, type: :string, json_name: "payloadFamily"
  field :encoding, 10, type: :string
  field :metadata, 11, type: :bytes
  field :payload, 12, type: :bytes
  field :flags, 13, type: :uint32
end

defmodule Desktopmedia.DesktopMediaAck do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :gateway_id, 4, type: :string, json_name: "gatewayId"
  field :last_accepted_sequence, 5, type: :uint64, json_name: "lastAcceptedSequence"
  field :credit_bytes, 6, type: :uint32, json_name: "creditBytes"
  field :quality_level, 7, type: :uint32, json_name: "qualityLevel"
  field :pause, 8, type: :bool
  field :resume, 9, type: :bool
  field :close_reason, 10, type: :string, json_name: "closeReason"
end

defmodule Desktopmedia.DesktopMediaHeartbeat do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaHeartbeat",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :agent_id, 4, type: :string, json_name: "agentId"
  field :last_sequence, 5, type: :uint64, json_name: "lastSequence"
  field :sent_bytes, 6, type: :uint64, json_name: "sentBytes"
  field :received_credit_bytes, 7, type: :uint64, json_name: "receivedCreditBytes"
  field :viewer_count, 8, type: :uint32, json_name: "viewerCount"
  field :timestamp_unix, 9, type: :int64, json_name: "timestampUnix"
end

defmodule Desktopmedia.DesktopMediaHeartbeatAck do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaHeartbeatAck",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :accepted, 1, type: :bool
  field :lease_expires_at_unix, 2, type: :int64, json_name: "leaseExpiresAtUnix"
  field :message, 3, type: :string
end

defmodule Desktopmedia.DesktopMediaStreamClose do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.DesktopMediaStreamClose",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :agent_id, 4, type: :string, json_name: "agentId"
  field :gateway_id, 5, type: :string, json_name: "gatewayId"
  field :reason, 6, type: :string
  field :last_sequence, 7, type: :uint64, json_name: "lastSequence"
end

defmodule Desktopmedia.CloseDesktopMediaSessionRequest do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.CloseDesktopMediaSessionRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :desktop_session_id, 1, type: :string, json_name: "desktopSessionId"
  field :media_session_id, 2, type: :string, json_name: "mediaSessionId"
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :agent_id, 4, type: :string, json_name: "agentId"
  field :gateway_id, 5, type: :string, json_name: "gatewayId"
  field :reason, 6, type: :string
end

defmodule Desktopmedia.CloseDesktopMediaSessionResponse do
  @moduledoc false

  use Protobuf,
    full_name: "desktopmedia.CloseDesktopMediaSessionResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :closed, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Desktopmedia.DesktopMediaService.Service do
  @moduledoc false

  use GRPC.Service, name: "desktopmedia.DesktopMediaService", protoc_gen_elixir_version: "0.16.0"

  rpc(
    :OpenDesktopMediaSession,
    Desktopmedia.OpenDesktopMediaSessionRequest,
    Desktopmedia.OpenDesktopMediaSessionResponse
  )

  rpc(
    :StreamDesktopMedia,
    stream(Desktopmedia.DesktopMediaClientMessage),
    stream(Desktopmedia.DesktopMediaServerMessage)
  )

  rpc(:Heartbeat, Desktopmedia.DesktopMediaHeartbeat, Desktopmedia.DesktopMediaHeartbeatAck)

  rpc(
    :CloseDesktopMediaSession,
    Desktopmedia.CloseDesktopMediaSessionRequest,
    Desktopmedia.CloseDesktopMediaSessionResponse
  )
end

defmodule Desktopmedia.DesktopMediaService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Desktopmedia.DesktopMediaService.Service
end
