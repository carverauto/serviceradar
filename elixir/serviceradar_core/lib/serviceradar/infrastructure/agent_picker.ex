defmodule ServiceRadar.Infrastructure.AgentPicker do
  @moduledoc """
  Bounded application boundary for sweep-group agent-picker reads.

  This module intentionally exposes no sort or page-size input. Callers may
  advance only with the opaque keyset cursors returned by the preceding page.
  """

  alias Ash.Page.Keyset
  alias ServiceRadar.Infrastructure.Agent

  @page_size 50

  @type cursor_selector :: :first | {:after, String.t()} | {:before, String.t()}

  @spec page(map(), String.t(), cursor_selector()) ::
          {:ok, Keyset.t()} | {:error, Ash.Error.t()}
  def page(scope, search, selector \\ :first) when is_map(scope) and is_binary(search) do
    Agent
    |> Ash.Query.for_read(:agent_picker, %{search: normalize_search(search)})
    |> Ash.read(scope: scope, page: page_options(selector))
    |> normalize_page_cursors()
  end

  defp page_options(:first), do: [limit: @page_size]

  defp page_options({:after, cursor}) when is_binary(cursor),
    do: [limit: @page_size, after: cursor]

  defp page_options({:before, cursor}) when is_binary(cursor),
    do: [limit: @page_size, before: cursor]

  defp normalize_page_cursors({:ok, %Keyset{results: results} = page}) do
    {:ok,
     %{
       page
       | after: results |> List.last() |> keyset(),
         before: results |> List.first() |> keyset()
     }}
  end

  defp normalize_page_cursors(other), do: other

  defp keyset(nil), do: nil
  defp keyset(record), do: record |> Map.get(:__metadata__, %{}) |> Map.get(:keyset)

  defp normalize_search(search), do: search |> String.trim() |> String.downcase()
end
