defmodule ServiceRadar.AgentConfig.Changes.ComputeConfigHash do
  @moduledoc """
  Computes SHA256 hash of the compiled_config for change detection.

  Agents use this hash to determine if their config has changed
  without downloading the full config payload.
  """

  use Ash.Resource.Change

  alias ServiceRadar.AgentConfig.Compiler

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :compiled_config) do
      nil ->
        changeset

      compiled_config when is_map(compiled_config) ->
        Ash.Changeset.change_attribute(
          changeset,
          :content_hash,
          Compiler.content_hash(compiled_config)
        )

      _ ->
        changeset
    end
  end
end
