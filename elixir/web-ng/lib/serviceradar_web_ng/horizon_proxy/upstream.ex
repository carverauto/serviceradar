defmodule ServiceRadarWebNG.HorizonProxy.Upstream do
  @moduledoc """
  Server-side upstream Horizon base URL and Bearer API key resolution and
  SSRF validation.

  Resolution order:
  1. Enabled `cloud.serviceradar.horizon-feed` plugin assignment
  2. Application config `:serviceradar_web_ng, :horizon_proxy` or
     `SERVICERADAR_HORIZON_API_URL` / `SERVICERADAR_HORIZON_API_KEY` env vars
  """

  import Bitwise

  alias Palisade.NetworkAddressPolicy
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginPackage
  alias ServiceRadar.Plugins.SecretRefs

  require Ash.Query
  require Logger

  @horizon_plugin_id "cloud.serviceradar.horizon-feed"

  @horizon_secret_schema %{
    "properties" => %{
      "watchlist_api_key_secret_ref" => %{"secretRef" => true},
      "api_key_secret_ref" => %{"secretRef" => true}
    }
  }

  @forbidden_hosts MapSet.new([
                     "localhost",
                     "localhost.localdomain",
                     "metadata.google.internal",
                     "metadata.goog",
                     "instance-data"
                   ])

  @forbidden_ipv4_cidrs [
    # Unspecified
    {{0, 0, 0, 0}, 8},
    # Loopback
    {{127, 0, 0, 0}, 8},
    # Link-local / Cloud metadata (169.254.169.254)
    {{169, 254, 0, 0}, 16},
    # Multicast
    {{224, 0, 0, 0}, 4},
    # Reserved
    {{240, 0, 0, 0}, 4}
  ]

  @type config :: %{
          base_url: String.t(),
          api_key: String.t()
        }

  @doc """
  Resolves and validates the upstream Horizon base URL and Bearer API key.
  """
  @spec resolve() :: {:ok, config()} | {:error, :not_configured | :invalid_upstream_url}
  def resolve do
    with {:ok, %{base_url: base_url, api_key: api_key}} <- fetch_raw_upstream(),
         {:ok, normalized_base} <- validate_base_url(base_url) do
      {:ok, %{base_url: normalized_base, api_key: api_key}}
    end
  end

  @doc """
  Validates that an upstream Horizon base URL uses `https://`, has a valid host
  with no userinfo/query/fragment, and does not point at loopback, link-local,
  metadata, multicast, or reserved addresses.
  """
  @spec validate_base_url(term()) :: {:ok, String.t()} | {:error, :invalid_upstream_url}
  def validate_base_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if contains_control_chars?(url) do
      {:error, :invalid_upstream_url}
    else
      case URI.new(trimmed) do
        {:ok, %URI{scheme: scheme, host: host, port: port, userinfo: nil, query: nil, fragment: nil} = uri}
        when is_binary(scheme) and is_binary(host) and host != "" ->
          with "https" <- String.downcase(scheme),
               :ok <- validate_port(port),
               {:ok, normalized_host} <- validate_host(host) do
            normalized_path = uri.path |> to_string() |> String.trim_trailing("/")
            {:ok, URI.to_string(%{uri | scheme: "https", host: normalized_host, path: normalized_path})}
          else
            _ -> {:error, :invalid_upstream_url}
          end

        _ ->
          {:error, :invalid_upstream_url}
      end
    end
  end

  def validate_base_url(_), do: {:error, :invalid_upstream_url}

  defp fetch_raw_upstream do
    case Application.get_env(:serviceradar_web_ng, :horizon_proxy_upstream_resolver) do
      resolver when is_function(resolver, 0) ->
        resolver.()

      _ ->
        resolve_from_plugin_assignment() || resolve_from_config_or_env() || {:error, :not_configured}
    end
  end

  defp resolve_from_plugin_assignment do
    actor = SystemActor.system(:horizon_proxy)

    assignments =
      PluginAssignment
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(plugin_id == ^@horizon_plugin_id and enabled == true)
      |> Ash.Query.sort(updated_at: :desc)
      |> Ash.Query.limit(5)
      |> Ash.read!(actor: actor)

    Enum.find_value(assignments, fn assignment ->
      extract_assignment_upstream(assignment, actor)
    end)
  rescue
    error ->
      Logger.warning("Horizon proxy plugin assignment lookup failed: #{inspect(error.__struct__)}")
      nil
  end

  defp extract_assignment_upstream(%PluginAssignment{params: params} = assignment, actor) when is_map(params) do
    schema = merge_secret_schema(fetch_package_schema(assignment.plugin_package_id, actor))

    resolved_params =
      case SecretRefs.resolve_runtime_params(schema, params,
             broker_opts: [consumer_kind: :plugin, resolution_location: :core]
           ) do
        {:ok, resolved} -> resolved
        {:error, _reasons} -> SecretRefs.public_params(params)
      end

    base_url = present_string(resolved_params["api_base_url"])
    api_key = resolve_api_key(resolved_params)

    if base_url && api_key do
      {:ok, %{base_url: base_url, api_key: api_key}}
    end
  end

  defp extract_assignment_upstream(_assignment, _actor), do: nil

  defp fetch_package_schema(package_id, actor) when is_binary(package_id) and package_id != "" do
    case PluginPackage
         |> Ash.Query.for_read(:read)
         |> Ash.Query.filter(id == ^package_id)
         |> Ash.read_one(actor: actor) do
      {:ok, %PluginPackage{config_schema: schema}} when is_map(schema) -> schema
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp fetch_package_schema(_package_id, _actor), do: %{}

  defp merge_secret_schema(schema) when is_map(schema) do
    existing_props = Map.get(schema, "properties", %{})
    merged_props = Map.merge(@horizon_secret_schema["properties"], existing_props)
    Map.put(schema, "properties", merged_props)
  end

  defp resolve_api_key(params) do
    Enum.find_value([params["watchlist_api_key"], params["api_key"]], &usable_secret/1)
  end

  defp usable_secret(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and not SecretRefs.secret_ref?(trimmed) do
      trimmed
    end
  end

  defp usable_secret(_), do: nil

  defp resolve_from_config_or_env do
    config = Application.get_env(:serviceradar_web_ng, :horizon_proxy, [])

    base_url =
      present_string(Keyword.get(config, :base_url)) ||
        present_string(System.get_env("SERVICERADAR_HORIZON_API_URL"))

    api_key =
      present_string(Keyword.get(config, :api_key)) ||
        present_string(System.get_env("SERVICERADAR_HORIZON_API_KEY"))

    if base_url && api_key do
      {:ok, %{base_url: base_url, api_key: api_key}}
    end
  end

  defp present_string(val) when is_binary(val) do
    case String.trim(val) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present_string(_), do: nil

  defp validate_port(nil), do: :ok
  defp validate_port(port) when is_integer(port) and port > 0 and port <= 65_535, do: :ok
  defp validate_port(_), do: {:error, :invalid_port}

  defp contains_control_chars?(value), do: Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp valid_host_chars?(host), do: Regex.match?(~r/\A[A-Za-z0-9._:-]+\z/, host)

  defp validate_host(host) when is_binary(host) do
    host_down = String.downcase(host)
    has_trailing_dot = String.ends_with?(host_down, ".")
    normalized = String.trim_trailing(host_down, ".")

    cond do
      not valid_host_chars?(host) ->
        {:error, :invalid_host}

      normalized == "" or String.starts_with?(host_down, ".") or String.contains?(host_down, "..") ->
        {:error, :invalid_host}

      MapSet.member?(@forbidden_hosts, normalized) ->
        {:error, :disallowed_host}

      String.ends_with?(normalized, ".localhost") ->
        {:error, :disallowed_host}

      true ->
        validate_host_address(normalized, has_trailing_dot)
    end
  end

  defp validate_host_address(host, has_trailing_dot) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} when has_trailing_dot ->
        {:error, :invalid_host}

      {:ok, ip} ->
        if forbidden_ip?(ip), do: {:error, :disallowed_host}, else: {:ok, host}

      {:error, _} ->
        if String.contains?(host, ":") do
          {:error, :invalid_host}
        else
          case check_resolved_addresses(host) do
            :ok -> {:ok, host}
            error -> error
          end
        end
    end
  end

  defp check_resolved_addresses(host) do
    charlist = String.to_charlist(host)

    addresses =
      case {:inet.getaddrs(charlist, :inet), :inet.getaddrs(charlist, :inet6)} do
        {{:ok, v4}, {:ok, v6}} -> v4 ++ v6
        {{:ok, v4}, _} -> v4
        {_, {:ok, v6}} -> v6
        _ -> []
      end

    if Enum.any?(addresses, &forbidden_ip?/1) do
      {:error, :disallowed_host}
    else
      :ok
    end
  end

  defp forbidden_ip?({_, _, _, _} = ip) do
    Enum.any?(@forbidden_ipv4_cidrs, fn {base, bits} -> in_ipv4_cidr?(ip, base, bits) end)
  end

  defp forbidden_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp forbidden_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  # IPv4-compatible (::/96)
  defp forbidden_ip?({0, 0, 0, 0, 0, 0, high, low}), do: embedded_ipv4_forbidden?(high, low)
  # IPv4-mapped (::ffff:0:0/96)
  defp forbidden_ip?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: embedded_ipv4_forbidden?(high, low)
  # IPv4-translated (::ffff:0:0:0/96)
  defp forbidden_ip?({0, 0, 0, 0, 0xFFFF, 0, high, low}), do: embedded_ipv4_forbidden?(high, low)
  # NAT64 well-known prefix (64:ff9b::/96)
  defp forbidden_ip?({0x0064, 0xFF9B, 0, 0, 0, 0, high, low}), do: embedded_ipv4_forbidden?(high, low)
  # 6to4 (2002::/16)
  defp forbidden_ip?({0x2002, high, low, _, _, _, _, _}), do: embedded_ipv4_forbidden?(high, low)

  # fe80::/10 link-local
  defp forbidden_ip?({w1, _, _, _, _, _, _, _}) when (w1 &&& 0xFFC0) == 0xFE80, do: true
  # ff00::/8 multicast
  defp forbidden_ip?({w1, _, _, _, _, _, _, _}) when (w1 &&& 0xFF00) == 0xFF00, do: true
  defp forbidden_ip?({_, _, _, _, _, _, _, _}), do: false
  defp forbidden_ip?(_), do: true

  defp embedded_ipv4_forbidden?(high, low) do
    forbidden_ip?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  defp in_ipv4_cidr?(ip, base, bits) when is_tuple(ip) and is_tuple(base) and is_integer(bits) and bits >= 0 do
    NetworkAddressPolicy.cidr_contains?(ip, "#{:inet.ntoa(base)}/#{bits}")
  end
end
