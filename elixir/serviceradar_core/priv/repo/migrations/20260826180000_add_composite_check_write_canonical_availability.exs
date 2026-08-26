defmodule ServiceRadar.Repo.Migrations.AddCompositeCheckWriteCanonicalAvailability do
  @moduledoc """
  Optional per-check flag to project a composite verdict onto Device.is_available.

  Default false so existing checks keep writing only DeviceCompositeCheckResult.
  """

  use Ecto.Migration

  def up do
    alter table(:composite_checks, prefix: "platform") do
      add :write_canonical_availability, :boolean, null: false, default: false
    end
  end

  def down do
    alter table(:composite_checks, prefix: "platform") do
      remove :write_canonical_availability
    end
  end
end
