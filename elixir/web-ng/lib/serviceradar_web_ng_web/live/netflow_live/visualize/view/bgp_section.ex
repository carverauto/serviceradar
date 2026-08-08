defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.BgpSection do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.FlowAccess, only: [flow_get: 2]

  def render(assigns) do
    # Extract BGP data from flow
    as_path = flow_get(assigns.flow, ["as_path"]) || []
    bgp_communities = flow_get(assigns.flow, ["bgp_communities"]) || []

    assigns =
      assigns
      |> assign(:as_path, as_path)
      |> assign(:bgp_communities, bgp_communities)
      |> assign(:has_bgp_data, not Enum.empty?(as_path) or not Enum.empty?(bgp_communities))
      |> assign(:as_path_collapsed, length(as_path) > 10)

    ~H"""
    <div class="text-xs uppercase tracking-wider text-sr-muted mb-2">BGP Routing</div>

    <%= if @has_bgp_data do %>
      <!-- AS Path Display -->
      <div :if={length(@as_path) > 0} class="mb-3">
        <div class="text-xs font-semibold text-sr-muted mb-1">AS Path</div>
        <div class="flex items-center gap-1 flex-wrap font-mono text-sm">
          <.as_path_display as_path={@as_path} />
        </div>
      </div>

      <!-- BGP Communities Display -->
      <div :if={length(@bgp_communities) > 0}>
        <div class="text-xs font-semibold text-sr-muted mb-1">BGP Communities</div>
        <div class="flex items-center gap-1 flex-wrap">
          <%= for community <- @bgp_communities do %>
            <.bgp_community_badge community={community} />
          <% end %>
        </div>
      </div>
    <% else %>
      <div class="text-sm text-sr-muted">
        No BGP routing information available for this flow
      </div>
    <% end %>
    """
  end

  attr(:as_path, :list, required: true)

  def as_path_display(assigns) do
    path_length = length(assigns.as_path)

    # If path is long, show first 5, ellipsis, and last 5
    {display_path, show_expand} =
      if path_length > 10 do
        first_five = Enum.take(assigns.as_path, 5)
        last_five = Enum.take(assigns.as_path, -5)
        {first_five ++ [:ellipsis] ++ last_five, true}
      else
        {assigns.as_path, false}
      end

    assigns =
      assigns
      |> assign(:display_path, display_path)
      |> assign(:show_expand, show_expand)
      |> assign(:path_length, path_length)

    ~H"""
    <%= for {item, index} <- Enum.with_index(@display_path) do %>
      <%= if item == :ellipsis do %>
        <span class="text-sr-muted text-xs">
          ... ({@path_length - 10} more ASNs) ...
        </span>
      <% else %>
        <%= if index > 0 and Enum.at(@display_path, index - 1) != :ellipsis do %>
          <span class="text-sr-muted">→</span>
        <% end %>
        <span class="px-2 py-0.5 rounded bg-sr-brand/10 text-sr-brand border border-sr-brand/20">
          AS{item}
        </span>
      <% end %>
    <% end %>
    """
  end

  attr(:community, :integer, required: true)

  def bgp_community_badge(assigns) do
    # Decode BGP community from 32-bit integer to AS:value format
    # Format: (high 16 bits = AS number) : (low 16 bits = value)
    community_value = assigns.community

    {display_text, variant} =
      case community_value do
        # Well-known communities (RFC 1997)
        0xFFFFFF01 ->
          {"NO_EXPORT", "warning"}

        0xFFFFFF02 ->
          {"NO_ADVERTISE", "error"}

        0xFFFFFF03 ->
          {"NO_EXPORT_SUBCONFED", "warning"}

        0xFFFFFF04 ->
          {"NOPEER", "error"}

        # Regular community - decode to AS:value
        _ ->
          as_number = Bitwise.bsr(community_value, 16)
          value = Bitwise.band(community_value, 0xFFFF)
          {"#{as_number}:#{value}", "info"}
      end

    assigns =
      assigns
      |> assign(:display_text, display_text)
      |> assign(:variant, variant)

    ~H"""
    <.ui_badge size="sm" variant={@variant} class="font-mono" title={"Raw value: #{@community}"}>
      {@display_text}
    </.ui_badge>
    """
  end
end
