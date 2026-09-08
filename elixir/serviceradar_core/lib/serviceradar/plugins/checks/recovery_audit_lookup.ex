defmodule ServiceRadar.Plugins.Checks.RecoveryAuditLookup do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias ServiceRadar.Actors.SystemActor

  @lookup_component :plugin_assignment_recovery_audit_lookup

  @impl true
  def describe(_opts), do: "legacy-row-authorized plugin recovery audit lookup"

  @impl true
  def match?(actor, _opts, _context) when is_map(actor) do
    expected = SystemActor.system(@lookup_component)

    actor_value(actor, :id) == expected.id and actor_value(actor, :role) == expected.role
  end

  def match?(_actor, _opts, _context), do: false

  defp actor_value(actor, key) do
    Map.get(actor, key) || Map.get(actor, Atom.to_string(key))
  end
end
