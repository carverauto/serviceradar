defmodule ServiceRadar.Automation.Ansible.AutomationAwxLaunchPreflightEvidence do
  @moduledoc """
  Append-only, secret-free evidence for one completed AWX live-launch preflight.

  This resource exists before a mutable automation operation or execution. It
  intentionally has no operation/execution attribute, relationship, payload,
  metadata map, raw controller response, or credential field. The durable agent
  command ID and bounded canonical digests are enough to join audit records
  without creating another place where a bearer, controller header, host
  variable, or playbook secret could persist.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}
  @sha256_hex ~r/\A[0-9a-f]{64}\z/

  postgres do
    table "automation_awx_launch_preflight_evidences"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_command: "automation_awx_preflight_evidence_command_uidx"

    references do
      reference :controller, on_delete: :restrict
      reference :binding, on_delete: :restrict
    end

    check_constraints do
      check_constraint :reviewed_launch_snapshot_digest,
                       "automation_awx_preflight_evidence_digest_check",
                       check: """
                       reviewed_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
                       AND preflight_request_digest ~ '^[0-9a-f]{64}$'
                       AND target_snapshot_digest ~ '^[0-9a-f]{64}$'
                       AND controller_security_snapshot_digest ~ '^[0-9a-f]{64}$'
                       AND live_launch_snapshot_digest ~ '^[0-9a-f]{64}$'
                       AND command_result_digest ~ '^[0-9a-f]{64}$'
                       """,
                       message: "must contain only lowercase SHA-256 digests"

      check_constraint :dispatch_agent_id, "automation_awx_preflight_evidence_bounds_check",
        check: """
        dispatch_agent_id <> ''
        AND dispatch_partition_id <> ''
        AND binding_version > 0
        AND expires_at > verified_at
        """,
        message: "must retain bounded command identity and a future expiry"
    end
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_command_id, action: :by_command_id, args: [:command_id]
    define :list_for_binding, action: :for_binding, args: [:binding_id]
    define :record, action: :record
  end

  actions do
    read :read do
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_command_id do
      argument :command_id, :uuid, allow_nil?: false
      get? true
      filter expr(command_id == ^arg(:command_id))
    end

    read :for_binding do
      argument :binding_id, :uuid, allow_nil?: false
      filter expr(binding_id == ^arg(:binding_id))
      prepare build(sort: [verified_at: :desc, inserted_at: :desc])
    end

    create :record do
      primary? true

      accept [
        :command_id,
        :controller_id,
        :dispatch_agent_id,
        :dispatch_partition_id,
        :binding_id,
        :binding_version,
        :approval_id,
        :reviewed_launch_snapshot_digest,
        :preflight_request_digest,
        :target_snapshot_digest,
        :controller_security_snapshot_digest,
        :live_launch_snapshot_digest,
        :command_result_digest,
        :verified_at,
        :expires_at
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_command_id, :for_binding], @view_check)
  end

  validations do
    validate fn changeset, _context ->
      with :ok <- validate_digests(changeset),
           :ok <- validate_dispatch_identity(changeset) do
        validate_expiry(changeset)
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :command_id, :uuid, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true

    attribute :dispatch_agent_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :dispatch_partition_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :binding_id, :uuid, allow_nil?: false, public?: true

    attribute :binding_version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :approval_id, :uuid, allow_nil?: false, public?: true

    attribute :reviewed_launch_snapshot_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :preflight_request_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :target_snapshot_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :controller_security_snapshot_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :live_launch_snapshot_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :command_result_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :verified_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :controller, ServiceRadar.Automation.Ansible.Controller do
      define_attribute? false
      source_attribute :controller_id
      public? true
    end

    belongs_to :binding, ServiceRadar.Automation.Ansible.AwxTemplateBinding do
      define_attribute? false
      source_attribute :binding_id
      public? true
    end
  end

  identities do
    identity :unique_command, [:command_id]
  end

  defp validate_digests(changeset) do
    digest_fields = [
      :reviewed_launch_snapshot_digest,
      :preflight_request_digest,
      :target_snapshot_digest,
      :controller_security_snapshot_digest,
      :live_launch_snapshot_digest,
      :command_result_digest
    ]

    if Enum.all?(digest_fields, &valid_digest?(attribute(changeset, &1))) do
      :ok
    else
      invalid(:reviewed_launch_snapshot_digest, "must be lowercase SHA-256 digests")
    end
  end

  defp validate_dispatch_identity(changeset) do
    agent_id = attribute(changeset, :dispatch_agent_id)
    partition_id = attribute(changeset, :dispatch_partition_id)

    if bounded_text?(agent_id) and bounded_text?(partition_id),
      do: :ok,
      else: invalid(:dispatch_agent_id, "must identify a non-secret dispatch agent and partition")
  end

  defp validate_expiry(changeset) do
    verified_at = attribute(changeset, :verified_at)
    expires_at = attribute(changeset, :expires_at)

    if match?(%DateTime{}, verified_at) and match?(%DateTime{}, expires_at) and
         DateTime.after?(expires_at, verified_at) do
      :ok
    else
      invalid(:expires_at, "must be later than the verified timestamp")
    end
  end

  defp valid_digest?(value), do: is_binary(value) and Regex.match?(@sha256_hex, value)

  defp bounded_text?(value) when is_binary(value) do
    byte_size(value) in 1..255 and String.valid?(value) and String.trim(value) == value and
      not String.contains?(value, ["\n", "\r", "\t", <<0>>])
  end

  defp bounded_text?(_value), do: false

  defp attribute(changeset, name), do: Ash.Changeset.get_attribute(changeset, name)
  defp invalid(field, message), do: {:error, field: field, message: message}
end
