defmodule ServiceRadar.Telemetry.OtelSetup do
  @moduledoc """
  Shared OpenTelemetry configuration for ServiceRadar Elixir applications.

  Configures the OpenTelemetry SDK with an OTLP/gRPC exporter targeting the
  ServiceRadar OTEL collector. Supports mTLS via environment variables.

  ## Environment Variables

  - `OTEL_EXPORTER_OTLP_ENDPOINT` - OTLP endpoint (e.g. `https://serviceradar-otel:4317`)
  - `OTEL_SERVICE_NAME` - Override service name (optional, defaults to app-provided name)
  - `OTEL_CERT_DIR` - Directory containing TLS certificates
  - `OTEL_CERT_NAME` - Certificate name prefix (e.g. `core` for `core.pem`, `core-key.pem`)
  - `OTEL_ENABLED` - Set to `false` to disable OTEL export (default: `true`)
  - `OTEL_TRACES_SAMPLER_ARG` - Sampling ratio 0.0-1.0 (default: `1.0`)

  ## Usage

      # In your Application.start/2:
      ServiceRadar.Telemetry.OtelSetup.configure(
        service_name: "serviceradar-core-elx",
        service_version: "0.1.0"
      )
  """

  require Logger

  @doc """
  Configures the OpenTelemetry SDK for the calling application.

  Options:
  - `:service_name` - Required. The OTEL service.name resource attribute.
  - `:service_version` - Optional. The service.version resource attribute.
  - `:instrumentations` - Optional. List of instrumentation modules to set up.
    Supported: `:phoenix`, `:ecto`, `:oban`. Defaults to `[]`.
  - `:ecto_repo` - Required when `:ecto` is in instrumentations. The Ecto repo module.
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    if enabled?() do
      service_name =
        System.get_env("OTEL_SERVICE_NAME") ||
          Keyword.fetch!(opts, :service_name)

      service_version = Keyword.get(opts, :service_version, "0.1.0")

      configure_resource(service_name, service_version)
      configure_exporter()
      setup_instrumentations(opts)

      Logger.info(
        "[OtelSetup] OpenTelemetry configured for #{service_name} " <>
          "-> #{endpoint()}"
      )
    else
      Logger.info("[OtelSetup] OpenTelemetry export disabled (OTEL_ENABLED=false or no endpoint)")
    end

    :ok
  end

  @doc """
  Returns true if OTEL export is enabled and an endpoint is configured.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case System.get_env("OTEL_ENABLED", "true") do
      val when val in ["false", "0", "no"] -> false
      _ -> endpoint() != nil
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp endpoint do
    System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  end

  defp configure_resource(service_name, service_version) do
    env = System.get_env("OTEL_DEPLOYMENT_ENVIRONMENT", "production")

    # The opentelemetry SDK reads OTEL_RESOURCE_ATTRIBUTES env var automatically,
    # but we also set them programmatically for clarity.
    resource_attrs = %{
      "service.name": service_name,
      "service.version": service_version,
      "deployment.environment": env,
      "service.namespace": "serviceradar",
      "telemetry.sdk.language": "erlang"
    }

    Application.put_env(:opentelemetry, :resource, resource_attrs)
  end

  defp configure_exporter do
    otlp_endpoint = endpoint()

    # Build exporter config
    exporter_config = [
      endpoint: otlp_endpoint,
      protocol: :grpc
    ]

    # Add TLS/mTLS config if cert dir is provided
    exporter_config =
      case tls_config() do
        nil -> exporter_config
        tls_opts -> Keyword.put(exporter_config, :ssl_options, tls_opts)
      end

    Application.put_env(:opentelemetry_exporter, :otlp_protocol, :grpc)
    Application.put_env(:opentelemetry_exporter, :otlp_endpoint, otlp_endpoint)

    if tls_config() do
      Application.put_env(:opentelemetry_exporter, :ssl_options, tls_config())
    end

    # Configure the SDK to use the OTLP exporter
    Application.put_env(:opentelemetry, :processors, [
      {:otel_batch_processor,
       %{
         exporter: {:opentelemetry_exporter, exporter_config}
       }}
    ])

    # Configure sampler
    sampler_arg =
      System.get_env("OTEL_TRACES_SAMPLER_ARG", "1.0")
      |> String.to_float()

    Application.put_env(:opentelemetry, :sampler, {:parent_based, %{root: {:trace_id_ratio_based, sampler_arg}}})
  end

  defp tls_config do
    cert_dir = System.get_env("OTEL_CERT_DIR")
    cert_name = System.get_env("OTEL_CERT_NAME")

    cond do
      cert_dir && cert_name ->
        ca_file = Path.join(cert_dir, "root.pem")
        cert_file = Path.join(cert_dir, "#{cert_name}.pem")
        key_file = Path.join(cert_dir, "#{cert_name}-key.pem")

        if File.exists?(ca_file) and File.exists?(cert_file) and File.exists?(key_file) do
          [
            verify: :verify_peer,
            cacertfile: String.to_charlist(ca_file),
            certfile: String.to_charlist(cert_file),
            keyfile: String.to_charlist(key_file)
          ]
        else
          Logger.warning(
            "[OtelSetup] TLS cert files not found in #{cert_dir} for #{cert_name}, " <>
              "falling back to insecure connection"
          )

          nil
        end

      # Fall back to SPIFFE cert dir if OTEL-specific vars not set
      true ->
        spiffe_cert_dir = System.get_env("SPIFFE_CERT_DIR")

        if spiffe_cert_dir do
          ca_file = Path.join(spiffe_cert_dir, "root.pem")
          # Try common cert names
          possible_names = ["core", "web-ng", "agent-gateway"]

          Enum.find_value(possible_names, fn name ->
            cert_file = Path.join(spiffe_cert_dir, "#{name}.pem")
            key_file = Path.join(spiffe_cert_dir, "#{name}-key.pem")

            if File.exists?(cert_file) and File.exists?(key_file) and File.exists?(ca_file) do
              [
                verify: :verify_peer,
                cacertfile: String.to_charlist(ca_file),
                certfile: String.to_charlist(cert_file),
                keyfile: String.to_charlist(key_file)
              ]
            end
          end)
        else
          nil
        end
    end
  end

  defp setup_instrumentations(opts) do
    instrumentations = Keyword.get(opts, :instrumentations, [])

    if :phoenix in instrumentations do
      setup_phoenix()
    end

    if :ecto in instrumentations do
      repo = Keyword.get(opts, :ecto_repo, ServiceRadar.Repo)
      setup_ecto(repo)
    end

    if :oban in instrumentations do
      setup_oban()
    end
  end

  defp setup_phoenix do
    if Code.ensure_loaded?(OpentelemetryPhoenix) do
      OpentelemetryPhoenix.setup()
      Logger.debug("[OtelSetup] Phoenix instrumentation attached")
    end
  end

  defp setup_ecto(repo) do
    if Code.ensure_loaded?(OpentelemetryEcto) do
      # OpentelemetryEcto expects the telemetry prefix of the repo
      # e.g. ServiceRadar.Repo -> [:service_radar, :repo]
      repo_prefix = telemetry_prefix(repo)
      OpentelemetryEcto.setup(repo_prefix)
      Logger.debug("[OtelSetup] Ecto instrumentation attached for #{inspect(repo)}")
    end
  end

  defp setup_oban do
    if Code.ensure_loaded?(OpentelemetryOban) do
      OpentelemetryOban.setup()
      Logger.debug("[OtelSetup] Oban instrumentation attached")
    end
  end

  defp telemetry_prefix(repo) do
    repo
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&String.to_atom/1)
  end
end
