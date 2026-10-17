defmodule ServiceRadar.Repo.Migrations.GrantCameraViewToCustomRoleProfiles do
  @moduledoc """
  Carries live camera access over to the new `devices.cameras.view` permission.

  Live video used to need only `devices.view`. Built-in role profiles pick the
  new key up from the RBAC catalog when the seeder re-syncs them, but custom
  profiles store their own permission arrays, so without this a custom role that
  could watch cameras before the upgrade would silently lose it.

  Only custom profiles (`system = false`) that grant `devices.view` and do not
  already hold the new key are touched, so re-running is a no-op. An operator
  who wants to withhold live video removes the key from the profile afterwards.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    execute("""
    UPDATE #{@prefix}.role_profiles
    SET permissions = array_append(permissions, 'devices.cameras.view')
    WHERE system = false
      AND 'devices.view' = ANY(permissions)
      AND NOT ('devices.cameras.view' = ANY(permissions))
    """)
  end

  def down do
    execute("""
    UPDATE #{@prefix}.role_profiles
    SET permissions = array_remove(permissions, 'devices.cameras.view')
    WHERE system = false
    """)
  end
end
