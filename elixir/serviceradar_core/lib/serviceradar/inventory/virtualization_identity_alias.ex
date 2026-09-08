defmodule ServiceRadar.Inventory.VirtualizationIdentityAlias do
  @moduledoc """
  Read-compatible aliases from legacy virtualization refs to v3 refs.

  An alias is usable only when `status` is `:resolved` and it has exactly one
  target. Ambiguous and unresolved rows are quarantine evidence; they never
  authorize writes, ownership selection, credential use, or console routing.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @fields [
    :provider,
    :resource_kind,
    :legacy_provider_ref,
    :target_provider_ref,
    :status,
    :reason,
    :candidate_provider_refs,
    :metadata
  ]

  postgres do
    table "virtualization_identity_aliases"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]

    create :create do
      accept @fields
      upsert? true
      upsert_identity :unique_legacy_ref

      upsert_fields [
        :target_provider_ref,
        :status,
        :reason,
        :candidate_provider_refs,
        :metadata,
        :updated_at
      ]
    end

    update :update do
      accept [
        :target_provider_ref,
        :status,
        :reason,
        :candidate_provider_refs,
        :metadata
      ]
    end

    read :by_legacy_ref do
      argument :provider, :string, allow_nil?: false
      argument :resource_kind, :atom, allow_nil?: false
      argument :legacy_provider_ref, :string, allow_nil?: false
      get? true

      filter expr(
               provider == ^arg(:provider) and resource_kind == ^arg(:resource_kind) and
                 legacy_provider_ref == ^arg(:legacy_provider_ref)
             )
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@devices_view_check)
    action_type_with_permission(:create, @devices_update_check)
    action_type_with_permission(:update, @devices_update_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :resource_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:cluster, :host, :guest]
    end

    attribute :legacy_provider_ref, :string do
      allow_nil? false
      public? true
    end

    attribute :target_provider_ref, :string do
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :unresolved
      constraints one_of: [:resolved, :ambiguous, :unresolved]
    end

    attribute :reason, :string do
      public? true
    end

    attribute :candidate_provider_refs, {:array, :string} do
      allow_nil? false
      public? true
      default []
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_legacy_ref, [:provider, :resource_kind, :legacy_provider_ref]
  end
end
