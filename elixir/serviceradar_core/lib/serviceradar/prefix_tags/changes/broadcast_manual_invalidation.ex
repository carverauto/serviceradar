defmodule ServiceRadar.PrefixTags.Changes.BroadcastManualInvalidation do
  @moduledoc false

  use Ash.Resource.Change

  alias ServiceRadar.PrefixTags.Loader

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _cs, result ->
      _ =
        try do
          Loader.reload("manual")
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end

      _ = Loader.broadcast_invalidation(%{source: "manual"})
      {:ok, result}
    end)
  end
end
