defmodule ServiceRadar.Repo.Migrations.AddUserGroupMembershipSource do
  @moduledoc """
  Records whether a group membership was created by an operator or by an
  identity-provider group claim.

  Group memberships back access grants, so an identity provider driving them has
  to be able to withdraw them: a user removed from an IdP group should lose the
  membership that group created. Without provenance, withdrawing would also
  remove memberships an operator added by hand, which the IdP knows nothing
  about.

  Existing rows are backfilled to 'manual', correct by construction -- nothing
  could create an IdP-sourced membership before this column existed.

  `UserGroupMembership` sets `migrate? false`, so this table's schema is managed
  by hand-written migrations rather than generated from the resource.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    alter table(:user_group_memberships, prefix: @prefix) do
      add(:source, :text, null: false, default: "manual")
    end

    create(
      constraint(:user_group_memberships, :user_group_memberships_source_check,
        check: "source IN ('manual', 'idp')",
        prefix: @prefix
      )
    )

    # Withdrawal scans for IdP-sourced rows on every sign-in.
    create(
      index(:user_group_memberships, [:user_id, :source],
        where: "source = 'idp'",
        name: :user_group_memberships_idp_by_user_index,
        prefix: @prefix
      )
    )
  end

  def down do
    drop(
      index(:user_group_memberships, [:user_id, :source],
        name: :user_group_memberships_idp_by_user_index,
        prefix: @prefix
      )
    )

    drop(
      constraint(:user_group_memberships, :user_group_memberships_source_check, prefix: @prefix)
    )

    alter table(:user_group_memberships, prefix: @prefix) do
      remove(:source)
    end
  end
end
