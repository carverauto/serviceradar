defmodule Camera.OpenRelaySessionRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :relay_session_id, 1, type: :string, json_name: "relaySessionId"
  field :agent_id, 2, type: :string, json_name: "agentId"
  field :gateway_id, 3, type: :string, json_name: "gatewayId"
  field :camera_source_id, 4, type: :string, json_name: "cameraSourceId"
  field :stream_profile_id, 5, type: :string, json_name: "streamProfileId"
  field :lease_token, 6, type: :string, json_name: "leaseToken"
  field :codec_hint, 7, type: :string, json_name: "codecHint"
  field :container_hint, 8, type: :string, json_name: "containerHint"
end

defmodule Camera.OpenRelaySessionResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :accepted, 1, type: :bool
  field :message, 2, type: :string
  field :media_ingest_id, 3, type: :string, json_name: "mediaIngestId"
  field :max_chunk_bytes, 4, type: :uint32, json_name: "maxChunkBytes"
  field :lease_expires_at_unix, 5, type: :int64, json_name: "leaseExpiresAtUnix"
end

defmodule Camera.MediaChunk do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :relay_session_id, 1, type: :string, json_name: "relaySessionId"
  field :media_ingest_id, 2, type: :string, json_name: "mediaIngestId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :track_id, 4, type: :string, json_name: "trackId"
  field :payload, 5, type: :bytes
  field :sequence, 6, type: :uint64
  field :pts, 7, type: :int64
  field :dts, 8, type: :int64
  field :keyframe, 9, type: :bool
  field :is_final, 10, type: :bool, json_name: "isFinal"
  field :codec, 11, type: :string
  field :payload_format, 12, type: :string, json_name: "payloadFormat"
end

defmodule Camera.UploadMediaResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :received, 1, type: :bool
  field :last_sequence, 2, type: :uint64, json_name: "lastSequence"
  field :message, 3, type: :string
end

defmodule Camera.RelayHeartbeat do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :relay_session_id, 1, type: :string, json_name: "relaySessionId"
  field :media_ingest_id, 2, type: :string, json_name: "mediaIngestId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :last_sequence, 4, type: :uint64, json_name: "lastSequence"
  field :sent_bytes, 5, type: :uint64, json_name: "sentBytes"
  field :viewer_count, 6, type: :uint32, json_name: "viewerCount"
  field :timestamp_unix, 7, type: :int64, json_name: "timestampUnix"
end

defmodule Camera.RelayHeartbeatAck do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :accepted, 1, type: :bool
  field :lease_expires_at_unix, 2, type: :int64, json_name: "leaseExpiresAtUnix"
  field :message, 3, type: :string
end

defmodule Camera.CloseRelaySessionRequest do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :relay_session_id, 1, type: :string, json_name: "relaySessionId"
  field :media_ingest_id, 2, type: :string, json_name: "mediaIngestId"
  field :agent_id, 3, type: :string, json_name: "agentId"
  field :reason, 4, type: :string
end

defmodule Camera.CloseRelaySessionResponse do
  @moduledoc false

  use Protobuf, syntax: :proto3, protoc_gen_elixir_version: "0.16.0"

  field :closed, 1, type: :bool
  field :message, 2, type: :string
end

defmodule Camera.CameraMediaService.Service do
  @moduledoc false

  use GRPC.Service, name: "camera.CameraMediaService", protoc_gen_elixir_version: "0.16.0"

  rpc(:OpenRelaySession, Camera.OpenRelaySessionRequest, Camera.OpenRelaySessionResponse)

  rpc(:UploadMedia, stream(Camera.MediaChunk), Camera.UploadMediaResponse)

  rpc(:Heartbeat, Camera.RelayHeartbeat, Camera.RelayHeartbeatAck)

  rpc(:CloseRelaySession, Camera.CloseRelaySessionRequest, Camera.CloseRelaySessionResponse)
end

defmodule Camera.CameraMediaService.Stub do
  @moduledoc false

  use GRPC.Stub, service: Camera.CameraMediaService.Service
end
