# `mix test` starts :serviceradar_core_elx before the suite. This target runs the
# files with `elixir -r`, which starts nothing, so every call to a registered
# process exits with "no process ... application isn't started":
#
#   CameraMediaSessionTracker, the camera-relay managers, the ingress
#   supervisors, RemoteDesktop.MediaSessionManager, and ServiceRadar.PubSub.
#
# The telemetry application has to be up first. TelemetryMetricsPrometheus
# registers on :telemetry_handler_table, and that table does not exist until
# the application is started. ViewerRegistry subscribes during init, so PubSub
# has to exist before the supervision tree.
#
# serviceradar_core itself stays down. config/test.exs disables the repo and
# Oban because this suite never touches them, and booting that application
# would open the vault and the database.
#
# Req and ExWebRTC stay unloaded under `elixir -r` too. Req.post needs the
# Req.Finch pool, and WebRTC signaling needs ExWebRTC.Registry. Both exist
# only after those applications start. AnalysisHTTPAdapter posts through
# ServiceRadar.Finch, which core's application starts. This suite does not
# boot core, so the pool has to be started here.
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:ex_webrtc)

if !Process.whereis(ServiceRadar.Finch) do
  {:ok, finch} = Finch.start_link(name: ServiceRadar.Finch)
  Process.unlink(finch)
end

if !Process.whereis(ServiceRadar.PubSub) do
  {:ok, pubsub} = Phoenix.PubSub.Supervisor.start_link(name: ServiceRadar.PubSub)
  Process.unlink(pubsub)
end

# Core's application starts the relay-host :pg scope; the relay pipeline manager
# advertises into it, so it has to exist before the supervision tree.
if !Process.whereis(:serviceradar_camera_relay_hosts) do
  {:ok, relay_hosts} = :pg.start_link(:serviceradar_camera_relay_hosts)
  Process.unlink(relay_hosts)
end

if !Process.whereis(ServiceRadarCoreElx.Supervisor) do
  case ServiceRadarCoreElx.Application.start(:normal, []) do
    {:ok, supervisor} ->
      Process.unlink(supervisor)

    {:error, reason} ->
      raise "serviceradar_core_elx failed to start for the unit suite: #{inspect(reason)}"
  end
end

ExUnit.start()
