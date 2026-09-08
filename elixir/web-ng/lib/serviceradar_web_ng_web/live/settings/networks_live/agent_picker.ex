defmodule ServiceRadarWebNGWeb.Live.Settings.NetworksLive.AgentPicker do
  @moduledoc """
  Side-effect-free state for the bounded sweep-group agent picker.

  LiveViews own database reads and rendering. This module only retains the
  committed and draft UID selections plus query-bound browse pagination.
  """

  @page_size 50
  @sort_version "agent-picker-name-uid-v1"

  defstruct committed: MapSet.new(),
            draft: MapSet.new(),
            mode: :browse,
            query: "",
            cursor: nil,
            cursor_binding: nil,
            cursor_history: [],
            page: %{results: [], after: nil, before: nil},
            selected_offset: 0,
            selected_error: nil,
            error: nil

  @type t :: %__MODULE__{
          committed: MapSet.t(String.t()),
          draft: MapSet.t(String.t()),
          mode: :browse | :selected,
          query: String.t(),
          cursor: String.t() | nil,
          cursor_binding: %{query: String.t(), sort: String.t()} | nil,
          cursor_history: [String.t() | nil],
          page: %{results: [map()], after: String.t() | nil, before: String.t() | nil},
          selected_offset: non_neg_integer(),
          selected_error: %{reason: term(), retryable?: true} | nil,
          error: %{reason: term(), retryable?: true} | nil
        }

  @spec new(Enumerable.t()) :: t()
  def new(initial_ids) do
    committed = initial_ids |> normalize_ids() |> MapSet.new()
    %__MODULE__{committed: committed, draft: committed}
  end

  @spec open(t()) :: t()
  def open(%__MODULE__{} = state) do
    reset_browse(%{state | draft: state.committed, mode: :browse, selected_offset: 0, selected_error: nil})
  end

  @spec search(t(), term()) :: t()
  def search(%__MODULE__{} = state, text) do
    query = normalize_query(text)

    if query == state.query do
      state
    else
      reset_browse(%{state | query: query})
    end
  end

  @spec loaded(t(), map() | {:error, term()}) :: t()
  def loaded(%__MODULE__{} = state, {:error, reason}) do
    %{state | error: %{reason: reason, retryable?: true}}
  end

  def loaded(%__MODULE__{} = state, %{results: results, after: after_cursor, before: before_cursor})
      when is_list(results) do
    %{
      state
      | page: %{results: results, after: after_cursor, before: before_cursor},
        error: nil
    }
  end

  @spec next_page(t()) :: t()
  def next_page(%__MODULE__{page: %{after: nil}} = state), do: state

  def next_page(%__MODULE__{page: %{after: after_cursor}} = state) do
    %{
      state
      | cursor: after_cursor,
        cursor_binding: %{query: state.query, sort: @sort_version},
        cursor_history: [state.cursor | state.cursor_history],
        error: nil
    }
  end

  @spec previous_page(t()) :: t()
  def previous_page(%__MODULE__{cursor_history: []} = state), do: state

  def previous_page(%__MODULE__{cursor_history: [cursor | history]} = state) do
    %{
      state
      | cursor: cursor,
        cursor_binding: cursor_binding(cursor, state.query),
        cursor_history: history,
        error: nil
    }
  end

  @spec show_selected(t()) :: t()
  def show_selected(%__MODULE__{} = state), do: %{state | mode: :selected, selected_offset: 0, selected_error: nil}

  @spec show_browse(t()) :: t()
  def show_browse(%__MODULE__{} = state), do: %{state | mode: :browse}

  @spec toggle(t(), String.t()) :: t()
  def toggle(%__MODULE__{} = state, uid) when is_binary(uid) do
    draft =
      if MapSet.member?(state.draft, uid) do
        MapSet.delete(state.draft, uid)
      else
        MapSet.put(state.draft, uid)
      end

    clamp_selected_offset(%{state | draft: draft})
  end

  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = state, uid) when is_binary(uid) do
    clamp_selected_offset(%{state | draft: MapSet.delete(state.draft, uid)})
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = state), do: %{state | draft: MapSet.new(), selected_offset: 0, selected_error: nil}

  @spec apply(t()) :: t()
  def apply(%__MODULE__{} = state), do: %{state | committed: state.draft, error: nil, selected_error: nil}

  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = state),
    do: %{state | draft: state.committed, error: nil, selected_offset: 0, selected_error: nil}

  @spec selected_page(t()) :: %{
          uids: [String.t()],
          count: non_neg_integer(),
          offset: non_neg_integer(),
          has_previous?: boolean(),
          has_next?: boolean()
        }
  def selected_page(%__MODULE__{} = state) do
    count = MapSet.size(state.draft)

    uids =
      state.draft
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.slice(state.selected_offset, @page_size)

    %{
      uids: uids,
      count: count,
      offset: state.selected_offset,
      has_previous?: state.selected_offset > 0,
      has_next?: state.selected_offset + @page_size < count
    }
  end

  @spec selected_next_page(t()) :: t()
  def selected_next_page(%__MODULE__{} = state) do
    if selected_page(state).has_next? do
      %{state | selected_offset: state.selected_offset + @page_size, selected_error: nil}
    else
      state
    end
  end

  @spec selected_previous_page(t()) :: t()
  def selected_previous_page(%__MODULE__{} = state) do
    if selected_page(state).has_previous? do
      %{state | selected_offset: max(state.selected_offset - @page_size, 0), selected_error: nil}
    else
      state
    end
  end

  @spec selected_loaded(t(), :ok | {:error, term()}) :: t()
  def selected_loaded(%__MODULE__{} = state, :ok), do: %{state | selected_error: nil}

  def selected_loaded(%__MODULE__{} = state, {:error, reason}) do
    %{state | selected_error: %{reason: reason, retryable?: true}}
  end

  @spec browse_results(t()) :: [map()]
  def browse_results(%__MODULE__{} = state), do: Enum.take(state.page.results, @page_size)

  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  defp clamp_selected_offset(%__MODULE__{} = state) do
    count = MapSet.size(state.draft)
    last_offset = if count == 0, do: 0, else: div(count - 1, @page_size) * @page_size
    %{state | selected_offset: min(state.selected_offset, last_offset)}
  end

  @spec browse_request(t()) :: %{
          search: String.t(),
          selector: :first | {:after, String.t()} | {:before, String.t()}
        }
  def browse_request(%__MODULE__{} = state) do
    %{search: state.query, selector: cursor_selector(state)}
  end

  defp cursor_selector(state) do
    case bound_cursor(state) do
      nil -> :first
      cursor -> {:after, cursor}
    end
  end

  defp bound_cursor(%__MODULE__{cursor: cursor, cursor_binding: %{query: query, sort: @sort_version}, query: query}),
    do: cursor

  defp bound_cursor(_state), do: nil

  defp cursor_binding(nil, _query), do: nil
  defp cursor_binding(_cursor, query), do: %{query: query, sort: @sort_version}

  defp reset_browse(state) do
    %{
      state
      | cursor: nil,
        cursor_binding: nil,
        cursor_history: [],
        page: %{results: [], after: nil, before: nil},
        error: nil
    }
  end

  defp normalize_query(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_query(_value), do: ""

  defp normalize_ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
