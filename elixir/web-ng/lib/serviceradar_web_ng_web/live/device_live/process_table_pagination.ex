defmodule ServiceRadarWebNGWeb.DeviceLive.ProcessTablePagination do
  @moduledoc """
  Shared, self-contained helpers for paginating and searching the device-detail
  process tables (the Process Listeners snapshot and the sysmon process table).

  Both tables are rendered from lists that are already in memory by the time the
  component runs, so filtering and pagination happen in-LiveView (client side from
  the database's perspective). The search is a case-insensitive substring match
  across the configured fields; pagination is a simple page/offset window.

  This module also exposes the shared `search_bar/1` and `paginator/1` function
  components so both process tables render an identical toolbar.
  """

  use ServiceRadarWebNGWeb, :html

  @default_page_size 50

  @doc "Default number of rows rendered per page."
  def default_page_size, do: @default_page_size

  @doc """
  Filters `rows` by a case-insensitive substring `search` term applied across the
  values produced by `field_fun`, then returns the requested 1-based `page`.

  Returns a map describing the rendered window:

    * `:rows` - the rows for the current page
    * `:page` - the clamped 1-based page number
    * `:page_count` - total number of pages (at least 1)
    * `:total` - total number of rows before filtering
    * `:filtered_total` - number of rows after filtering
    * `:filtered?` - whether a search term narrowed the list
    * `:page_size` - rows per page
    * `:range_start` / `:range_end` - 1-based row range shown (0 when empty)
  """
  def paginate(rows, search, page, opts \\ []) when is_list(rows) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    field_fun = Keyword.get(opts, :fields, fn _row -> [] end)

    term = normalize_search(search)
    total = length(rows)

    filtered =
      case term do
        nil -> rows
        term -> Enum.filter(rows, &row_matches?(&1, term, field_fun))
      end

    filtered_total = length(filtered)
    page_count = max(div(filtered_total + page_size - 1, page_size), 1)
    page = clamp_page(page, page_count)

    offset = (page - 1) * page_size
    window = filtered |> Enum.drop(offset) |> Enum.take(page_size)

    range_start = if window == [], do: 0, else: offset + 1
    range_end = offset + length(window)

    %{
      rows: window,
      page: page,
      page_count: page_count,
      total: total,
      filtered_total: filtered_total,
      filtered?: term != nil,
      page_size: page_size,
      range_start: range_start,
      range_end: range_end
    }
  end

  @doc "Coerces a user-supplied page param into a positive integer (defaults to 1)."
  def parse_page(value) when is_integer(value) and value > 0, do: value

  def parse_page(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {page, _} when page > 0 -> page
      _ -> 1
    end
  end

  def parse_page(_value), do: 1

  @doc "Normalizes a search term to a trimmed, downcased string or nil when blank."
  def normalize_search(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      term -> term
    end
  end

  def normalize_search(_value), do: nil

  defp row_matches?(row, term, field_fun) do
    row
    |> field_fun.()
    |> List.wrap()
    |> Enum.any?(fn value -> field_contains?(value, term) end)
  end

  defp field_contains?(nil, _term), do: false
  defp field_contains?(value, term) when is_binary(value), do: String.contains?(String.downcase(value), term)
  defp field_contains?(value, term), do: value |> to_string() |> String.downcase() |> String.contains?(term)

  defp clamp_page(page, page_count) when is_integer(page) do
    page |> max(1) |> min(page_count)
  end

  defp clamp_page(_page, _page_count), do: 1

  # ---------------------------------------------------------------------------
  # Shared UI: search bar + paginator
  # ---------------------------------------------------------------------------

  attr(:search, :string, default: "")
  attr(:event, :string, required: true)
  attr(:id, :string, required: true)
  attr(:placeholder, :string, default: "Search processes…")
  attr(:total, :integer, default: 0)
  attr(:filtered_total, :integer, default: 0)
  attr(:filtered?, :boolean, default: false)
  attr(:unit, :string, default: "processes")

  @doc "Case-insensitive search box (phx-change) plus a total/filtered count summary."
  def search_bar(assigns) do
    ~H"""
    <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
      <label
        id={@id}
        class="flex w-full min-h-9 items-center gap-2 rounded-sr-control border border-sr-line bg-sr-control px-3 text-sm shadow-sr-control sm:max-w-xs"
      >
        <.icon name="hero-magnifying-glass" class="h-4 w-4 text-sr-muted" />
        <input
          type="search"
          name="search"
          value={@search}
          placeholder={@placeholder}
          phx-change={@event}
          phx-debounce="200"
          autocomplete="off"
          class="min-w-0 grow bg-transparent text-sr-ink outline-none placeholder:text-sr-muted"
        />
      </label>
      <div class="text-xs text-sr-muted">
        <span :if={@filtered?}>
          {@filtered_total} of {@total} {@unit}
        </span>
        <span :if={not @filtered?}>
          {@total} {@unit}
        </span>
      </div>
    </div>
    """
  end

  attr(:page, :integer, required: true)
  attr(:page_count, :integer, required: true)
  attr(:range_start, :integer, default: 0)
  attr(:range_end, :integer, default: 0)
  attr(:filtered_total, :integer, default: 0)
  attr(:prev_event, :string, required: true)
  attr(:next_event, :string, required: true)
  attr(:unit, :string, default: "processes")

  @doc "Prev/next pager with a showing-N-of-M summary; hidden when a single page."
  def paginator(assigns) do
    ~H"""
    <div
      :if={@page_count > 1}
      class="flex flex-col gap-2 border-t border-sr-line px-4 py-3 text-xs sm:flex-row sm:items-center sm:justify-between"
    >
      <span class="text-sr-muted">
        Showing {@range_start}–{@range_end} of {@filtered_total} {@unit}
      </span>
      <div class="flex items-center gap-1">
        <.ui_button
          type="button"
          size="xs"
          variant="ghost"
          phx-click={@prev_event}
          disabled={@page <= 1}
        >
          <.icon name="hero-chevron-left" class="size-4" /> Prev
        </.ui_button>
        <span class="inline-flex min-h-7 items-center px-2 font-mono text-sr-muted">
          Page {@page} / {@page_count}
        </span>
        <.ui_button
          type="button"
          size="xs"
          variant="ghost"
          phx-click={@next_event}
          disabled={@page >= @page_count}
        >
          Next <.icon name="hero-chevron-right" class="size-4" />
        </.ui_button>
      </div>
    </div>
    """
  end
end
