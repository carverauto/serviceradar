defmodule ServiceRadar.Repo.Migrations.AddRoleProfileSource do
  @moduledoc """
  Records whether a user's role profile was assigned by an operator or granted
  by an identity-provider group mapping.

  Removing a user from an IdP group should revoke what that group granted. That
  requires knowing which grants came from the IdP: clearing every profile when
  no mapping matches would also wipe a profile an admin assigned by hand to
  someone who has no mapping at all.

  Existing rows are backfilled to 'manual', which is correct by construction --
  before this column, nothing could assign a profile from an identity provider.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:ng_users, prefix: @prefix) do
      add(:role_profile_source, :text, null: false, default: "manual")
    end

    create(
      constraint(:ng_users, :ng_users_role_profile_source_check,
        check: "role_profile_source IN ('manual', 'idp')",
        prefix: @prefix
      )
    )

    # A row claiming an IdP-granted profile without a profile is contradictory,
    # and would make revocation a no-op that looks like it worked.
    create(
      constraint(:ng_users, :ng_users_idp_profile_requires_profile_check,
        check: "role_profile_source <> 'idp' OR role_profile_id IS NOT NULL",
        prefix: @prefix
      )
    )
  end

  def down do
    drop(constraint(:ng_users, :ng_users_idp_profile_requires_profile_check, prefix: @prefix))
    drop(constraint(:ng_users, :ng_users_role_profile_source_check, prefix: @prefix))

    alter table(:ng_users, prefix: @prefix) do
      remove(:role_profile_source)
    end
  end
end
