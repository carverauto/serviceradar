defmodule ServiceRadar.Plugins.Checks.RecoveryAuditWriter do
  @moduledoc false

  use Ash.Policy.SimpleCheck

  alias ServiceRadar.Actors.SystemActor

  @writer_component :plugin_assignment_recovery_audit_writer

  @impl true
  def describe(_opts), do: "dedicated plugin assignment recovery audit writer"

  @impl true
  def match?(actor, _opts, _context) when is_map(actor) do
    expected = SystemActor.system(@writer_component)

    actor_value(actor, :id) == expected.id and actor_value(actor, :role) == expected.role
  end

  def match?(_actor, _opts, _context), do: false

  defp actor_value(actor, key) do
    Map.get(actor, key) || Map.get(actor, Atom.to_string(key))
  end
end
