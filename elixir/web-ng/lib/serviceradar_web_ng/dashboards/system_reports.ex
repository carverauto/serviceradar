defmodule ServiceRadarWebNG.Dashboards.SystemReports do
  @moduledoc """
  Creates the built-in SRQL dashboard definitions that ship with the product.

  Only definitions are created: an authored dashboard record and its panels,
  each panel holding SRQL text. Nothing about a panel's contents is stored —
  every panel runs its query against live data each time the dashboard is
  loaded.

  These are public authored dashboards, not a separate Reports product. Users
  find them in the dashboard library Reports section and can email them with
  the existing schedule UI.

  ## Definitions are created, never reconciled

  An operator is expected to adopt these dashboards: narrow a panel's SRQL to
  chosen devices, add panels, copy the dashboard. So this module creates a
  definition when it is absent and then leaves it alone. It does not write
  shipped titles, descriptions or queries back over what it finds.

  That is a deliberate reversal. The previous implementation reconciled drifted
  fields, which meant an operator edit to a shipped query was silently restored
  on the next boot — a divergence that only appeared after a restart, long after
  the edit had appeared to succeed.

  The single exception is a dashboard record carrying no panels at all. That is
  an interrupted creation rather than an operator choice, so its panels are
  created.

  Who may edit a definition is enforced by the resources, not here:
  `DashboardPanel` authorizes create/update/destroy on the
  `analytics.dashboards.edit` permission or an explicit per-dashboard grant, and
  fails closed. This module writes as a system actor, which is what lets it
  create the definition at all.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel

  require Ash.Query
  require Logger

  @create_delay_ms 7_000
  @retry_delay_ms 30_000

  @new_devices_slug "new-devices"
  @new_devices_query "in:devices first_seen:last_30d sort:first_seen:desc limit:200"

  @mtr_path_analytics_slug "mtr-path-analytics"

  # Packet loss is a ratio of summed probe counts, never a mean of per-hop
  # percentages: a hop that sent one lost probe must not weigh as much as one
  # that sent five hundred cleanly. Hop latency is weighted by received packets
  # for the same reason. These strings are guarded by
  # `built_in_dashboard_panel_queries_compile` in rust/srql/src/query/mtr_hops.rs,
  # so a grammar change fails a test rather than this dashboard at load time.
  @mtr_loss_query "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr sort:loss:desc limit:20"
  @mtr_latency_query "in:mtr_hops time:last_24h stats:wavg(avg_us, received) as latency by addr sort:latency:desc limit:20"
  @mtr_asn_query "in:mtr_hops time:last_24h asn:>0 stats:loss_ratio(sent, received) as loss by asn sort:loss:desc limit:20"
  @mtr_trend_query "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by time:1h limit:500"

  @dashboards [
    %{
      slug: @new_devices_slug,
      title: "New devices",
      description: "Devices first seen in the last 30 days. Schedule this dashboard to email the list.",
      default_time_range: "last_30d",
      report_kind: "new_devices",
      panels: [
        %{
          title: "Recently added devices",
          srql_query: @new_devices_query,
          visual_type: :table,
          data_binding: %{},
          layout: %{"x" => 0, "y" => 0, "w" => 12, "h" => 8},
          position: 0
        }
      ]
    },
    %{
      slug: @mtr_path_analytics_slug,
      title: "MTR path analytics",
      description:
        "Hop-level packet loss and latency across traced paths. Loss is total lost probes over total sent, not an average of per-hop percentages, so a low-sample hop cannot dominate. Edit a panel's query to scope it to particular devices.",
      default_time_range: "last_24h",
      report_kind: "mtr_path_analytics",
      panels: [
        # Every panel sets an explicit layout. An empty layout is not "let the
        # renderer decide": LayoutHelpers.panel_grid_style/2 defaults a missing
        # layout to x=0, y=0, w=12, h=4, so a dashboard whose panels all omit it
        # places every one of them in the SAME grid cell, stacked, and only one is
        # visible. The builder canvas does its own placement, so the dashboard
        # looks correct there while the view shows a single panel.
        %{
          title: "Highest-loss hops",
          srql_query: @mtr_loss_query,
          visual_type: :bar,
          data_binding: %{"label_field" => "addr", "value_field" => "loss"},
          layout: %{"x" => 0, "y" => 0, "w" => 6, "h" => 5},
          position: 0
        },
        %{
          title: "Highest-latency hops",
          srql_query: @mtr_latency_query,
          visual_type: :bar,
          data_binding: %{"label_field" => "addr", "value_field" => "latency"},
          layout: %{"x" => 6, "y" => 0, "w" => 6, "h" => 5},
          position: 1
        },
        # `asn` is populated only by a GeoLite2 lookup, which carries no private
        # ASNs and no RFC1918 addresses. It is therefore NULL for every internal
        # hop, so this panel is restricted to resolved ASNs and titled as
        # external rather than presented as fleet-wide. On a fleet whose internal
        # BGP runs on private ASNs it will legitimately render empty.
        %{
          title: "Loss by external AS (transit only)",
          srql_query: @mtr_asn_query,
          visual_type: :bar,
          data_binding: %{"label_field" => "asn", "value_field" => "loss"},
          layout: %{"x" => 0, "y" => 5, "w" => 6, "h" => 5},
          position: 2
        },
        %{
          title: "Loss trend",
          srql_query: @mtr_trend_query,
          visual_type: :line,
          data_binding: %{"time_field" => "bucket", "value_field" => "loss"},
          layout: %{"x" => 6, "y" => 5, "w" => 6, "h" => 5},
          position: 3
        }
      ]
    }
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    Process.send_after(self(), :seed, Keyword.get(opts, :delay_ms, @create_delay_ms))
    {:ok, Map.new(opts)}
  end

  @impl true
  def handle_info(:seed, state) do
    case seed_all() do
      {:ok, dashboards} ->
        Enum.each(dashboards, fn dashboard ->
          Logger.info("Built-in dashboard definition present: #{dashboard.slug}")
        end)

        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Failed to create built-in dashboard definitions: #{inspect(reason)}")
        Process.send_after(self(), :seed, Map.get(state, :retry_delay_ms, @retry_delay_ms))
        {:noreply, state}
    end
  end

  @doc "The dashboard definitions that ship with the product."
  @spec dashboard_specs() :: [map()]
  def dashboard_specs, do: @dashboards

  @spec new_devices_query() :: String.t()
  def new_devices_query, do: @new_devices_query

  @spec new_devices_slug() :: String.t()
  def new_devices_slug, do: @new_devices_slug

  @spec mtr_path_analytics_slug() :: String.t()
  def mtr_path_analytics_slug, do: @mtr_path_analytics_slug

  @spec seed_all(keyword()) :: {:ok, [AuthoredDashboard.t()]} | {:error, term()}
  def seed_all(opts \\ []) do
    if repo_enabled?() do
      actor = Keyword.get(opts, :actor) || SystemActor.system(:system_reports)

      @dashboards
      |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
        case ensure_dashboard(actor, spec) do
          {:ok, dashboard} -> {:cont, {:ok, [dashboard | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, dashboards} -> {:ok, Enum.reverse(dashboards)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :repo_not_started}
    end
  end

  @doc """
  Decides what to do about a dashboard definition, given what is already stored.

  Pure, and deliberately separated from the Ash calls so the rule that matters —
  an existing definition is never rewritten — is assertable without a database.

  * `nil` (nothing stored) → `:create`
  * a dashboard with no panels → `:create_panels`, an interrupted creation
  * anything else → `:keep`, because every remaining field is operator-editable

  There is no branch that updates a title, description, time range or panel
  query. That is the point: the previous implementation had one, and it silently
  restored shipped values over operator edits on the next boot.
  """
  @spec definition_action(nil | map()) :: :create | :create_panels | :keep
  def definition_action(nil), do: :create

  def definition_action(dashboard) do
    if Enum.empty?(List.wrap(Map.get(dashboard, :panels))) do
      :create_panels
    else
      :keep
    end
  end

  @doc """
  Ensures one dashboard definition exists, without altering an existing one.
  """
  @spec ensure_dashboard(map(), map()) :: {:ok, AuthoredDashboard.t()} | {:error, term()}
  def ensure_dashboard(actor, spec) do
    case existing_dashboard(actor, spec.slug) do
      {:ok, dashboard} ->
        case definition_action(dashboard) do
          :create_panels -> create_panels(actor, dashboard, spec)
          :keep -> {:ok, dashboard}
        end

      {:error, :not_found} ->
        create_dashboard(actor, spec, 0)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_dashboard(actor, slug) do
    query =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: slug})
      |> Ash.Query.load([:panels])

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, dashboard} -> {:ok, dashboard}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_dashboard(_actor, _spec, attempts) when attempts >= 8 do
    {:error, :dashboard_ref_generation_failed}
  end

  defp create_dashboard(actor, spec, attempts) do
    attrs = %{
      dashboard_ref: Enum.random(1_000_000..9_999_999),
      title: spec.title,
      description: spec.description,
      slug: spec.slug,
      visibility: :public,
      status: :active,
      default_time_range: spec.default_time_range,
      metadata: %{
        "system_report" => true,
        "report_kind" => spec.report_kind
      }
    }

    case AuthoredDashboard
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, dashboard} ->
        create_panels(actor, dashboard, spec)

      {:error, reason} ->
        if unique_dashboard_ref_error?(reason) do
          create_dashboard(actor, spec, attempts + 1)
        else
          {:error, reason}
        end
    end
  end

  defp create_panels(actor, dashboard, spec) do
    Enum.reduce_while(spec.panels, {:ok, dashboard}, fn panel, {:ok, dashboard} ->
      attrs =
        panel
        |> Map.take([:title, :srql_query, :visual_type, :data_binding, :layout, :position])
        |> Map.put(:dashboard_id, dashboard.id)

      case DashboardPanel
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(actor: actor) do
        {:ok, _panel} -> {:cont, {:ok, dashboard}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp unique_dashboard_ref_error?(reason) do
    reason
    |> Exception.message()
    |> String.contains?("authored_dashboards_dashboard_ref")
  rescue
    _ -> false
  end

  defp repo_enabled? do
    Process.whereis(ServiceRadar.Repo) != nil
  end
end
