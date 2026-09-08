defmodule ServiceRadar.Repo.Migrations.AddResourcesToAddonPackages do
  @moduledoc """
  Stores manifest-declared resource limits (addon.yaml `resources`) on native
  add-on packages so the agent supervisor can enforce CPU/memory/task ceilings on
  on-host compute add-ons (e.g. the per-series anomaly add-on). Mirrors the
  existing `requires` JSONB column; an empty object means unbounded.
  """

  use Ecto.Migration

  def change do
    alter table(:addon_packages, prefix: "platform") do
      add(:resources, :map, null: false, default: %{})
    end
  end
end
