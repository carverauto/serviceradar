defmodule ServiceRadarWebNG.Observability.ContractRegistry do
  @moduledoc """
  Runtime index of the display and config contracts installed packages ship.

  This is what makes the plugin tier genuinely extensible. Before it,
  `ServiceRadarWebNG.Observability.SignalDisplay` resolved contracts from a
  compile-time `File.read!` map over six first-party paths, so a third-party
  package could not ship a renderable contract without a web-ng recompile - the
  `signal_schemas` column packages already persist was never read at render
  time. The compile-time map is still there and still wins nothing it used to
  win; it is now the FALLBACK for packages that ship no contract of their own.

  ## Shape

  Three lookups, all served from one ETS table so a render never touches the
  database:

    * `lookup_signal/4` - the four-part key
      `{producer_id, producer_version, schema_id, schema_version}` a stored event
      or log row carries in `metadata.service_radar.signal_schema`.
    * `lookup_surface/4` - a non-signal surface (`notification_delivery`,
      `notification_channel_health`) bound to a notifier key.
    * `lookup_notifier/2` - the validated `notifications:` manifest entry for a
      `{plugin_package_id, action_key}` pair, which is where a notifier's config
      contract comes from at runtime rather than from the copy taken when the
      provider row was created.

  ## Why a process

  Readers are LiveView mounts, including DISCONNECTED mounts, and a disconnected
  mount must not query. The refresh runs here, on its own schedule; every reader
  does a constant-time ETS read and can never block on the database or on
  another reader. A cold or failed load leaves the table empty, which degrades
  to the compile-time fallback rather than to an error page.

  Only APPROVED packages are indexed. A staged, denied, or revoked package has
  not been reviewed, and a contract is UI the operator sees; letting an
  unreviewed package decide what a settings screen renders would make review
  advisory.
  """

  use GenServer

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.AddonPackage
  alias ServiceRadar.Plugins.DisplayContract
  alias ServiceRadar.Plugins.Manifest
  alias ServiceRadar.Plugins.PluginPackage

  require Ash.Query
  require Logger

  @table :serviceradar_display_contracts
  @refresh_interval_ms to_timeout(minute: 5)
  @max_diagnostics 200

  @type contract :: map()
  @type diagnostic :: %{
          package: String.t(),
          version: String.t(),
          source: String.t(),
          reason: String.t()
        }

  # --- client ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The display contract bound to a stored signal's four-part schema ref."
  @spec lookup_signal(String.t(), String.t(), String.t(), String.t()) :: {:ok, contract()} | :error
  def lookup_signal(producer_id, producer_version, schema_id, schema_version) do
    fetch({:signal, producer_id, producer_version, schema_id, schema_version})
  end

  @doc "The display contract a package ships for a non-signal surface."
  @spec lookup_surface(String.t(), String.t(), String.t(), String.t()) :: {:ok, contract()} | :error
  def lookup_surface(producer_id, producer_version, surface, schema_id) do
    fetch({:surface, producer_id, producer_version, surface, schema_id})
  end

  @doc """
  The validated `notifications:` manifest entry a package declares, by package id
  and notifier key.

  Resolved from the package's CURRENT manifest rather than from the
  `config_schema` copied onto the provider row when it was created, so a package
  upgrade that changes a notifier's configuration reaches the form without the
  operator re-creating the provider.
  """
  @spec lookup_notifier(term(), String.t()) :: {:ok, map()} | :error
  def lookup_notifier(package_id, action_key) when is_binary(action_key) and not is_nil(package_id) do
    fetch({:notifier, to_string(package_id), action_key})
  end

  def lookup_notifier(_package_id, _action_key), do: :error

  @doc "The producer identity (`{id, version}`) of an indexed package."
  @spec package_identity(term()) :: {:ok, {String.t(), String.t()}} | :error
  def package_identity(nil), do: :error

  def package_identity(package_id), do: fetch({:package, to_string(package_id)})

  @doc """
  Contracts an installed package shipped and this node refused, newest load
  first.

  3.5.3 requires a broken contract to be diagnosable rather than merely
  invisible: a package whose contract was rejected renders through the generic
  fallback, and this is where an operator finds out why.
  """
  @spec diagnostics() :: [diagnostic()]
  def diagnostics do
    case fetch(:diagnostics) do
      {:ok, diagnostics} -> diagnostics
      :error -> []
    end
  end

  @doc "When the index was last rebuilt, or `nil` if it never has been."
  @spec loaded_at() :: DateTime.t() | nil
  def loaded_at do
    case fetch(:loaded_at) do
      {:ok, at} -> at
      :error -> nil
    end
  end

  @doc "Rebuild the index now. Synchronous; used by importers and by tests."
  @spec refresh(GenServer.server(), timeout()) :: :ok
  def refresh(server \\ __MODULE__, timeout \\ 30_000) do
    GenServer.call(server, :refresh, timeout)
  catch
    :exit, _reason -> :ok
  end

  @doc "Rebuild the index without waiting."
  @spec refresh_async(GenServer.server()) :: :ok
  def refresh_async(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  catch
    :exit, _reason -> :ok
  end

  # --- pure indexing --------------------------------------------------------

  @doc """
  Build the ETS entries and diagnostics for a list of package records.

  Pure and database-free on purpose: this is the function the "a third-party
  contract renders without a recompile" test exercises, so the property is
  proven without needing a database to prove it.

  A package record is anything exposing `display_contracts`, `signal_schemas`,
  `manifest`, and either `plugin_id` or `addon_id` plus `version`.
  """
  @spec index([struct() | map()]) :: {[{term(), term()}], [diagnostic()]}
  def index(packages) when is_list(packages) do
    Enum.reduce(packages, {[], []}, fn package, {entries, diagnostics} ->
      {package_entries, package_diagnostics} = index_package(package)
      {package_entries ++ entries, package_diagnostics ++ diagnostics}
    end)
  end

  defp index_package(package) do
    producer_id = producer_id(package)
    producer_version = string_value(Map.get(package, :version))

    if is_nil(producer_id) or is_nil(producer_version) do
      {[], []}
    else
      {contract_entries, diagnostics} =
        contract_entries(package, producer_id, producer_version)

      entries =
        [{{:package, to_string(Map.get(package, :id))}, {producer_id, producer_version}}] ++
          contract_entries ++ notifier_entries(package)

      {entries, diagnostics}
    end
  end

  # A contract is re-validated on the way OUT as well as on the way in. The row
  # may have been written by an older release whose validator was weaker, and a
  # renderer that trusted stored data would inherit every rule that release did
  # not have.
  defp contract_entries(package, producer_id, producer_version) do
    package
    |> Map.get(:display_contracts)
    |> case do
      %{} = contracts -> contracts
      _other -> %{}
    end
    |> Enum.sort_by(fn {key, _document} -> to_string(key) end)
    |> Enum.reduce({[], []}, fn {key, document}, {entries, diagnostics} ->
      case DisplayContract.validate(document) do
        {:ok, contract} ->
          {contract_entry(contract, producer_id, producer_version) ++ entries, diagnostics}

        {:error, errors} ->
          diagnostic = %{
            package: producer_id,
            version: producer_version,
            source: to_string(key),
            reason: Enum.join(errors, "; ")
          }

          {entries, [diagnostic | diagnostics]}
      end
    end)
  end

  defp contract_entry(contract, producer_id, producer_version) do
    schema_id = Map.fetch!(contract, "schema_id")
    surface = Map.fetch!(contract, "surface")

    case DisplayContract.signal_binding(contract) do
      {^schema_id, schema_version} ->
        [{{:signal, producer_id, producer_version, schema_id, schema_version}, contract}]

      _other ->
        [{{:surface, producer_id, producer_version, surface, schema_id}, contract}]
    end
  end

  defp notifier_entries(package) do
    package_id = to_string(Map.get(package, :id))

    case Manifest.notification_entries(Map.get(package, :manifest) || %{}) do
      {:ok, entries} ->
        Enum.map(entries, fn entry ->
          {{:notifier, package_id, Map.fetch!(entry, "key")}, entry}
        end)

      {:error, _errors} ->
        []
    end
  end

  defp producer_id(package) do
    string_value(Map.get(package, :plugin_id)) || string_value(Map.get(package, :addon_id))
  end

  defp string_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_value(_value), do: nil

  # --- server ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(Keyword.get(opts, :table, @table), [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    interval = Keyword.get(opts, :refresh_interval_ms, @refresh_interval_ms)

    {:ok, %{table: table, interval: interval}, {:continue, :load}}
  end

  @impl GenServer
  def handle_continue(:load, state) do
    load(state)
    schedule(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:refresh, _from, state) do
    load(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:refresh, state) do
    load(state)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:refresh, state) do
    load(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(%{interval: interval}) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :refresh, interval)
  end

  defp schedule(_state), do: :ok

  # A failed load must not take the registry down: the UI it feeds still has a
  # compile-time fallback, and a crash loop here would restart on the same
  # unreachable database.
  defp load(%{table: table}) do
    {entries, diagnostics} = index(read_packages())

    :ets.delete_all_objects(table)
    :ets.insert(table, entries)
    :ets.insert(table, {:diagnostics, Enum.take(diagnostics, @max_diagnostics)})
    :ets.insert(table, {:loaded_at, DateTime.utc_now()})

    :ok
  rescue
    error ->
      Logger.warning("display contract registry load failed: #{Exception.message(error)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("display contract registry load exited: #{inspect(reason)}")
      :ok
  end

  # The package source is overridable through application configuration, the
  # same escape hatch `ServiceRadarWebNG.Observability.SignalDisplay` already
  # offers for contracts themselves. It exists so the runtime resolution path -
  # not a stand-in for it - can be exercised without a database, and so an
  # operator can pin the index while diagnosing one.
  defp read_packages do
    :serviceradar_web_ng
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:packages)
    |> case do
      nil -> read_approved_packages()
      packages when is_list(packages) -> packages
      source when is_function(source, 0) -> source.()
      _other -> read_approved_packages()
    end
  end

  defp read_approved_packages do
    actor = SystemActor.system(:display_contract_registry)

    read(PluginPackage, actor) ++ read(AddonPackage, actor)
  end

  # An unavailable repo is a normal state here, not an incident: the registry
  # boots with the rest of the supervision tree and refreshes on a timer, so it
  # can legitimately run before the database is reachable. It degrades to an
  # empty index, which degrades to the compile-time fallback.
  defp read(resource, actor) do
    resource
    |> Ash.Query.for_read(:approved)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, packages} -> packages
      {:error, _reason} -> []
    end
  rescue
    error ->
      Logger.debug("display contract registry could not read #{inspect(resource)}: #{Exception.message(error)}")

      []
  end

  defp fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end
end
