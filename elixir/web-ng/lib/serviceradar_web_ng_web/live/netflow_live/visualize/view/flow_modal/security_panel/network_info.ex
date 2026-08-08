defmodule ServiceRadarWebNGWeb.NetflowLive.Visualize.View.FlowModal.SecurityPanel.NetworkInfo do
  @moduledoc false
  use ServiceRadarWebNGWeb, :html

  import ServiceRadarWebNGWeb.NetflowLive.Visualize.AsnLookup, only: [asn_rir_hint: 1]

  attr(:context, :map, required: true)
  attr(:arin_lookup, :map, default: %{})

  def ipinfo_block(assigns) do
    ~H"""
    <div>
      <div class="font-semibold">ipinfo.io/lite</div>
      <.ipinfo_line label="Source" info={Map.get(@context, :src_ipinfo)} arin_lookup={@arin_lookup} />
      <.ipinfo_line label="Dest" info={Map.get(@context, :dst_ipinfo)} arin_lookup={@arin_lookup} />
    </div>
    """
  end

  attr(:context, :map, required: true)

  def rdns_block(assigns) do
    ~H"""
    <div>
      <div class="font-semibold">rDNS</div>
      <.rdns_line label="Source" rdns={Map.get(@context, :src_rdns)} />
      <.rdns_line label="Dest" rdns={Map.get(@context, :dst_rdns)} />
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:info, :any, default: nil)
  attr(:arin_lookup, :map, default: %{})

  def ipinfo_line(assigns) do
    ~H"""
    <div class="mt-1 text-sr-muted">
      {@label}:
      <%= if @info do %>
        <span class="font-mono">
          {Enum.join(
            Enum.filter([@info.city, @info.region, @info.country_code], &(&1 && &1 != "")),
            ", "
          )}
          <%= if is_integer(@info.as_number) and @info.as_number > 0 do %>
            <button
              type="button"
              phx-click="netflow_lookup_asn"
              phx-value-asn={@info.as_number}
              phx-value-rir-hint={asn_rir_hint(Map.get(@info, :country_code))}
              class={[
                "ml-2 font-mono underline decoration-dotted underline-offset-2 hover:text-sr-brand",
                Map.get(@arin_lookup, :asn) == @info.as_number && "text-sr-brand"
              ]}
            >
              AS{@info.as_number}
            </button>
          <% end %>
          <span
            :if={is_binary(@info.as_name) and @info.as_name != ""}
            class="ml-2 text-sr-muted"
          >
            {@info.as_name}
          </span>
        </span>
      <% else %>
        <span class="text-sr-muted">n/a</span>
      <% end %>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:rdns, :any, default: nil)

  def rdns_line(assigns) do
    ~H"""
    <div class="mt-1 text-sr-muted">
      {@label}:
      <span class="font-mono">
        <%= if @rdns && @rdns.status == "ok" && is_binary(@rdns.hostname) && @rdns.hostname != "" do %>
          {@rdns.hostname}
        <% else %>
          <span class="text-sr-muted">n/a</span>
        <% end %>
      </span>
    </div>
    """
  end
end
