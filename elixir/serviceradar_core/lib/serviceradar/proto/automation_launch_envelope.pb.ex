defmodule Monitoring.AutomationLaunchEnvelopeResolveRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AutomationLaunchEnvelopeResolveRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :envelope_ref, 2, type: :string, json_name: "envelopeRef"
  field :command_id, 3, type: :string, json_name: "commandId"
end

defmodule Monitoring.AutomationLaunchEnvelopeResolveResponse do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AutomationLaunchEnvelopeResolveResponse",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :message, 2, type: :string
  field :bearer, 3, type: :bytes
  field :callback_grant_id, 4, type: :string, json_name: "callbackGrantId"
  field :expires_at_unix, 5, type: :int64, json_name: "expiresAtUnix"
  field :idempotency_key, 6, type: :bytes, json_name: "idempotencyKey"
end
