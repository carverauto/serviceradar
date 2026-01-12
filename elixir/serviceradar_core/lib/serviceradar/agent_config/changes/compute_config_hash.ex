defmodule ServiceRadar.AgentConfig.Changes.ComputeConfigHash do
  @moduledoc """
  Computes SHA256 hash of the compiled_config for change detection.

  Agents use this hash to determine if their config has changed
  without downloading the full config payload.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :compiled_config) do
      nil ->
        changeset

      compiled_config when is_map(compiled_config) ->
        # Canonicalize JSON for consistent hashing
        canonical_json = Jason.encode!(compiled_config, pretty: false)
        hash = :crypto.hash(:sha256, canonical_json) |> Base.encode16(case: :lower)

        Ash.Changeset.change_attribute(changeset, :content_hash, hash)

      _ ->
        changeset
    end
  end
end
