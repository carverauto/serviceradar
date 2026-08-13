defmodule ServiceRadarWebNG.Dashboards.SystemReports do
  @moduledoc """
  Seeds built-in SRQL report dashboards (issue 4976).

  These are public authored dashboards, not a separate Reports product. Users
  find them in the dashboard library Reports section and can email them with
  the existing schedule UI.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadar.Dashboards.DashboardPanel

  require Ash.Query
  require Logger

  @seed_delay_ms 7_000
  @retry_delay_ms 30_000
  @new_devices_slug "new-devices"
  @new_devices_query "in:devices first_seen:last_30d sort:first_seen:desc limit:200"
  @new_devices_description "Devices first seen in the last 30 days. Schedule this dashboard to email the list."
  @new_devices_panel_title "Recently added devices"

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
    Process.send_after(self(), :seed, Keyword.get(opts, :delay_ms, @seed_delay_ms))
    {:ok, Map.new(opts)}
  end

  @impl true
  def handle_info(:seed, state) do
    case seed_all() do
      {:ok, dashboards} ->
        Enum.each(dashboards, fn dashboard ->
          Logger.info("Seeded system report dashboard #{dashboard.slug}")
        end)

        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Failed to seed system report dashboards: #{inspect(reason)}")
        Process.send_after(self(), :seed, Map.get(state, :retry_delay_ms, @retry_delay_ms))
        {:noreply, state}
    end
  end

  @spec new_devices_query() :: String.t()
  def new_devices_query, do: @new_devices_query

  @spec new_devices_slug() :: String.t()
  def new_devices_slug, do: @new_devices_slug

  @spec seed_all(keyword()) :: {:ok, [AuthoredDashboard.t()]} | {:error, term()}
  def seed_all(opts \\ []) do
    if repo_enabled?() do
      actor = Keyword.get(opts, :actor) || SystemActor.system(:system_reports)

      with {:ok, dashboard} <- ensure_new_devices_report(actor) do
        {:ok, [dashboard]}
      end
    else
      {:error, :repo_not_started}
    end
  end

  @spec ensure_new_devices_report(map()) :: {:ok, AuthoredDashboard.t()} | {:error, term()}
  def ensure_new_devices_report(actor) do
    case existing_new_devices_report(actor) do
      {:ok, dashboard} -> reconcile_new_devices_report(actor, dashboard)
      {:error, :not_found} -> create_new_devices_report(actor)
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_new_devices_report(actor) do
    query =
      AuthoredDashboard
      |> Ash.Query.for_read(:by_slug, %{slug: @new_devices_slug})
      |> Ash.Query.load([:panels])

    case Ash.read_one(query, actor: actor) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, dashboard} -> {:ok, dashboard}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_new_devices_report(actor), do: create_new_devices_report(actor, 0)

  defp create_new_devices_report(_actor, attempts) when attempts >= 8 do
    {:error, :dashboard_ref_generation_failed}
  end

  defp create_new_devices_report(actor, attempts) do
    attrs = %{
      dashboard_ref: Enum.random(1_000_000..9_999_999),
      title: "New devices",
      description: @new_devices_description,
      slug: @new_devices_slug,
      visibility: :public,
      status: :active,
      default_time_range: "last_30d",
      metadata: %{
        "system_report" => true,
        "report_kind" => "new_devices"
      }
    }

    case AuthoredDashboard
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(actor: actor) do
      {:ok, dashboard} ->
        create_new_devices_panel(actor, dashboard)

      {:error, reason} ->
        if unique_dashboard_ref_error?(reason) do
          create_new_devices_report(actor, attempts + 1)
        else
          {:error, reason}
        end
    end
  end

  defp reconcile_new_devices_report(actor, dashboard) do
    with {:ok, dashboard} <- maybe_update_new_devices_dashboard(actor, dashboard) do
      maybe_update_new_devices_panel(actor, dashboard)
    end
  end

  defp maybe_update_new_devices_dashboard(actor, dashboard) do
    attrs =
      %{}
      |> maybe_put(:description, dashboard.description, @new_devices_description)
      |> maybe_put(:default_time_range, dashboard.default_time_range, "last_30d")

    if attrs == %{} do
      {:ok, dashboard}
    else
      dashboard
      |> Ash.Changeset.for_update(:update, attrs)
      |> Ash.update(actor: actor)
    end
  end

  defp maybe_update_new_devices_panel(actor, dashboard) do
    case List.first(List.wrap(dashboard.panels)) do
      nil ->
        create_new_devices_panel(actor, dashboard)

      panel ->
        attrs =
          %{}
          |> maybe_put(:srql_query, panel.srql_query, @new_devices_query)
          |> maybe_put(:title, panel.title, @new_devices_panel_title)

        if attrs == %{} do
          {:ok, dashboard}
        else
          case panel
               |> Ash.Changeset.for_update(:update, attrs)
               |> Ash.update(actor: actor) do
            {:ok, _panel} -> {:ok, dashboard}
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp maybe_put(attrs, _key, current, expected) when current == expected, do: attrs
  defp maybe_put(attrs, key, _current, expected), do: Map.put(attrs, key, expected)

  defp create_new_devices_panel(actor, dashboard) do
    case DashboardPanel
         |> Ash.Changeset.for_create(:create, %{
           dashboard_id: dashboard.id,
           title: @new_devices_panel_title,
           srql_query: @new_devices_query,
           visual_type: :table,
           position: 0
         })
         |> Ash.create(actor: actor) do
      {:ok, _panel} -> {:ok, dashboard}
      {:error, reason} -> {:error, reason}
    end
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
