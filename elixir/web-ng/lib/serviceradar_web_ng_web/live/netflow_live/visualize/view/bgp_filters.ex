defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.BgpFilters do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  def bgp_community_badge_small(assigns) do
    community_value = assigns.community

    display_text =
      case community_value do
        0xFFFFFF01 ->
          "NO_EXPORT"

        0xFFFFFF02 ->
          "NO_ADVERTISE"

        0xFFFFFF03 ->
          "NO_EXPORT_SUBCONFED"

        0xFFFFFF04 ->
          "NOPEER"

        _ ->
          as_number = Bitwise.bsr(community_value, 16)
          value = Bitwise.band(community_value, 0xFFFF)
          "#{as_number}:#{value}"
      end

    assigns = assign(assigns, :display_text, display_text)

    ~H"""
    <.ui_badge size="xs" variant="info" class="font-mono">{@display_text}</.ui_badge>
    """
  end

  attr(:query, :string, required: true)

  def render(assigns) do
    # Parse current query to extract BGP filters
    as_filter = extract_filter_value(assigns.query, "as_path")
    community_filter = extract_filter_value(assigns.query, "bgp_communities")

    assigns =
      assigns
      |> assign(:as_filter, as_filter)
      |> assign(:community_filter, community_filter)
      |> assign(:has_filters, as_filter != "" || community_filter != "")

    ~H"""
    <div class="space-y-3">
      <div class="text-[11px] text-sr-muted mb-2">
        Filter flows by BGP routing information. Filters are automatically added to your SRQL query.
      </div>

      <!-- Active BGP Filters Display -->
      <div
        :if={@has_filters}
        class="flex items-center gap-2 flex-wrap p-2 bg-sr-brand/5 rounded-md border border-sr-brand/20"
      >
        <span class="text-xs text-sr-muted">Active BGP filters:</span>
        <.ui_badge :if={@as_filter != ""} size="sm" variant="primary" class="gap-1">
          <span>AS Path: {@as_filter}</span>
          <button
            type="button"
            phx-click="srql_builder_remove_filter"
            phx-value-field="as_path"
            class="hover:text-error"
            title="Remove AS filter"
          >
            ✕
          </button>
        </.ui_badge>
        <.ui_badge :if={@community_filter != ""} size="sm" variant="info" class="gap-1">
          <span>Community: {decode_community_display(@community_filter)}</span>
          <button
            type="button"
            phx-click="srql_builder_remove_filter"
            phx-value-field="bgp_communities"
            class="hover:text-error"
            title="Remove community filter"
          >
            ✕
          </button>
        </.ui_badge>
      </div>

      <!-- AS Number Filter Input -->
      <div>
        <label class="text-xs font-semibold text-sr-muted mb-1 block">
          AS Number
        </label>
        <form phx-submit="bgp_add_as_filter" class="flex gap-2">
          <input
            type="number"
            name="as_number"
            placeholder="e.g., 64512"
            min="1"
            max="4294967295"
            class={ui_field_class(size: "sm", mono: true, class: "flex-1 text-xs")}
          />
          <.ui_button type="submit" size="sm" variant="primary">
            Add AS Filter
          </.ui_button>
        </form>
        <div class="mt-1 text-[10px] text-sr-muted">
          Filter flows where AS path contains this autonomous system number
        </div>
      </div>

      <!-- BGP Community Filter Input -->
      <div>
        <label class="text-xs font-semibold text-sr-muted mb-1 block">
          BGP Community
        </label>
        <form phx-submit="bgp_add_community_filter" class="space-y-2">
          <div class="flex gap-2">
            <input
              type="text"
              name="community"
              placeholder="e.g., 65000:100 or 4259840100"
              class={ui_field_class(size: "sm", mono: true, class: "flex-1 text-xs")}
            />
            <.ui_button type="submit" size="sm" variant="info">
              Add Community Filter
            </.ui_button>
          </div>
          <div class="text-[10px] text-sr-muted">
            Enter as AS:value (e.g., 65000:100) or raw 32-bit integer (e.g., 4259840100)
          </div>
        </form>
      </div>

      <!-- Quick filters for well-known communities -->
      <div>
        <label class="text-xs font-semibold text-sr-muted mb-1 block">
          Well-Known Communities
        </label>
        <div class="flex flex-wrap gap-2">
          <.ui_button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967041"
            size="xs"
            variant="outline"
          >
            NO_EXPORT
          </.ui_button>
          <.ui_button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967042"
            size="xs"
            variant="outline"
          >
            NO_ADVERTISE
          </.ui_button>
          <.ui_button
            type="button"
            phx-click="bgp_add_community_filter"
            phx-value-community="4294967043"
            size="xs"
            variant="outline"
          >
            NO_EXPORT_SUBCONFED
          </.ui_button>
        </div>
        <div class="mt-1 text-[10px] text-sr-muted">
          Quick add filters for RFC 1997 well-known communities
        </div>
      </div>

      <!-- Clear all BGP filters -->
      <div :if={@has_filters} class="pt-2">
        <.ui_button
          type="button"
          phx-click="bgp_clear_filters"
          size="sm"
          variant="ghost"
          class="text-error w-full"
        >
          Clear All BGP Filters
        </.ui_button>
      </div>
    </div>
    """
  end

  # Helper function to extract filter value from SRQL query
  def extract_filter_value(query, field) when is_binary(query) do
    # Match patterns like: field:[value] or field:value
    regex = ~r/#{field}:\[?([^\]\s]+)\]?/

    case Regex.run(regex, query) do
      [_, value] -> value
      _ -> ""
    end
  end

  def extract_filter_value(_, _), do: ""

  # Helper function to decode community for display
  def decode_community_display(value) when is_binary(value) do
    case Integer.parse(value) do
      {community_int, ""} ->
        case community_int do
          0xFFFFFF01 ->
            "NO_EXPORT (#{value})"

          0xFFFFFF02 ->
            "NO_ADVERTISE (#{value})"

          0xFFFFFF03 ->
            "NO_EXPORT_SUBCONFED (#{value})"

          _ ->
            as_number = Bitwise.bsr(community_int, 16)
            val = Bitwise.band(community_int, 0xFFFF)
            "#{as_number}:#{val}"
        end

      _ ->
        value
    end
  end

  def decode_community_display(value), do: value
end
