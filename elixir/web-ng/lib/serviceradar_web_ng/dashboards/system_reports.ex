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
  alias ServiceRadarWebNG.Dashboards.DefinitionLoader

  require Ash.Query
  require Logger

  @create_delay_ms 7_000
  @retry_delay_ms 30_000

  # Dashboards are no longer described here. They are declarative JSON definitions
  # under priv/dashboards, loaded and validated at runtime by DefinitionLoader.
  # Amending or adding a built-in dashboard is a data change, not a code change,
  # and the same format is what an operator exports from the builder.

  @panel_attribute_keys [
    :title,
    :srql_query,
    :visual_type,
    :data_binding,
    :layout,
    :position,
    :display_config,
    :visual_config
  ]

  @new_devices_slug "new-devices"
  @mtr_path_analytics_slug "mtr-path-analytics"

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

  @doc "The dashboard definitions that ship with the product, loaded from priv."
  @spec dashboard_specs() :: [map()]
  def dashboard_specs do
    DefinitionLoader.load_all().definitions
  end

  @doc "The map keys accepted when persisting a panel spec. Keys not in this list are silently dropped by Map.take/2 in create_panels/3."
  @spec panel_attribute_keys() :: [atom()]
  def panel_attribute_keys, do: @panel_attribute_keys

  @doc "Load errors for the shipped definitions, so a test can assert there are none."
  @spec definition_errors() :: [String.t()]
  def definition_errors do
    DefinitionLoader.load_all().errors
  end

  @spec new_devices_query() :: String.t() | nil
  def new_devices_query do
    case Enum.find(dashboard_specs(), &(&1.slug == @new_devices_slug)) do
      %{panels: [%{srql_query: query} | _]} -> query
      _ -> nil
    end
  end

  @spec new_devices_slug() :: String.t()
  def new_devices_slug, do: @new_devices_slug

  @spec mtr_path_analytics_slug() :: String.t()
  def mtr_path_analytics_slug, do: @mtr_path_analytics_slug

  @spec seed_all(keyword()) :: {:ok, [AuthoredDashboard.t()]} | {:error, term()}
  def seed_all(opts \\ []) do
    if repo_enabled?() do
      actor = Keyword.get(opts, :actor) || SystemActor.system(:system_reports)

      %{definitions: definitions, errors: errors} = DefinitionLoader.load_all()

      # A malformed definition is logged loudly rather than dropped. A dashboard
      # silently missing from the library gives no hint where to look.
      Enum.each(errors, fn error ->
        Logger.error("Invalid built-in dashboard definition: #{error}")
      end)

      definitions
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
      metadata: spec.metadata
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
        |> Map.take(@panel_attribute_keys)
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
