defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackages do
  @moduledoc """
  Bootstraps dashboard packages that ship as part of the ServiceRadar product.

  These packages still use the same dashboard package and instance resources as
  operator-imported packages, but their renderers are built into the web asset
  pipeline instead of loaded as separate package artifacts.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.DashboardInstance
  alias ServiceRadar.Dashboards.DashboardPackage
  alias ServiceRadar.Dashboards.Manifest
  alias ServiceRadar.Dashboards.PackageImport
  alias ServiceRadar.Plugins.ConfigSchema

  require Ash.Query
  require Logger

  Module.register_attribute(__MODULE__, :sobelow_skip, accumulate: true)

  @seed_delay_ms 5_000
  @retry_delay_ms 30_000
  @service_availability_noc :service_availability_noc
  @security_findings :security_findings
  @endpoint_inventory :endpoint_inventory
  @first_party_dashboard_packages [
    %{
      key: @service_availability_noc,
      dashboard_id: "cloud.serviceradar.service-availability-noc",
      route_slug: "service-availability-noc",
      package_dir: "dashboard-packages/service-availability-noc",
      renderer_artifact: "service-availability-noc",
      first_party_object_key: "first-party://built-in/service-availability-noc",
      default?: true
    },
    %{
      key: @security_findings,
      dashboard_id: "cloud.serviceradar.security-findings",
      route_slug: "security-findings",
      package_dir: "dashboard-packages/security-findings",
      renderer_artifact: "security-findings",
      first_party_object_key: "first-party://built-in/security-findings",
      default?: false
    },
    %{
      key: @endpoint_inventory,
      dashboard_id: "cloud.serviceradar.endpoint-inventory",
      route_slug: "endpoint-inventory",
      package_dir: "dashboard-packages/endpoint-inventory",
      renderer_artifact: "endpoint-inventory",
      first_party_object_key: "first-party://built-in/endpoint-inventory",
      default?: false
    }
  ]
  @supported_first_party_frame_entities ~w(
    dashboards
    devices
    dns_activity
    endpoint_inventory
    endpoint_inventory_packages
    endpoint_inventory_scans
    endpoint_inventory_status
    endpoint_inventory_statuses
    endpoint_packages
    service_availability
    scan_activity
    security_findings
    monitored_services
    slo_evaluations
    services
  )

  @type seed_result :: %{
          package: DashboardPackage.t(),
          instance: DashboardInstance.t()
        }
  @type seed_all_result :: %{
          packages: [seed_result()]
        }

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
      {:ok, %{packages: packages}} ->
        Enum.each(packages, fn %{package: package, instance: instance} ->
          Logger.info("Seeded first-party dashboard #{package.dashboard_id} at /dashboards/#{instance.route_slug}")
        end)

        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Failed to seed first-party dashboards: #{inspect(reason)}")
        Process.send_after(self(), :seed, Map.get(state, :retry_delay_ms, @retry_delay_ms))
        {:noreply, state}
    end
  end

  @doc """
  Ensures bundled first-party dashboard packages are imported and enabled.
  """
  @spec seed_all(keyword()) :: {:ok, seed_all_result()} | {:error, term()}
  def seed_all(opts \\ []) do
    if repo_enabled?() do
      actor = Keyword.get(opts, :actor) || SystemActor.system(:first_party_dashboard_seeder)

      @first_party_dashboard_packages
      |> Enum.reduce_while({:ok, []}, fn definition, {:ok, results} ->
        case ensure_package(definition, Keyword.put(opts, :actor, actor)) do
          {:ok, result} -> {:cont, {:ok, [result | results]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, results} -> {:ok, %{packages: Enum.reverse(results)}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :repo_not_started}
    end
  end

  @spec ensure_service_availability_noc(keyword()) :: {:ok, seed_result()} | {:error, term()}
  def ensure_service_availability_noc(opts \\ []) do
    ensure_package!(opts, @service_availability_noc)
  end

  @spec ensure_security_findings(keyword()) :: {:ok, seed_result()} | {:error, term()}
  def ensure_security_findings(opts \\ []) do
    ensure_package!(opts, @security_findings)
  end

  @spec ensure_endpoint_inventory(keyword()) :: {:ok, seed_result()} | {:error, term()}
  def ensure_endpoint_inventory(opts \\ []) do
    ensure_package!(opts, @endpoint_inventory)
  end

  defp ensure_package!(opts, key) do
    definition =
      Enum.find(@first_party_dashboard_packages, fn definition -> definition.key == key end) ||
        raise ArgumentError, "unknown first-party dashboard package #{inspect(key)}"

    ensure_package(definition, opts)
  end

  defp ensure_package(definition, opts) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:first_party_dashboard_seeder)

    with {:ok, manifest_json} <- read_package(definition, opts),
         {:ok, manifest} <- Manifest.from_json(manifest_json),
         :ok <- validate_first_party_manifest(manifest),
         {:ok, attrs} <- package_attrs(manifest, definition, manifest_json),
         {:ok, package} <- upsert_package(attrs, actor),
         {:ok, package} <- ensure_package_enabled(package, actor),
         {:ok, instance} <- ensure_route_instance(package, actor, definition),
         {:ok, instance} <- maybe_mark_default(instance, actor, definition) do
      {:ok, %{package: package, instance: instance}}
    end
  end

  @sobelow_skip ["Traversal.FileModule"]
  defp read_package(definition, opts) do
    dir = Keyword.get(opts, :package_dir) || default_package_dir(definition)
    manifest_path = Path.join(dir, "manifest.json")

    case File.read(manifest_path) do
      {:ok, manifest_json} -> {:ok, manifest_json}
      {:error, reason} -> {:error, {:first_party_dashboard_asset_unavailable, reason}}
    end
  end

  @doc false
  @spec validate_first_party_manifest(Manifest.t()) :: :ok | {:error, term()}
  def validate_first_party_manifest(%Manifest{data_frames: data_frames}) do
    data_frames
    |> Enum.filter(&Map.get(&1, "required", true))
    |> Enum.reduce_while(:ok, fn frame, :ok ->
      case frame_entity(Map.get(frame, "query")) do
        {:ok, entity} ->
          if entity in @supported_first_party_frame_entities do
            {:cont, :ok}
          else
            {:halt, {:error, {:unsupported_first_party_dashboard_frame_entity, frame["id"], entity}}}
          end

        :error ->
          {:halt, {:error, {:missing_first_party_dashboard_frame_entity, frame["id"]}}}
      end
    end)
  end

  @spec frame_entity(term()) :: {:ok, String.t()} | :error
  defp frame_entity(query) when is_binary(query) do
    case Regex.run(~r/(?:^|\s)in:([a-zA-Z0-9_]+)/, query) do
      [_, entity] -> {:ok, entity}
      _ -> :error
    end
  end

  defp frame_entity(_), do: :error

  defp package_attrs(%Manifest{} = manifest, definition, manifest_json) do
    source_metadata =
      Map.merge(manifest.source || %{}, %{
        "source" => "first_party",
        "route_slug" => definition.route_slug,
        "renderer_artifact" => definition.renderer_artifact
      })

    PackageImport.attrs_from_manifest(
      manifest,
      wasm_object_key: definition.first_party_object_key,
      source_type: :first_party,
      source_ref: service_version(),
      source_manifest_path: Path.join(definition.package_dir, "manifest.json"),
      source_bundle_digest: bundle_digest(manifest_json),
      source_metadata: source_metadata,
      verification_status: "verified",
      verification_error: nil
    )
  end

  defp bundle_digest(manifest_json) when is_binary(manifest_json) do
    :sha256
    |> :crypto.hash(manifest_json)
    |> Base.encode16(case: :lower)
  end

  defp upsert_package(attrs, actor) do
    DashboardPackage
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(actor: actor)
  end

  defp ensure_package_enabled(%DashboardPackage{status: :enabled} = package, _actor), do: {:ok, package}

  defp ensure_package_enabled(%DashboardPackage{status: :revoked}, _actor) do
    {:error, :first_party_dashboard_package_revoked}
  end

  defp ensure_package_enabled(%DashboardPackage{} = package, actor) do
    package
    |> Ash.Changeset.for_update(:enable, %{})
    |> Ash.update(actor: actor)
  end

  defp ensure_route_instance(%DashboardPackage{} = package, actor, definition) do
    case fetch_route_instance(actor, definition) do
      {:ok, nil} ->
        create_route_instance(package, actor, definition)

      {:ok,
       %DashboardInstance{dashboard_package: %DashboardPackage{dashboard_id: dashboard_id}} =
           instance} ->
        if dashboard_id == definition.dashboard_id do
          update_route_instance(instance, package, actor)
        else
          route_conflict = %{
            route_slug: definition.route_slug,
            owner_dashboard_id: dashboard_id
          }

          {:error, {:first_party_dashboard_route_in_use, route_conflict}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_route_instance(actor, definition) do
    DashboardInstance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(route_slug == ^definition.route_slug)
    |> Ash.Query.load(:dashboard_package)
    |> Ash.read_one(actor: actor)
  end

  defp create_route_instance(%DashboardPackage{} = package, actor, definition) do
    settings = ConfigSchema.normalize_params(package.settings_schema || %{}, %{})

    attrs = %{
      dashboard_package_id: package.id,
      name: package.name,
      route_slug: definition.route_slug,
      placement: :dashboard,
      enabled: true,
      settings: settings,
      metadata: %{"source" => "first_party"}
    }

    DashboardInstance
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp update_route_instance(%DashboardInstance{} = instance, %DashboardPackage{} = package, actor) do
    attrs = %{
      dashboard_package_id: package.id,
      name: package.name,
      placement: :dashboard,
      enabled: true,
      metadata: Map.put(instance.metadata || %{}, "source", "first_party")
    }

    instance
    |> Ash.Changeset.for_update(:update, attrs)
    |> Ash.update(actor: actor)
  end

  defp maybe_mark_default(%DashboardInstance{} = instance, _actor, %{default?: false}), do: {:ok, instance}

  defp maybe_mark_default(%DashboardInstance{is_default: true} = instance, _actor, _definition), do: {:ok, instance}

  defp maybe_mark_default(%DashboardInstance{} = instance, actor, _definition) do
    case fetch_default_dashboard_instance(actor) do
      {:ok, nil} ->
        instance
        |> Ash.Changeset.for_update(:update, %{enabled: true, is_default: true})
        |> Ash.update(actor: actor)

      {:ok, %DashboardInstance{id: id}} when id == instance.id ->
        instance
        |> Ash.Changeset.for_update(:update, %{enabled: true, is_default: true})
        |> Ash.update(actor: actor)

      {:ok, %DashboardInstance{}} ->
        {:ok, instance}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_default_dashboard_instance(actor) do
    DashboardInstance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(placement == :dashboard and is_default == true)
    |> Ash.Query.limit(1)
    |> Ash.read_one(actor: actor)
  end

  defp default_package_dir(definition) do
    :serviceradar_web_ng
    |> :code.priv_dir()
    |> case do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("../../priv", __DIR__)
    end
    |> Path.join(definition.package_dir)
  end

  defp service_version do
    case Application.spec(:serviceradar_web_ng, :vsn) do
      nil -> "unknown"
      value -> to_string(value)
    end
  end

  defp repo_enabled? do
    Application.get_env(:serviceradar_core, :repo_enabled, true) != false &&
      is_pid(Process.whereis(ServiceRadar.Repo))
  end
end
