defmodule ServiceRadarCoreElx.Application do
  @moduledoc """
  ServiceRadar Core-ELX Application.

  This is the primary coordination node for the ServiceRadar cluster.
  It configures serviceradar_core with cluster-specific settings but does NOT
  start duplicate processes - serviceradar_core handles all child processes.

  ## Responsibilities

  - Enable cluster mode for serviceradar_core
  - Enable AshOban scheduler (only core-elx runs schedulers)
  - Configure runtime settings before serviceradar_core starts

  ## Architecture

  Core-ELX is a thin wrapper that:
  1. Sets cluster_enabled = true (enables ClusterSupervisor, ClusterHealth in serviceradar_core)
  2. Sets start_ash_oban_scheduler = true (enables AshOban schedulers)
  3. Starts any core-elx specific services (none currently)

  All distributed registry, supervision, and clustering is handled by
  serviceradar_core's Application module when cluster_enabled is true.
  """

  use Application

  alias ServiceRadar.Repo
  alias ServiceRadar.Telemetry.OtelSetup

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting ServiceRadar Core-ELX node: #{node()}")

    # Attach OTEL auto-instrumentation handlers (SDK configured in runtime.exs)
    OtelSetup.attach_instrumentations(
      instrumentations: [:ecto, :oban],
      ecto_repo: Repo
    )

    # Core-ELX doesn't start duplicate children - serviceradar_core handles everything
    # when cluster_enabled=true is set in runtime.exs
    #
    # The following are started by serviceradar_core when cluster_enabled=true:
    # - ServiceRadar.ClusterSupervisor (libcluster + Horde)
    # - ServiceRadar.ClusterHealth
    # - ProcessRegistry (singleton Horde registry + DynamicSupervisor)
    #
    # AshOban scheduler is started when :start_ash_oban_scheduler = true

    children = [
      ServiceRadarCoreElx.CameraRelay.ViewerRegistry,
      ServiceRadarCoreElx.CameraRelay.PipelineManager,
      ServiceRadarCoreElx.CameraRelay.WebRTCSignalingManager,
      ServiceRadarCoreElx.CameraMediaSessionTracker,
      {Registry, keys: :unique, name: ServiceRadarCoreElx.CameraMediaIngressRegistry},
      ServiceRadarCoreElx.CameraMediaIngressSupervisor,
      {GRPC.Server.Supervisor,
       endpoint: ServiceRadarCoreElx.Endpoint,
       port: media_grpc_port(),
       start_server: true,
       adapter_opts: media_adapter_opts()}
    ]

    Logger.info("Core-ELX initialized - serviceradar_core handles cluster infrastructure")

    opts = [strategy: :one_for_one, name: ServiceRadarCoreElx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp media_grpc_port do
    value = System.get_env("CORE_ELX_MEDIA_GRPC_PORT", "50062")

    case Integer.parse(value) do
      {port, ""} when port > 0 and port < 65_536 -> port
      _ -> 50_062
    end
  end

  defp media_adapter_opts do
    case media_grpc_credential() do
      nil -> []
      credential -> [cred: credential]
    end
  end

  defp media_grpc_credential do
    cert_dir = System.get_env("CORE_ELX_MEDIA_CERT_DIR", "/etc/serviceradar/certs")
    cert_file = Path.join(cert_dir, "core-elx.pem")
    key_file = Path.join(cert_dir, "core-elx-key.pem")
    ca_file = Path.join(cert_dir, "root.pem")

    if File.exists?(cert_file) and File.exists?(key_file) and File.exists?(ca_file) do
      ssl_opts = [
        certfile: cert_file,
        keyfile: key_file,
        cacertfile: ca_file,
        verify: :verify_peer,
        fail_if_no_peer_cert: false
      ]

      GRPC.Credential.new(ssl: ssl_opts)
    else
      allow_insecure? = System.get_env("CORE_ELX_MEDIA_ALLOW_INSECURE_GRPC", "true") == "true"

      if allow_insecure? do
        nil
      else
        raise "No TLS certs available for core-elx camera media gRPC server"
      end
    end
  end
end
