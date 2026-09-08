defmodule ServiceRadar.Repo.Migrations.AddUserLocalLoginEnabled do
  @moduledoc """
  Adds `local_login_enabled` to `platform.ng_users` for server-side local-login
  enforcement (vs SSO-only). See `ServiceRadarWebNGWeb.Auth.LoginPolicy`.

  The column defaults to `false` (SSO-only). The UP-only backfill preserves the
  effective behavior at upgrade time so nobody is locked out: every account that has
  a password hash AND whose deployment had password fallback effectively enabled
  (the legacy system-wide `allow_password_fallback`, defaulting to true when unset)
  is granted local login. SSO-only rows (no password hash) stay `false`.

  Note: `allow_password_fallback` is intentionally NOT dropped here — it is retained
  transitionally and only consulted by this backfill. A follow-up migration removes it.
  """

  use Ecto.Migration

  def up do
    # Adding a NOT NULL column with a CONSTANT default (`false`) is a metadata-only
    # change on PostgreSQL >= 11 (no full-table rewrite), so this ALTER takes only a
    # brief ACCESS EXCLUSIVE lock on the small platform.ng_users control-plane table.
    alter table(:ng_users, prefix: "platform") do
      add :local_login_enabled, :boolean, null: false, default: false
    end

    # serviceradar:allow-startup-maintenance - bounded, schema-critical one-time backfill.
    # platform.ng_users is a small control-plane table (user accounts, not a hypertable),
    # so this is a single full-scan UPDATE of a handful of rows in the first-boot Job with
    # no large-table lock/timeout risk. It is required for correctness: it preserves each
    # account's existing login ability on upgrade so the deploy cannot lock anyone out, and
    # it is safe to re-run (it deterministically re-sets the same rows to true).
    #
    # Preserve current behavior: accounts that can log in with a password today keep
    # that ability. `allow_password_fallback` is a singleton flag; COALESCE to true
    # mirrors the legacy default (and the UI/get path that treated missing settings as
    # fallback-enabled) so the upgrade does not lock anyone out.
    execute("""
    UPDATE platform.ng_users
       SET local_login_enabled = true
     WHERE hashed_password IS NOT NULL
       AND COALESCE((SELECT allow_password_fallback FROM platform.auth_settings LIMIT 1), true) = true
    """)
  end

  def down do
    alter table(:ng_users, prefix: "platform") do
      remove :local_login_enabled
    end
  end
end
