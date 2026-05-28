defmodule ServiceRadar.AgentConfig.Compilers.VisibilityCompiler do
  @moduledoc """
  Compiler for host network visibility configuration.

  Phase 1 only emits passive fingerprint bindings. DPI, flow attribution,
  and process snapshot controls are reserved in the profile and protobuf
  schemas for later phases.
  """

  @behaviour ServiceRadar.AgentConfig.Compiler

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.TargetedProfileResolver
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.VisibilityProfile
  alias ServiceRadar.Inventory.VisibilityProfileSrqlTargetResolver, as: SrqlTargetResolver

  require Logger

  @default_sample_interval_ms 0

  @impl true
  def config_type, do: :visibility

  @impl true
  def source_resources do
    [VisibilityProfile]
  end

  @impl true
  def compile(_partition, _agent_id, opts \\ []) do
    actor = opts[:actor] || SystemActor.system(:visibility_compiler)
    device_uid = opts[:device_uid]

    profile = resolve_profile(device_uid, actor, opts)
    device_ip = resolve_device_ip(device_uid, actor, opts)

    cond do
      profile == nil ->
        {:ok, disabled_config(opts)}

      blank?(device_ip) ->
        {:ok, disabled_config(opts)}

      true ->
        {:ok, compile_profile(profile, device_ip, opts)}
    end
  rescue
    error ->
      Logger.error("VisibilityCompiler: error compiling config - #{inspect(error)}")
      {:error, {:compilation_error, error}}
  end

  @impl true
  def validate(config) when is_map(config) do
    cond do
      not Map.has_key?(config, "enabled") ->
        {:error, "Config missing 'enabled' key"}

      not Map.has_key?(config, "device_bindings") ->
        {:error, "Config missing 'device_bindings' key"}

      not is_list(config["device_bindings"]) ->
        {:error, "Config 'device_bindings' must be a list"}

      true ->
        :ok
    end
  end

  @spec resolve_profile(String.t() | nil, map(), keyword()) :: VisibilityProfile.t() | nil
  def resolve_profile(device_uid, actor, opts \\ []) do
    TargetedProfileResolver.resolve(device_uid, actor,
      resolver: Keyword.get(opts, :profile_resolver, &SrqlTargetResolver.resolve_for_device/2),
      log_prefix: "VisibilityCompiler"
    )
  end

  @spec compile_profile(VisibilityProfile.t(), String.t(), keyword()) :: map()
  def compile_profile(%VisibilityProfile{} = profile, device_ip, opts \\ []) do
    binding = %{
      "ip" => device_ip,
      "profile_id" => to_string(profile.id || ""),
      "profile_name" => profile.name || "",
      "fingerprint" => normalize_fingerprint(profile.fingerprint),
      "sample_interval_ms" => profile.sample_interval_ms || @default_sample_interval_ms
    }

    %{
      "enabled" => profile.enabled == true,
      "capture_interfaces" => capture_interfaces(profile, opts),
      "binary_overrides" => binary_overrides(opts),
      "device_bindings" => [binding],
      "default_sample_interval_ms" => profile.sample_interval_ms || @default_sample_interval_ms
    }
  end

  @spec disabled_config(keyword()) :: map()
  def disabled_config(opts \\ []) do
    %{
      "enabled" => false,
      "capture_interfaces" => capture_interfaces(opts),
      "binary_overrides" => binary_overrides(opts),
      "device_bindings" => [],
      "default_sample_interval_ms" => @default_sample_interval_ms
    }
  end

  defp resolve_device_ip(nil, _actor, _opts), do: nil

  defp resolve_device_ip(device_uid, actor, opts) when is_binary(device_uid) do
    resolver = Keyword.get(opts, :device_ip_resolver, &fetch_device_ip/2)

    case resolver.(device_uid, actor) do
      {:ok, ip} when is_binary(ip) ->
        String.trim(ip)

      {:ok, _} ->
        nil

      {:error, reason} ->
        Logger.debug(
          "VisibilityCompiler: device IP lookup failed for #{device_uid}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp fetch_device_ip(device_uid, actor) do
    case Device.get_by_uid(device_uid, false, actor: actor) do
      {:ok, %Device{ip: ip}} -> {:ok, ip}
      {:ok, _} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_fingerprint(fingerprint) when is_map(fingerprint) do
    %{
      "tcp" => boolean_value(fingerprint, "tcp"),
      "tls" => boolean_value(fingerprint, "tls"),
      "http" => boolean_value(fingerprint, "http")
    }
  end

  defp normalize_fingerprint(_fingerprint) do
    %{"tcp" => true, "tls" => true, "http" => true}
  end

  defp boolean_value(map, "tcp"), do: Map.get(map, "tcp", Map.get(map, :tcp, false)) == true
  defp boolean_value(map, "tls"), do: Map.get(map, "tls", Map.get(map, :tls, false)) == true
  defp boolean_value(map, "http"), do: Map.get(map, "http", Map.get(map, :http, false)) == true

  defp capture_interfaces(opts) do
    opts
    |> Keyword.get(:capture_interfaces, [])
    |> List.wrap()
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: [], else: [trimmed]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp capture_interfaces(%VisibilityProfile{} = profile, opts) do
    profile_interfaces =
      profile
      |> Map.get(:capture_interfaces, [])
      |> List.wrap()
      |> normalize_interfaces()

    case profile_interfaces do
      [] -> capture_interfaces(opts)
      interfaces -> interfaces
    end
  end

  defp normalize_interfaces(values) do
    values
    |> Enum.flat_map(fn
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: [], else: [trimmed]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp binary_overrides(opts) do
    case Keyword.get(opts, :binary_override_path) do
      value when is_binary(value) ->
        path = String.trim(value)
        if path == "", do: %{}, else: %{"path" => path}

      _ ->
        %{}
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
