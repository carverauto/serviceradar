defmodule ServiceRadar.Repo.Migrations.SetRoleProfileFkOnDeleteNull do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE platform.ng_users
    DROP CONSTRAINT IF EXISTS ng_users_role_profile_id_fkey
    """)

    execute("""
    ALTER TABLE platform.ng_users
    ADD CONSTRAINT ng_users_role_profile_id_fkey
    FOREIGN KEY (role_profile_id)
    REFERENCES platform.role_profiles(id)
    ON DELETE SET NULL
    """)
  end

  def down do
    execute("""
    ALTER TABLE platform.ng_users
    DROP CONSTRAINT IF EXISTS ng_users_role_profile_id_fkey
    """)

    execute("""
    ALTER TABLE platform.ng_users
    ADD CONSTRAINT ng_users_role_profile_id_fkey
    FOREIGN KEY (role_profile_id)
    REFERENCES platform.role_profiles(id)
    """)
  end
end
