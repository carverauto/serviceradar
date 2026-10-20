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

  def breakdown_modal(assigns) do
    modal = assigns.modal

    items =
      Enum.map(modal.items, fn item ->
        %{value: item.name, count: item.count, href: breakdown_item_path(modal.filter_field, item.name)}
      end)

    assigns = assign(assigns, :items_json, Jason.encode!(items))

    ~H"""
    <.ui_modal
      id="device_breakdown_modal"
      size="form"
      on_cancel="close_breakdown_modal"
      box_class="max-w-xl"
    >
      <:title>{@modal.title}</:title>
      <div
        id="device_breakdown_values"
        phx-hook="ValueBrowser"
        phx-update="ignore"
        data-items={@items_json}
      >
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
end
