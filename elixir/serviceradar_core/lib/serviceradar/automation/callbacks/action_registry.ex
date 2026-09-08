defmodule ServiceRadar.Automation.Callbacks.ActionRegistry do
  @moduledoc """
  Closed, versioned registry of reviewed automation callback actions.

  Registry entries are source-controlled security contracts, not runtime
  configuration. An action is usable only when its exact name and version are
  present here. The initial registry deliberately contains one read-only action
  and cannot be extended through playbook, catalog, or request input.
  """

  defmodule Contract do
    @moduledoc false

    @enforce_keys [
      :action,
      :version,
      :request_schema,
      :response_schema,
      :effect,
      :sensitivity,
      :target_binding,
      :credential_rule,
      :principal_types,
      :required_permissions,
      :approval,
      :max_ttl_seconds,
      :max_budget,
      :max_response_bytes,
      :idempotency,
      :audit_schema_version,
      :deployment_maximum
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            action: String.t(),
            version: String.t(),
            request_schema: map(),
            response_schema: map(),
            effect: :read_only,
            sensitivity: :target_scoped_internal,
            target_binding: :exact_execution_snapshot,
            credential_rule: :short_lived_bearer,
            principal_types: [:human | :service_principal],
            required_permissions: [String.t()],
            approval: :current_launch_approval,
            max_ttl_seconds: pos_integer(),
            max_budget: pos_integer(),
            max_response_bytes: pos_integer(),
            idempotency: :one_logical_read_per_child_policy,
            audit_schema_version: String.t(),
            deployment_maximum: map()
          }
  end

  @ssh_ca_bundle_action "remote_access.ssh_ca.bundle.read"
  @ssh_ca_bundle_version "1.0.0"
  @response_schema_path Path.expand(
                          "../../../../priv/automation_callbacks/ssh-ca-bundle-response.schema.json",
                          __DIR__
                        )
  @external_resource @response_schema_path

  @ssh_ca_bundle_request_schema %{
    "$schema" => "http://json-schema.org/draft-07/schema#",
    "$id" => "serviceradar.remote_access.ssh_ca_bundle_request/v1",
    "type" => "object",
    "additionalProperties" => false,
    "required" => [
      "action",
      "schema_version",
      "manifest_sha256",
      "job_id",
      "phase",
      "operation",
      "state"
    ],
    "properties" => %{
      "action" => %{"const" => @ssh_ca_bundle_action},
      "schema_version" => %{"const" => "serviceradar.remote_access.ssh_ca_bundle/v1"},
      "manifest_sha256" => %{"type" => "string", "pattern" => "^[a-f0-9]{64}$"},
      "job_id" => %{"type" => "integer", "minimum" => 1},
      "phase" => %{"enum" => ["preflight", "stage", "verify", "commit"]},
      "operation" => %{"enum" => ["enroll", "overlap", "retire", "remove"]},
      "state" => %{"enum" => ["present", "absent"]}
    }
  }

  @ssh_ca_bundle_response_schema @response_schema_path
                                 |> File.read!()
                                 |> Jason.decode!()

  @contracts %{
    {@ssh_ca_bundle_action, @ssh_ca_bundle_version} =>
      struct!(Contract,
        action: @ssh_ca_bundle_action,
        version: @ssh_ca_bundle_version,
        request_schema: @ssh_ca_bundle_request_schema,
        response_schema: @ssh_ca_bundle_response_schema,
        effect: :read_only,
        sensitivity: :target_scoped_internal,
        target_binding: :exact_execution_snapshot,
        credential_rule: :short_lived_bearer,
        principal_types: [:human, :service_principal],
        required_permissions: [
          "ansible.runs.launch",
          "devices.remote_access.ssh.ca_bundle.read"
        ],
        approval: :current_launch_approval,
        max_ttl_seconds: 600,
        max_budget: 1,
        max_response_bytes: 262_144,
        idempotency: :one_logical_read_per_child_policy,
        audit_schema_version: "serviceradar.automation_callback_audit.v1",
        deployment_maximum: %{
          "operations" => ["enroll"],
          "phases" => ["preflight", "stage", "verify", "commit"],
          "states" => ["present"],
          "max_targets" => 100
        }
      )
  }

  @spec all() :: [Contract.t()]
  def all do
    @contracts
    |> Map.values()
    |> Enum.sort_by(&{&1.action, &1.version})
  end

  @spec fetch(String.t(), String.t()) :: {:ok, Contract.t()} | {:error, :action_not_registered}
  def fetch(action, version) when is_binary(action) and is_binary(version) do
    case Map.fetch(@contracts, {action, version}) do
      {:ok, contract} -> {:ok, contract}
      :error -> {:error, :action_not_registered}
    end
  end

  def fetch(_action, _version), do: {:error, :action_not_registered}

  @spec registered?(String.t(), String.t()) :: boolean()
  def registered?(action, version), do: match?({:ok, _contract}, fetch(action, version))

  @spec required_permissions(String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, :action_not_registered}
  def required_permissions(action, version) do
    with {:ok, contract} <- fetch(action, version), do: {:ok, contract.required_permissions}
  end
end
