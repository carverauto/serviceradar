defmodule ServiceRadar.Edge.AgentRelease do
  @moduledoc """
  Catalog entry for a publishable agent release.
  """

  use Ash.Resource,
    domain: ServiceRadar.Edge,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Edge.ReleaseManifestValidator

  @release_fields [:version, :manifest, :signature, :release_notes, :published_at, :metadata]

  postgres do
    table("agent_releases")
    repo(ServiceRadar.Repo)
    schema("platform")
  end

  code_interface do
    define(:get_by_id, action: :by_id, args: [:id])
    define(:get_by_version, action: :by_version, args: [:version])
    define(:publish, action: :publish)
  end

  actions do
    defaults([:read])

    read :by_id do
      argument(:id, :uuid, allow_nil?: false)
      get?(true)
      filter(expr(id == ^arg(:id)))
    end

    read :by_version do
      argument(:version, :string, allow_nil?: false)
      get?(true)
      filter(expr(version == ^arg(:version)))
    end

    create :publish do
      accept(@release_fields)
      upsert?(true)
      upsert_identity(:unique_version)

      change(fn changeset, _context ->
        published_at =
          Ash.Changeset.get_attribute(changeset, :published_at) || DateTime.utc_now()

        changeset
        |> ReleaseManifestValidator.add_publish_errors()
        |> Ash.Changeset.change_attribute(:published_at, published_at)
      end)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_operator_plus()
    operator_action(:publish)
  end

  identities do
    identity(:unique_version, [:version])
  end

  attributes do
    uuid_primary_key(:id, source: :release_id)

    attribute :version, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :manifest, :map do
      allow_nil?(false)
      public?(true)
      default(%{})
    end

    attribute :signature, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :release_notes, :string do
      public?(true)
    end

    attribute :published_at, :utc_datetime do
      public?(true)
    end

    attribute :metadata, :map do
      public?(true)
      default(%{})
    end

    timestamps()
  end
end
