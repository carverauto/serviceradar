defmodule ServiceRadar.SNMPProfiles.BuiltinTemplateSeeder do
  @moduledoc """
  Writes the built-in SNMP OID templates on startup.

  See `ServiceRadar.SNMPProfiles.BuiltinTemplates.seed/1`: a template already
  in the database is left alone, so restarting never rewrites one. This seeds
  templates only, never a profile, so a profile the operator deleted stays
  deleted (GitHub #4170).
  """

  use ServiceRadar.DelayedSeeder, callback: :seed

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.SNMPProfiles.BuiltinTemplates

  require Logger

  def seed do
    if repo_enabled?() do
      case BuiltinTemplates.seed(SystemActor.system(:snmp_template_seeder)) do
        {:ok, _created} ->
          :ok

        {:error, reason} ->
          Logger.warning("Built-in SNMP OID templates were not seeded: #{inspect(reason)}")
      end
    end
  end
end
