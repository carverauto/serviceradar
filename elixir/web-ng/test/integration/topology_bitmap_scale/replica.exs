defmodule ServiceRadarWebNG.Topology.Scale.Replica do
  @moduledoc false
  alias ServiceRadar.Inventory.DevicePubSub
  alias ServiceRadar.Repo
  alias ServiceRadar.TopologyAtlas
  alias ServiceRadarWebNG.Auth.Guardian
  alias ServiceRadarWebNG.Topology.BitmapIndex
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.Native
  alias ServiceRadarWebNG.Topology.Scale.Fixture
  alias ServiceRadarWebNG.Topology.Scale.Meter
  alias ServiceRadarWebNG.Topology.TileKey
  alias ServiceRadarWebNG.Topology.WorldCache
  alias ServiceRadarWebNG.Topology.WorldTile
  alias ServiceRadarWebNGWeb.Endpoint

  @supervisor __MODULE__.Supervisor
  @version "00000000-0000-4000-8000-000000000731"

  def start(config, user) do
    for {app, _} <- config, do: Application.load(app)
    Application.put_all_env(config, persistent: true)

    # Serve through the production pool, not the test Sandbox. In :auto mode a
    # querying process owns its connection until it exits, so every long-lived
    # WebSocket that authenticated on connect would pin one; the remaining
    # upgrades were dropped from the queue and refused with 403. Size and queue
    # limits are inherited unchanged.
    repo = Application.fetch_env!(:serviceradar_core, Repo)
    Application.put_env(:serviceradar_core, Repo, Keyword.put(repo, :pool, DBConnection.ConnectionPool))

    for app <- [
          :logger,
          :crypto,
          :ssl,
          :postgrex,
          :ecto_sql,
          :ash_postgres,
          :phoenix,
          :phoenix_pubsub,
          :guardian,
          :bandit
        ] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    Application.put_env(:serviceradar_web_ng, :bitmap_tag_keys, ["cohort", "scale"])
    endpoint = Application.fetch_env!(:serviceradar_web_ng, Endpoint)
    Application.put_env(:serviceradar_web_ng, Endpoint, Keyword.merge(endpoint, server: false, check_origin: false))

    tasks = ServiceRadarWebNG.Topology.BitmapIndexTasks
    tile_tasks = ServiceRadarWebNG.Topology.TileTasks

    children = [
      Repo,
      Meter,
      {Phoenix.PubSub, name: ServiceRadar.PubSub},
      Supervisor.child_spec({Phoenix.PubSub, name: ServiceRadarWebNG.PubSub}, id: :web_pubsub),
      {Task.Supervisor, name: tasks, max_children: 1},
      Supervisor.child_spec({Task.Supervisor, name: tile_tasks, max_children: 4}, id: tile_tasks),
      Supervisor.child_spec({Task.Supervisor, name: ServiceRadarWebNG.Topology.TileWatchTasks, max_children: 64},
        id: :watch_tasks
      ),
      {WorldCache, name: WorldCache, task_supervisor: tile_tasks, pubsub: ServiceRadar.PubSub},
      {BitmapIndex, name: BitmapIndex, task_supervisor: tasks, pubsub: ServiceRadar.PubSub},
      BitmapQueries,
      ServiceRadarWebNGWeb.Auth.ConfigCache,
      ServiceRadarWebNG.Auth.TokenRevocation,
      Endpoint,
      Supervisor.child_spec({Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: 0}, id: :listener)
    ]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one, name: @supervisor)
    Process.unlink(supervisor)
    {_, bandit, _, _} = Enum.find(Supervisor.which_children(supervisor), fn {id, _, _, _} -> id == :listener end)
    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    Map.merge(session(user), %{port: port, version: @version, machine: machine()})
  end

  defp machine do
    %{
      otp: to_string(:erlang.system_info(:system_version)),
      elixir: System.version(),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      schedulers: :erlang.system_info(:schedulers_online),
      dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
      cpu_quota: cgroup("cpu.max"),
      memory_limit: cgroup("memory.max")
    }
  end

  defp cgroup(name) do
    case File.read("/sys/fs/cgroup/" <> name) do
      {:ok, value} -> String.trim(value)
      {:error, _} -> "unavailable"
    end
  end

  def hint(ids), do: DevicePubSub.broadcast_invalidated(ids)
  def report, do: Meter.report()
  def progress, do: progress_result(BitmapIndex.snapshot())
  defp progress_result({:ok, snapshot}), do: {:ok, snapshot.progress}
  defp progress_result(error), do: error

  # The same index epoch and revision that membership frames carry.
  def revision do
    with {:ok, snapshot} <- BitmapIndex.snapshot() do
      {:ok, {Ecto.UUID.load!(snapshot.index_epoch), snapshot.progress.index_revision}}
    end
  end

  # The native pending queue's overflow generation, bound to the index epoch
  # it belongs to, read directly from production status rather than a sample.
  def pending do
    with {:ok, snapshot} <- BitmapIndex.snapshot(),
         {:ok, status} <- Native.bitmap_index_status(snapshot.device) do
      {:ok,
       %{
         index_epoch: Ecto.UUID.load!(snapshot.index_epoch),
         rescan_generation: status.pending.rescan_generation,
         drained: snapshot.progress.pending_dirty == 0 and status.pending.pending_count == 0
       }}
    end
  end

  def install_geometry do
    world = Fixture.world(@version)
    manifest = %{layout_version: @version, generation: 1, zmax: 24}

    prepared =
      Map.new(TileKey.low_zoom(manifest), fn key ->
        {:ok, tile} = WorldTile.build(world, key)
        {key, tile}
      end)

    :ok = WorldCache.install(world, manifest, prepared)
    replace_mapping()
  end

  def replace_mapping do
    {:ok, snapshot} = BitmapIndex.snapshot()
    {:ok, %{world: world}} = WorldCache.world()
    {:ok, mapping} = TopologyAtlas.new_ordinals(world, snapshot.dictionary_epoch)
    map_pages(world, mapping, 0)
    {:ok, info} = TopologyAtlas.seal_ordinals(world, mapping)
    :ok = WorldCache.install_ordinals(world, mapping)
    %{mapped: info.mapped, total: info.total, retained_bytes: info.retained_bytes}
  end

  defp map_pages(world, mapping, cursor) do
    {:ok, %{entries: rows, next_cursor: next}} = BitmapSource.identity_page(cursor)
    {:ok, _} = TopologyAtlas.apply_ordinals(world, mapping, rows)
    if next, do: map_pages(world, mapping, next), else: :ok
  end

  def restart_index do
    {:ok, previous} = BitmapIndex.snapshot()
    :ok = Supervisor.terminate_child(@supervisor, BitmapIndex)
    {:ok, %{ready: false, cardinality: 0}} = Native.bitmap_index_status(previous.device)
    {:ok, _} = Supervisor.restart_child(@supervisor, BitmapIndex)
    :ok
  end

  def stop do
    Supervisor.stop(@supervisor, :shutdown, 10_000)
    :ok
  end

  defp session(user) do
    {:ok, token, _} = Guardian.create_access_token(user, ttl: {2, :hour})
    salts = Application.fetch_env!(:serviceradar_web_ng, :session)

    options =
      Plug.Session.init(
        store: :cookie,
        key: "_serviceradar_web_ng_key",
        signing_salt: Keyword.fetch!(salts, :signing_salt),
        encryption_salt: Keyword.fetch!(salts, :encryption_salt)
      )

    conn =
      :get
      |> Plug.Test.conn("/")
      |> Map.put(:secret_key_base, Endpoint.config(:secret_key_base))
      |> Plug.Session.call(options)
      |> Plug.Conn.fetch_session()
      |> Plug.Conn.put_session("user_token", token)
      |> Plug.CSRFProtection.call(Plug.CSRFProtection.init([]))

    csrf = Plug.CSRFProtection.get_csrf_token()
    conn = Plug.Conn.send_resp(conn, 200, "")
    [cookie | _] = Plug.Conn.get_resp_header(conn, "set-cookie")
    %{cookie: cookie |> String.split(";", parts: 2) |> hd(), csrf: csrf}
  end
end
