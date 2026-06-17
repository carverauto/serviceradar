defmodule ServiceRadar.Repo.Migrations.RetireEndpointInventoryAddon do
  @moduledoc false
  use Ecto.Migration

  @addon_id "endpoint-inventory"

  def up do
    execute("""
    DELETE FROM platform.producer_schedules ps
    USING platform.addon_packages ap
    WHERE ps.addon_package_id = ap.id
      AND ap.addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_assignments aa
    USING platform.addon_packages ap
    WHERE aa.addon_package_id = ap.id
      AND ap.addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_assignments
    WHERE addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_statuses
    WHERE addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_profiles profile
    USING platform.addon_packages ap
    WHERE profile.addon_package_id = ap.id
      AND ap.addon_id = '#{@addon_id}'
    """)

    execute("""
    DELETE FROM platform.addon_packages
    WHERE addon_id = '#{@addon_id}'
    """)
  end

  def down, do: :ok
end
