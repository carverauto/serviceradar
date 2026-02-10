defmodule ServiceRadar.Telemetry.OtelSetup do
  @moduledoc """
  Shared OpenTelemetry instrumentation setup for ServiceRadar Elixir applications.

  The OTEL SDK and exporter are configured in each app's `config/runtime.exs`
  (which runs before any OTP applications start). This module handles attaching
  telemetry event handlers for auto-instrumentation libraries (Phoenix, Ecto, Oban)
  and registering the OTLP log handler.

  ## Environment Variables

  These are read in `runtime.exs` to configure the SDK:
  - `OTEL_EXPORTER_OTLP_ENDPOINT` - OTLP endpoint (e.g. `https://serviceradar-otel:4317`)
  - `OTEL_SERVICE_NAME` - Override service name
  - `OTEL_CERT_DIR` - Directory containing TLS certificates
  - `OTEL_CERT_NAME` - Certificate name prefix (e.g. `core` for `core.pem`, `core-key.pem`)
  - `OTEL_ENABLED` - Set to `false` to disable OTEL export (default: `true`)
  - `OTEL_TRACES_SAMPLER_ARG` - Sampling ratio 0.0-1.0 (default: `1.0`)

  ## Usage

      # In your Application.start/2:
      ServiceRadar.Telemetry.OtelSetup.attach_instrumentations(
        instrumentations: [:phoenix, :ecto, :oban],
        ecto_repo: ServiceRadar.Repo
      )
  """

  require Logger

  @doc """
  Attaches telemetry event handlers for auto-instrumentation libraries
  and registers the OTLP log handler.

  Call this in `Application.start/2`. The OTEL SDK is already configured
  via `runtime.exs`; this attaches telemetry handlers and the log exporter.

  Options:
  - `:instrumentations` - List of instrumentation modules to set up.
    Supported: `:phoenix`, `:ecto`, `:oban`. Defaults to `[]`.
  - `:phoenix_adapter` - `:bandit` (default) or `:cowboy2`.
  - `:ecto_repo` - Required when `:ecto` is in instrumentations.
  """
  @spec attach_instrumentations(keyword()) :: :ok
  def attach_instrumentations(opts \\ []) do
    instrumentations = Keyword.get(opts, :instrumentations, [])

    if :phoenix in instrumentations do
      adapter = Keyword.get(opts, :phoenix_adapter, :bandit)
      setup_phoenix(adapter)
    end

    if :ecto in instrumentations do
      repo = Keyword.get(opts, :ecto_repo, ServiceRadar.Repo)
      setup_ecto(repo)
    end

    if :oban in instrumentations do
      setup_oban()
    end

    setup_log_handler()

    :ok
  end

  @doc """
  Builds the SSL options keyword list for the OTLP exporter.

  Reads `OTEL_CERT_DIR` and `OTEL_CERT_NAME` env vars. Returns mTLS options
  if certs are found, basic TLS options (verify_none) if not. Intended to be
  called from `runtime.exs`.

  Always returns a list (never nil) so the opentelemetry_exporter never falls
  back to `tls_certificate_check` which fails on minimal containers.
  """
  @spec ssl_options() :: keyword()
  def ssl_options do
    cert_dir = System.get_env("OTEL_CERT_DIR")
    cert_name = System.get_env("OTEL_CERT_NAME")

    with true <- is_binary(cert_dir) and cert_dir != "" and is_binary(cert_name) and cert_name != "" do
      ca_file = Path.join(cert_dir, "root.pem")
      cert_file = Path.join(cert_dir, "#{cert_name}.pem")
      key_file = Path.join(cert_dir, "#{cert_name}-key.pem")

      missing_files = missing_files([{ca_file, "CA"}, {cert_file, "cert"}, {key_file, "key"}])

      if missing_files == [] do
        IO.puts("[OtelSetup] Using mTLS certs from #{cert_dir} (#{cert_name})")

        [
          verify: :verify_peer,
          cacertfile: String.to_charlist(ca_file),
          certfile: String.to_charlist(cert_file),
          keyfile: String.to_charlist(key_file)
        ]
      else
        missing =
          Enum.map_join(missing_files, ", ", fn {f, label} -> "#{label}=#{f}" end)

        IO.puts("[OtelSetup] WARNING: Missing TLS files: #{missing}. Using verify_none.")
        [verify: :verify_none]
      end
    else
      _ ->
        IO.puts("[OtelSetup] No OTEL_CERT_DIR/OTEL_CERT_NAME set, using verify_none for TLS")
        [verify: :verify_none]
    end
  end

  # ============================================================================
  # Private - instrumentation setup
  # ============================================================================

  defp setup_phoenix(adapter) do
    if Code.ensure_loaded?(OpentelemetryPhoenix) do
      OpentelemetryPhoenix.setup(adapter: adapter)
      Logger.debug("[OtelSetup] Phoenix instrumentation attached (adapter: #{adapter})")
    end
  end

  defp setup_ecto(repo) do
    if Code.ensure_loaded?(OpentelemetryEcto) do
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

  defp setup_log_handler do
    cond do
      not Code.ensure_loaded?(:serviceradar_otel_log_handler_v2) ->
        Logger.warning(
          "[OtelSetup] serviceradar_otel_log_handler_v2 module not available; skipping OTLP log handler registration"
        )

        :ok

      not (Code.ensure_loaded?(:otel_exporter_logs_otlp) and function_exported?(:otel_exporter_logs_otlp, :export, 3)) ->
        Logger.warning(
          "[OtelSetup] OTLP log exporter not available (missing otel_exporter_logs_otlp:export/3); skipping OTLP log handler registration"
        )

        :ok

      true ->
        handler_config = %{
          config: %{
            exporter: {:opentelemetry_exporter, %{protocol: :grpc}}
          },
          level: :info
        }

        # Use a local copy of the handler implementation. The upstream
        # `otel_log_handler` can get stuck in the `exporting` state when a timer
        # tick fires with an empty batch, which halts further log exporting.
        case :logger.add_handler(:otel_log_handler, :serviceradar_otel_log_handler_v2, handler_config) do
          :ok ->
            Logger.info("[OtelSetup] OTLP log handler registered")

          {:error, {:already_exist, _}} ->
            :ok

          {:error, reason} ->
            Logger.warning("[OtelSetup] Failed to register OTLP log handler: #{inspect(reason)}")
        end
    end
  end

  defp telemetry_prefix(repo) do
    repo
    |> Module.split()
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp missing_files(files) when is_list(files) do
    Enum.reject(files, fn {f, _label} -> File.exists?(f) end)
  end
end
