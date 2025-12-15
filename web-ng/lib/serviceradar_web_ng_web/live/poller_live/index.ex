defmodule ServiceRadarWebNGWeb.PollerLive.Index do
  use ServiceRadarWebNGWeb, :live_view

  import ServiceRadarWebNGWeb.UIComponents

  alias Phoenix.LiveView.JS
  alias ServiceRadarWebNGWeb.SRQL.Page, as: SRQLPage

  @default_limit 20
  @max_limit 100

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Pollers")
     |> assign(:pollers, [])
     |> assign(:limit, @default_limit)
     |> SRQLPage.init("pollers", default_limit: @default_limit)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    {:noreply,
     socket
     |> SRQLPage.load_list(params, uri, :pollers,
       default_limit: @default_limit,
       max_limit: @max_limit
     )}
  end

  @impl true
  def handle_event("srql_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_change", params)}
  end

  def handle_event("srql_submit", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_submit", params, fallback_path: "/pollers")}
  end

  def handle_event("srql_builder_toggle", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_toggle", %{}, entity: "pollers")}
  end

  def handle_event("srql_builder_change", params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_change", params)}
  end

  def handle_event("srql_builder_apply", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_apply", %{})}
  end

  def handle_event("srql_builder_run", _params, socket) do
    {:noreply, SRQLPage.handle_event(socket, "srql_builder_run", %{}, fallback_path: "/pollers")}
  end

  def handle_event("srql_builder_add_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_add_filter", params, entity: "pollers")}
  end

  def handle_event("srql_builder_remove_filter", params, socket) do
    {:noreply,
     SRQLPage.handle_event(socket, "srql_builder_remove_filter", params, entity: "pollers")}
  end

  @impl true
  def render(assigns) do
    pagination = get_in(assigns, [:srql, :pagination]) || %{}
    assigns = assign(assigns, :pagination, pagination)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} srql={@srql}>
      <div class="mx-auto max-w-7xl p-6">
        <.ui_panel>
          <:header>
            <div class="min-w-0">
              <span class="text-sm text-base-content/70">
                Click a poller to view full details.
              </span>
            </div>
            <.ui_button variant="ghost" size="xs" patch={~p"/pollers"}>
              Reset
            </.ui_button>
          </:header>

          <.pollers_table id="pollers" pollers={@pollers} />

          <div class="mt-4 pt-4 border-t border-base-200">
            <.ui_pagination
              prev_cursor={Map.get(@pagination, "prev_cursor")}
              next_cursor={Map.get(@pagination, "next_cursor")}
              base_path="/pollers"
              query={Map.get(@srql, :query, "")}
              limit={@limit}
              result_count={length(@pollers)}
            />
          </div>
        </.ui_panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :pollers, :list, default: []

  defp pollers_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm table-zebra w-full">
        <thead>
          <tr>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-48">
              Poller ID
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-24">
              Status
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60 w-40">
              Address
            </th>
            <th class="whitespace-nowrap text-xs font-semibold text-base-content/70 bg-base-200/60">
              Last Seen
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :if={@pollers == []}>
            <td colspan="4" class="text-sm text-base-content/60 py-8 text-center">
              No pollers found.
            </td>
          </tr>

          <%= for {poller, idx} <- Enum.with_index(@pollers) do %>
            <tr
              id={"#{@id}-row-#{idx}"}
              class="hover:bg-base-200/40 cursor-pointer transition-colors"
              phx-click={JS.navigate(~p"/pollers/#{poller_id(poller)}")}
            >
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[12rem]"
                title={poller_id(poller)}
              >
                {poller_id(poller)}
              </td>
              <td class="whitespace-nowrap text-xs">
                <.status_badge active={Map.get(poller, "is_active")} />
              </td>
              <td
                class="whitespace-nowrap text-xs font-mono truncate max-w-[10rem]"
                title={poller_address(poller)}
              >
                {poller_address(poller)}
              </td>
              <td class="whitespace-nowrap text-xs font-mono">
                {format_timestamp(poller)}
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  attr :active, :any, default: nil

  defp status_badge(assigns) do
    {label, variant} =
      case assigns.active do
        true -> {"Active", "success"}
        false -> {"Inactive", "error"}
        _ -> {"Unknown", "ghost"}
      end

    assigns = assign(assigns, :label, label) |> assign(:variant, variant)

    ~H"""
    <.ui_badge variant={@variant} size="xs">{@label}</.ui_badge>
    """
  end

  defp poller_id(poller) do
    Map.get(poller, "poller_id") || Map.get(poller, "id") || "unknown"
  end

  defp poller_address(poller) do
    Map.get(poller, "address") ||
      Map.get(poller, "poller_address") ||
      Map.get(poller, "host") ||
      Map.get(poller, "hostname") ||
      Map.get(poller, "ip") ||
      Map.get(poller, "ip_address") ||
      "—"
  end

  defp format_timestamp(poller) do
    ts = Map.get(poller, "last_seen") || Map.get(poller, "updated_at")

    case parse_timestamp(ts) do
      {:ok, dt} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
      _ -> ts || "—"
    end
  end

  defp parse_timestamp(nil), do: :error
  defp parse_timestamp(""), do: :error

  defp parse_timestamp(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_timestamp(_), do: :error
end
