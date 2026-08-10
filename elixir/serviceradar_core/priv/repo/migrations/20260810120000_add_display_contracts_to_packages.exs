defmodule ServiceRadar.Repo.Migrations.AddDisplayContractsToPackages do
  @moduledoc """
  Persists package-shipped display contract documents so the UI can resolve them
  at runtime instead of compiling a first-party map in.

  Keyed by "<contract_id>@<contract_version>" inside the jsonb object, which is
  how ServiceRadarWebNG.Observability.ContractRegistry looks a contract up.
  Defaults to an empty object so every existing row keeps rendering through the
  compile-time first-party fallback with no backfill.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:plugin_packages, prefix: @prefix) do
      add(:display_contracts, :map, null: false, default: %{})
    end

    alter table(:addon_packages, prefix: @prefix) do
      add(:display_contracts, :map, null: false, default: %{})
    end
  end

  def down do
    alter table(:addon_packages, prefix: @prefix) do
      remove(:display_contracts)
    end

    alter table(:plugin_packages, prefix: @prefix) do
      remove(:display_contracts)
    end
  end
end
