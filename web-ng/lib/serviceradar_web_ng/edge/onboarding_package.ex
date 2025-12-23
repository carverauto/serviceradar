defmodule ServiceRadarWebNG.Edge.OnboardingPackage do
  @moduledoc """
  Schema for edge onboarding packages stored in the `edge_onboarding_packages` table.

  This table is schema-owned by Go core (DDL), but Phoenix has full DML access.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type status :: :issued | :delivered | :activated | :revoked | :expired | :deleted
  @type component_type :: :poller | :agent | :checker

  @statuses ~w(issued delivered activated revoked expired deleted)
  @component_types ~w(poller agent checker)
  @security_modes ~w(spire mtls)

  @primary_key {:id, :binary_id, autogenerate: false, source: :package_id}
  @derive {Phoenix.Param, key: :id}
  schema "edge_onboarding_packages" do
    field :label, :string
    field :component_id, :string
    field :component_type, :string, default: "poller"
    field :parent_type, :string
    field :parent_id, :string
    field :poller_id, :string
    field :site, :string
    field :status, :string, default: "issued"
    field :security_mode, :string, default: "spire"
    field :downstream_entry_id, :string
    field :downstream_spiffe_id, :string
    field :selectors, {:array, :string}, default: []
    field :checker_kind, :string
    field :checker_config_json, :map, default: %{}
    field :join_token_ciphertext, :string
    field :join_token_expires_at, :utc_datetime
    field :bundle_ciphertext, :string
    field :download_token_hash, :string
    field :download_token_expires_at, :utc_datetime
    field :created_by, :string, default: "system"
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
    field :metadata_json, :map, default: %{}
    field :kv_revision, :integer
    field :notes, :string
  end

  @create_required ~w(label)a
  @create_optional ~w(
    component_id component_type parent_type parent_id poller_id site
    security_mode selectors checker_kind checker_config_json metadata_json
    notes created_by downstream_spiffe_id
  )a

  @doc """
  Changeset for creating a new edge onboarding package.
  """
  def create_changeset(package, attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    package
    |> cast(attrs, @create_required ++ @create_optional)
    |> validate_required(@create_required)
    |> validate_length(:label, min: 1, max: 255)
    |> validate_inclusion(:component_type, @component_types)
    |> validate_inclusion(:security_mode, @security_modes)
    |> validate_parent_type()
    |> put_change(:id, Ecto.UUID.generate())
    |> put_change(:status, "issued")
    |> put_change(:created_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  Changeset for marking a package as delivered.
  """
  def deliver_changeset(package) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    package
    |> change()
    |> put_change(:status, "delivered")
    |> put_change(:delivered_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  Changeset for revoking a package.
  """
  def revoke_changeset(package, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    package
    |> cast(attrs, [:deleted_reason])
    |> put_change(:status, "revoked")
    |> put_change(:revoked_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  Changeset for soft-deleting a package.
  """
  def delete_changeset(package, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    package
    |> cast(attrs, [:deleted_by, :deleted_reason])
    |> put_change(:status, "deleted")
    |> put_change(:deleted_at, now)
    |> put_change(:updated_at, now)
  end

  @doc """
  Changeset for updating token fields (ciphertext, hash, expiration).
  """
  def token_changeset(package, attrs) do
    package
    |> cast(attrs, [
      :join_token_ciphertext,
      :join_token_expires_at,
      :bundle_ciphertext,
      :download_token_hash,
      :download_token_expires_at,
      :downstream_spiffe_id,
      :downstream_entry_id
    ])
    |> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  defp validate_parent_type(changeset) do
    parent_type = get_change(changeset, :parent_type)

    if parent_type && parent_type != "" do
      validate_inclusion(changeset, :parent_type, @component_types)
    else
      changeset
    end
  end

  # Status helpers
  def statuses, do: @statuses
  def component_types, do: @component_types
  def security_modes, do: @security_modes

  def issued?(package), do: package.status == "issued"
  def delivered?(package), do: package.status == "delivered"
  def activated?(package), do: package.status == "activated"
  def revoked?(package), do: package.status == "revoked"
  def deleted?(package), do: package.status == "deleted"
  def expired?(package), do: package.status == "expired"
end
