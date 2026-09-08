defmodule ServiceRadar.Automation.Ansible.PlaybookContent do
  @moduledoc """
  sha256-deduplicated stdout / stderr blob storage for `PlaybookTaskResult`s.

  Multiple results may reference the same `PlaybookContent` row when their
  output is byte-identical (common for repeated playbook runs against the
  same hosts). RetentionWorker prunes content rows whose ref count reaches
  zero after task-result detail is aged out.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_playbook_contents"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :get_by_sha256, action: :by_sha256, args: [:sha256]
    define :upsert_content, action: :upsert
  end

  actions do
    defaults [:destroy]

    read :read do
      # Primary read so this resource loads via its inbound relationships /
      # default read (task-result stdout/stderr content). See PlaybookRun.
      primary? true
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_sha256 do
      argument :sha256, :string, allow_nil?: false
      get? true
      filter expr(sha256 == ^arg(:sha256))
    end

    create :upsert do
      upsert? true
      upsert_identity :unique_sha256
      accept [:sha256, :payload, :size_bytes, :encoding]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    action_with_permission([:read, :by_id, :by_sha256], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :sha256, :string do
      allow_nil? false
      public? true
      description "Lowercase hex sha256 of payload; idempotency key"
      constraints min_length: 64, max_length: 64
    end

    attribute :payload, :string do
      allow_nil? false
      public? true
      description "Captured output blob"
    end

    attribute :size_bytes, :integer do
      allow_nil? false
      public? true
      constraints min: 0
    end

    attribute :encoding, :atom do
      allow_nil? false
      public? true
      default :utf8
      constraints one_of: [:utf8, :base64]
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_sha256, [:sha256]
  end
end
