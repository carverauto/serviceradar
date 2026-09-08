defmodule ServiceRadar.Repo.Migrations.RepairDefaultAuthSettings do
  @moduledoc """
  Restores the required password-only auth singleton on installations whose
  schema-only baseline skipped the original migration's seed statement.
  """

  use Ecto.Migration

  def up do
    execute """
    INSERT INTO platform.auth_settings (
      id,
      mode,
      is_enabled,
      allow_password_fallback,
      sso_auto_provision
    )
    VALUES (gen_random_uuid(), 'password_only', false, true, false)
    ON CONFLICT DO NOTHING
    """
  end

  # This is a data repair. A rollback must not delete an operator's auth configuration.
  def down, do: :ok
end
