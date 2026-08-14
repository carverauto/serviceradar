defmodule ServiceRadarWebNGWeb.DeviceLive.IndexView.Breakdown do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  attr(:title, :string, required: true)
  attr(:items, :list, required: true)
  attr(:icon, :string, required: true)
  attr(:kind, :string, required: true)
  attr(:filter_field, :string, required: true)
  attr(:empty_text, :string, default: "No data")

  def device_breakdown_card(assigns) do
    items = assigns.items || []
    top_item = List.first(items)
    other_count = items |> Enum.drop(1) |> Enum.reduce(0, fn %{count: c}, acc -> acc + c end)

    top_item_link =
      if top_item do
        breakdown_item_path(assigns.filter_field, top_item.name)
      end

    assigns =
      assigns
      |> assign(:top_item, top_item)
      |> assign(:other_count, other_count)
      |> assign(:item_count, length(items))
      |> assign(:top_item_link, top_item_link)

    ~H"""
    <div class="rounded-xl border border-sr-line bg-sr-surface p-4 h-full min-h-[7rem] hover:shadow-md transition-shadow">
      <div class="flex items-center gap-3">
        <div class="p-2.5 rounded-lg bg-info/10">
          <.icon name={@icon} class="size-5 text-info" />
        </div>
        <div class="flex-1 min-w-0">
          <.link
            :if={@top_item && @top_item_link}
            navigate={@top_item_link}
            class="block group cursor-pointer"
          >
            <div class="flex items-baseline gap-1">
              <span
                class="text-lg font-bold text-sr-ink truncate max-w-[8rem] group-hover:text-sr-brand transition-colors"
                title={@top_item.name}
              >
                {@top_item.name}
              </span>
              <span class="text-sm text-sr-muted">({@top_item.count})</span>
            </div>
            <div class="text-xs text-sr-muted">
              {@title}
              <span :if={@other_count > 0} class="text-sr-muted">
                · +{@item_count - 1} more
              </span>
            </div>
          </.link>
          <div :if={@top_item == nil} class="text-sm text-sr-muted">{@empty_text}</div>
        </div>
        <.ui_icon_button
          :if={@items != []}
          type="button"
          phx-click="open_breakdown_modal"
          phx-value-kind={@kind}
          title={"Browse #{@title}"}
          size="xs"
          variant="ghost"
          class="shrink-0"
        >
          <.icon name="hero-chevron-down" class="size-3" />
        </.ui_icon_button>
      </div>
    </div>
    """
  end

  attr(:modal, :map, required: true)
  attr(:search, :string, default: "")

  def breakdown_modal(assigns) do
    modal = assigns.modal || %{}
    search = assigns.search || ""
    all_items = Map.get(modal, :items, [])
    filtered_items = filter_breakdown_items(all_items, search)

    assigns =
      assigns
      |> assign(:title, Map.get(modal, :title, "Browse"))
      |> assign(:filter_field, Map.get(modal, :filter_field, ""))
      |> assign(:items, filtered_items)
      |> assign(:total_items, length(all_items))
      |> assign(:filtered_count, length(filtered_items))
      |> assign(:search, search)

    ~H"""
    <.ui_modal
      id="device_breakdown_modal"
      size="form"
      on_cancel="close_breakdown_modal"
      box_class="max-w-xl"
    >
      <:title>
        <span class="block">{@title}</span>
        <span class="mt-0.5 block text-xs font-normal text-sr-muted">
          {format_stat_number(@filtered_count)} of {format_stat_number(@total_items)}
        </span>
      </:title>

      <form
        id="device_breakdown_search_form"
        phx-change="breakdown_search"
        phx-submit="breakdown_search"
      >
        <%!--
          Stable id keeps LiveView from remounting this input on every keystroke
          (which was dropping focus after one character). data-dialog-autofocus
          makes DialogTopLayer focus the field when showModal() runs — otherwise
          the close button (earlier in the DOM) steals initial focus.
        --%>
        <input
          id="device_breakdown_search"
          type="search"
          name="q"
          value={@search}
          placeholder="Filter"
          autocomplete="off"
          phx-debounce="150"
          data-dialog-autofocus
          class={ui_field_class(size: "sm", class: "w-full")}
        />
      </form>

      <div class="max-h-[24rem] overflow-y-auto rounded-lg border border-sr-line">
        <div :if={@items == []} class="p-4 text-sm text-sr-muted">
          No matches.
        </div>
        <%= for item <- @items do %>
          <.link
            navigate={breakdown_item_path(@filter_field, item.name)}
            class="flex items-center justify-between gap-3 border-b border-sr-line px-3 py-2 text-sm last:border-b-0 hover:bg-sr-subtle/70"
          >
            <span class="min-w-0 flex-1 truncate text-sr-ink">{item.name}</span>
            <.ui_badge size="sm" variant="ghost" class="shrink-0">{item.count}</.ui_badge>
          </.link>
        <% end %>
      </div>
    </.ui_modal>
    """
  end

  def breakdown_modal_data(title, filter_field, items) do
    %{
      title: title,
      filter_field: filter_field,
      items: items || []
    }
  end

  defp filter_breakdown_items(items, ""), do: items

  defp filter_breakdown_items(items, search) when is_binary(search) do
    needle = search |> String.trim() |> String.downcase()

    if needle == "" do
      items
    else
      Enum.filter(items, fn item ->
        item
        |> Map.get(:name, "")
        |> to_string()
        |> String.downcase()
        |> String.contains?(needle)
      end)
    end
  end

  defp breakdown_item_path(filter_field, name) do
    encoded_query =
      URI.encode(~s|in:devices #{filter_field}:"#{escape_srql_string_value(name)}"|)

    "/devices?q=" <> encoded_query
  end

  defp escape_srql_string_value(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp format_stat_number(n) when is_integer(n) and n >= 1000 do
    n |> Integer.to_string() |> add_stat_commas()
  end

  defp format_stat_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_stat_number(n) when is_float(n), do: n |> trunc() |> format_stat_number()
  defp format_stat_number(_), do: "0"

  defp add_stat_commas(str) do
    str
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
