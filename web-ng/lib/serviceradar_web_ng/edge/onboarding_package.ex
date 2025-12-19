defmodule ServiceRadarWebNG.Edge.OnboardingPackage do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false, source: :package_id}
  @derive {Phoenix.Param, key: :id}
  schema "edge_onboarding_packages" do
    field :label, :string
    field :component_id, :string
    field :component_type, :string
    field :parent_type, :string
    field :parent_id, :string
    field :poller_id, :string
    field :site, :string
    field :status, :string
    field :security_mode, :string
    field :downstream_entry_id, :string
    field :downstream_spiffe_id, :string
    field :selectors, {:array, :string}
    field :checker_kind, :string
    field :checker_config_json, :map
    field :join_token_ciphertext, :string
    field :join_token_expires_at, :utc_datetime
    field :bundle_ciphertext, :string
    field :download_token_hash, :string
    field :download_token_expires_at, :utc_datetime
    field :created_by, :string
    field :created_at, :utc_datetime
    field :updated_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :activated_at, :utc_datetime
    field :activated_from_ip, :string
    field :last_seen_spiffe_id, :string
    field :revoked_at, :utc_datetime
    field :deleted_at, :utc_datetime
    field :deleted_by, :string
    field :deleted_reason, :string
    field :metadata_json, :map
    field :kv_revision, :integer
    field :notes, :string
  end
end
