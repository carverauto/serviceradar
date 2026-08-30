defmodule ServiceRadar.Infrastructure.Preparations.AgentPicker do
  @moduledoc false

  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    query
    |> Ash.Query.unset(:sort)
    |> Ash.Query.sort(picker_sort_key: :asc, uid: :asc)
    |> Ash.Query.load(gateway: [:partition_id])
    |> maybe_filter(Ash.Query.get_argument(query, :search))
  end

  defp maybe_filter(query, search) do
    case normalize_search(search) do
      "" ->
        query

      normalized ->
        pattern = "%#{normalized}%"

        Ash.Query.filter(
          query,
          expr(
            fragment("? ILIKE ?", name, ^pattern) or
              fragment("? ILIKE ?", uid, ^pattern)
          )
        )
    end
  end

  defp normalize_search(search) when is_binary(search),
    do: search |> String.trim() |> String.downcase()

  defp normalize_search(_search), do: ""
end
