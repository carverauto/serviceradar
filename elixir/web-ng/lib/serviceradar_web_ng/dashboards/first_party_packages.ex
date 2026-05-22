defmodule ServiceRadarWebNG.Dashboards.FirstPartyPackages do
  @moduledoc """
  Bootstraps dashboard packages that ship as part of the ServiceRadar product.

  These packages still use the same dashboard package and instance resources as
  operator-imported packages, but their renderer artifacts are bundled in
  `priv/` and served from the application release.
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

  @dashboard_id "cloud.serviceradar.service-availability-noc"
  @route_slug "service-availability-noc"
  @package_dir "dashboard-packages/service-availability-noc"
  @renderer_artifact "renderer.js"
  @first_party_object_key "first-party://dashboard-packages/service-availability-noc/renderer.js"
  @seed_delay_ms 5_000
  @retry_delay_ms 30_000

  @type seed_result :: %{
          package: DashboardPackage.t(),
          instance: DashboardInstance.t()
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
      {:ok, %{package: package, instance: instance}} ->
        Logger.info(
          "Seeded first-party dashboard #{package.dashboard_id} at /dashboards/#{instance.route_slug}"
        )

        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Failed to seed first-party dashboards: #{inspect(reason)}")
        Process.send_after(self(), :seed, Map.get(state, :retry_delay_ms, @retry_delay_ms))
        {:noreply, state}
    end
  end

  @doc """
  Ensures the bundled Service Availability NOC dashboard is imported and enabled.
  """
  @spec seed_all(keyword()) :: {:ok, seed_result()} | {:error, term()}
  def seed_all(opts \\ []) do
    if repo_enabled?() do
      ensure_service_availability_noc(opts)
    else
      {:error, :repo_not_started}
    end
  end

  @spec ensure_service_availability_noc(keyword()) :: {:ok, seed_result()} | {:error, term()}
  def ensure_service_availability_noc(opts \\ []) do
    actor = Keyword.get(opts, :actor) || SystemActor.system(:first_party_dashboard_seeder)

    with {:ok, manifest_json, renderer} <- read_package(opts),
         {:ok, manifest} <- Manifest.from_json(manifest_json),
         :ok <- PackageImport.verify_artifact_digest(renderer, manifest),
         {:ok, attrs} <- package_attrs(manifest, opts),
         {:ok, package} <- upsert_package(attrs, actor),
         {:ok, package} <- ensure_package_enabled(package, actor),
         {:ok, instance} <- ensure_route_instance(package, actor),
         {:ok, instance} <- maybe_mark_default(instance, actor) do
      {:ok, %{package: package, instance: instance}}
    end
  end

  @doc """
  Returns the bundled renderer for a first-party dashboard package.
  """
  @spec fetch_renderer(DashboardPackage.t(), keyword()) ::
          {:ok, {:binary, binary()}} | {:error, term()}
  def fetch_renderer(package, opts \\ [])

  def fetch_renderer(
        %DashboardPackage{source_type: :first_party, dashboard_id: @dashboard_id} = package,
        opts
      ) do
    with {:ok, _manifest_json, renderer} <- read_package(opts),
         :ok <- verify_package_renderer(package, renderer) do
      {:ok, {:binary, renderer}}
    end
  end

  def fetch_renderer(_package, _opts), do: {:error, :not_first_party}

  defp read_package(opts) do
    dir = Keyword.get(opts, :package_dir) || default_package_dir()
    manifest_path = Path.join(dir, "manifest.json")
    renderer_path = Path.join(dir, @renderer_artifact)

    with {:ok, manifest_json} <- File.read(manifest_path),
         {:ok, renderer} <- File.read(renderer_path) do
      {:ok, manifest_json, renderer}
    else
      {:error, reason} -> {:error, {:first_party_dashboard_asset_unavailable, reason}}
    end
  end

  defp package_attrs(%Manifest{} = manifest, opts) do
    source_metadata =
      Map.merge(manifest.source || %{}, %{
        "source" => "first_party",
        "route_slug" => @route_slug,
        "renderer_artifact" => @renderer_artifact
      })

    PackageImport.attrs_from_manifest(
      manifest,
      wasm_object_key: @first_party_object_key,
      source_type: :first_party,
      source_ref: service_version(),
      source_manifest_path: Path.join(@package_dir, "manifest.json"),
      source_bundle_digest: bundle_digest(opts),
      source_metadata: source_metadata,
      verification_status: "verified",
      verification_error: nil
    )
  end

  defp bundle_digest(opts) do
    case read_package(opts) do
      {:ok, manifest_json, renderer} ->
        :sha256
        |> :crypto.hash(manifest_json <> renderer)
        |> Base.encode16(case: :lower)

      {:error, _reason} ->
        nil
    end
  end

  defp upsert_package(attrs, actor) do
    DashboardPackage
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(actor: actor)
  end

  defp ensure_package_enabled(%DashboardPackage{status: :enabled} = package, _actor),
    do: {:ok, package}

  defp ensure_package_enabled(%DashboardPackage{status: :revoked}, _actor) do
    {:error, :first_party_dashboard_package_revoked}
  end

  defp ensure_package_enabled(%DashboardPackage{} = package, actor) do
    package
    |> Ash.Changeset.for_update(:enable, %{})
    |> Ash.update(actor: actor)
  end

  defp ensure_route_instance(%DashboardPackage{} = package, actor) do
    case fetch_route_instance(actor) do
      {:ok, nil} ->
        create_route_instance(package, actor)

      {:ok,
       %DashboardInstance{dashboard_package: %DashboardPackage{dashboard_id: @dashboard_id}} =
           instance} ->
        update_route_instance(instance, package, actor)

      {:ok, %DashboardInstance{dashboard_package: %DashboardPackage{dashboard_id: owner}}} ->
        {:error,
         {:first_party_dashboard_route_in_use,
          %{route_slug: @route_slug, owner_dashboard_id: owner}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_route_instance(actor) do
    DashboardInstance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(route_slug == ^@route_slug)
    |> Ash.Query.load(:dashboard_package)
    |> Ash.read_one(actor: actor)
  end

  defp create_route_instance(%DashboardPackage{} = package, actor) do
    settings = ConfigSchema.normalize_params(package.settings_schema || %{}, %{})

    attrs = %{
      dashboard_package_id: package.id,
      name: package.name,
      route_slug: @route_slug,
      placement: :dashboard,
      enabled: true,
      settings: settings,
      metadata: %{"source" => "first_party"}
    }

    DashboardInstance
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(actor: actor)
  end

  defp update_route_instance(
         %DashboardInstance{} = instance,
         %DashboardPackage{} = package,
         actor
       ) do
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

  defp maybe_mark_default(%DashboardInstance{is_default: true} = instance, _actor),
    do: {:ok, instance}

  defp maybe_mark_default(%DashboardInstance{} = instance, actor) do
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

  defp verify_package_renderer(%DashboardPackage{content_hash: hash}, renderer)
       when is_binary(hash) do
    actual =
      :sha256
      |> :crypto.hash(renderer)
      |> Base.encode16(case: :lower)

    if String.downcase(hash) == actual do
      :ok
    else
      {:error, :digest_mismatch}
    end
  end

  defp verify_package_renderer(_package, _renderer), do: {:error, :missing_content_hash}

  defp default_package_dir do
    :serviceradar_web_ng
    |> :code.priv_dir()
    |> case do
      path when is_list(path) -> List.to_string(path)
      {:error, _reason} -> Path.expand("../../priv", __DIR__)
    end
    |> Path.join(@package_dir)
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
