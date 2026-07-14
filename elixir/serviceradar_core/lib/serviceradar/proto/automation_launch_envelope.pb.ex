defmodule Monitoring.AutomationLaunchEnvelopeResolveRequest do
  @moduledoc false

  use Protobuf,
    full_name: "monitoring.AutomationLaunchEnvelopeResolveRequest",
    protoc_gen_elixir_version: "0.16.0",
    syntax: :proto3

  field :agent_id, 1, type: :string, json_name: "agentId"
  field :envelope_ref, 2, type: :string, json_name: "envelopeRef"
  field :command_id, 3, type: :string, json_name: "commandId"
  field :partition_id, 4, type: :string, json_name: "partitionId"
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
  field :callback_url, 7, type: :bytes, json_name: "callbackUrl"
  field :callback_allowed_origin, 8, type: :bytes, json_name: "callbackAllowedOrigin"
  field :manifest_sha256, 9, type: :bytes, json_name: "manifestSha256"
  field :scm_revision, 10, type: :bytes, json_name: "scmRevision"
  field :content_sha256, 11, type: :bytes, json_name: "contentSha256"
  field :callback_phase, 12, type: :bytes, json_name: "callbackPhase"
  field :callback_operation, 13, type: :bytes, json_name: "callbackOperation"
  field :callback_state, 14, type: :bytes, json_name: "callbackState"
  field :controller_id, 15, type: :string, json_name: "controllerId"
  field :inventory_id, 16, type: :int64, json_name: "inventoryId"
  field :job_template_id, 17, type: :int64, json_name: "jobTemplateId"
  field :callback_credential_type_id, 18, type: :int64, json_name: "callbackCredentialTypeId"

  field :callback_credential_organization_id, 19,
    type: :int64,
    json_name: "callbackCredentialOrganizationId"

  field :callback_credential_injector_sha256, 20,
    type: :bytes,
    json_name: "callbackCredentialInjectorSha256"

  field :dispatch_agent_id, 21, type: :string, json_name: "dispatchAgentId"
  field :child_execution_id, 22, type: :string, json_name: "childExecutionId"
  field :command_id, 23, type: :string, json_name: "commandId"
end
