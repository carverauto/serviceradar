defmodule ServiceRadar.Edge.RemoteAccessTargetPolicy do
  @moduledoc """
  Normalizes trusted registered application/TCP target policy before a session is opened.

  This module evaluates operator-owned target policy only. Browser intent must
  never supply upstream route, TLS, header, cookie, quota, approval, or recording
  policy.
  """

  alias ServiceRadar.Edge.RemoteAccessApplicationTarget
  alias ServiceRadar.Edge.RemoteAccessTcpTarget

  @default_app_methods ["GET", "HEAD"]
  @default_app_path_prefixes ["/"]
  @default_request_bytes 10 * 1024 * 1024
  @default_response_bytes 50 * 1024 * 1024
  @default_tcp_bytes 100 * 1024 * 1024
  @http_token ~r/^[A-Z][A-Z0-9!#$%&'*+.^_`|~-]*$/
  @forbidden_app_methods ["CONNECT"]

  @type evaluation :: {:ok, map()} | {:error, atom()}

  @spec evaluate_application(RemoteAccessApplicationTarget.t()) :: evaluation()
  def evaluate_application(%RemoteAccessApplicationTarget{} = target) do
    with {:ok, methods} <- normalize_methods(target.allowed_methods),
         {:ok, path_prefixes} <- normalize_path_prefixes(target.allowed_path_prefixes),
         {:ok, tls_policy} <- normalize_tls_policy(target.upstream_scheme, target.tls_policy),
         {:ok, redirect_policy} <- normalize_redirect_policy(target.header_policy),
         {:ok, header_policy} <- normalize_header_policy(target.header_policy),
         {:ok, cookie_policy} <- normalize_cookie_policy(target.cookie_policy),
         {:ok, quota_policy} <- normalize_app_quota_policy(target.quota_policy),
         {:ok, recording_policy} <- normalize_recording_policy(target.recording_policy),
         {:ok, enhanced_policy} <-
           normalize_enhanced_recording_policy(target.enhanced_recording_policy),
         {:ok, approval_policy} <-
           normalize_approval_policy(
             target.approval_policy,
             application_approval_triggers(
               target,
               methods,
               path_prefixes,
               tls_policy,
               recording_policy
             )
           ) do
      {:ok,
       %{
         "schema" => "serviceradar.remote_access.application_policy.v1",
         "allowed_methods" => methods,
         "allowed_path_prefixes" => path_prefixes,
         "tls_policy" => tls_policy,
         "redirect_policy" => redirect_policy,
         "header_policy" => header_policy,
         "cookie_policy" => cookie_policy,
         "quota_policy" => quota_policy,
         "approval_policy" => approval_policy,
         "recording_policy" => recording_policy,
         "enhanced_recording_policy" => enhanced_policy
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_remote_access_target_policy}
    end
  end

  @spec evaluate_tcp(RemoteAccessTcpTarget.t()) :: evaluation()
  def evaluate_tcp(%RemoteAccessTcpTarget{} = target) do
    with {:ok, quota_policy} <- normalize_tcp_quota_policy(target.quota_policy),
         {:ok, recording_policy} <- normalize_recording_policy(target.recording_policy),
         {:ok, enhanced_policy} <-
           normalize_enhanced_recording_policy(target.enhanced_recording_policy),
         {:ok, approval_policy} <-
           normalize_approval_policy(target.approval_policy, ["tcp_target"]) do
      {:ok,
       %{
         "schema" => "serviceradar.remote_access.tcp_policy.v1",
         "quota_policy" => quota_policy,
         "approval_policy" => approval_policy,
         "recording_policy" => recording_policy,
         "enhanced_recording_policy" => enhanced_policy
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_remote_access_target_policy}
    end
  end

  defp normalize_methods(methods) when methods in [nil, []], do: {:ok, @default_app_methods}

  defp normalize_methods(methods) when is_list(methods) do
    methods =
      methods
      |> Enum.map(&string_or_nil/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&String.upcase/1)
      |> Enum.uniq()

    if methods != [] and Enum.all?(methods, &valid_application_method?/1),
      do: {:ok, methods},
      else: {:error, :invalid_remote_access_target_policy}
  end

  defp normalize_methods(_methods), do: {:error, :invalid_remote_access_target_policy}

  defp valid_application_method?(method) do
    Regex.match?(@http_token, method) and method not in @forbidden_app_methods
  end

  defp normalize_path_prefixes(prefixes) when prefixes in [nil, []],
    do: {:ok, @default_app_path_prefixes}

  defp normalize_path_prefixes(prefixes) when is_list(prefixes) do
    prefixes =
      prefixes
      |> Enum.map(&string_or_nil/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if prefixes != [] and Enum.all?(prefixes, &valid_path_prefix?/1),
      do: {:ok, prefixes},
      else: {:error, :invalid_remote_access_target_policy}
  end

  defp normalize_path_prefixes(_prefixes), do: {:error, :invalid_remote_access_target_policy}

  defp normalize_tls_policy(:http, policy) do
    policy = normalize_map(policy)
    verify = policy_string(policy, "verify") || "disabled"

    if verify in ["disabled", "none", "required"] do
      {:ok,
       drop_nil_values(%{
         "verify" => if(verify == "required", do: "required", else: "disabled"),
         "ca_bundle_ref" => policy_string(policy, "ca_bundle_ref")
       })}
    else
      {:error, :invalid_remote_access_target_policy}
    end
  end

  defp normalize_tls_policy(:https, policy) do
    policy = normalize_map(policy)
    verify = policy_string(policy, "verify") || "required"

    if verify in ["required", "ca_bundle", "insecure_skip_verify"] do
      {:ok,
       drop_nil_values(%{
         "verify" => verify,
         "ca_bundle_ref" => policy_string(policy, "ca_bundle_ref"),
         "server_name" => policy_string(policy, "server_name")
       })}
    else
      {:error, :invalid_remote_access_target_policy}
    end
  end

  defp normalize_tls_policy(_scheme, _policy), do: {:error, :invalid_remote_access_target_policy}

  defp normalize_redirect_policy(header_policy) do
    header_policy = normalize_map(header_policy)

    policy =
      normalize_map(
        policy_value(header_policy, "redirects") || policy_value(header_policy, "redirect_policy")
      )

    mode = policy_string(policy, "mode") || "deny"
    max_hops_value = policy_value(policy, "max_hops")
    max_hops = non_negative_int(max_hops_value) || 0
    valid_mode? = mode in ["deny", "same_origin", "policy_allowed"]
    valid_hops? = is_nil(max_hops_value) or not is_nil(non_negative_int(max_hops_value))

    if valid_hops? and valid_mode? and max_hops <= 10 do
      {:ok, %{"mode" => mode, "max_hops" => max_hops}}
    else
      {:error, :invalid_remote_access_target_policy}
    end
  end

  defp normalize_header_policy(policy) do
    policy = normalize_map(policy)

    with {:ok, allow} <- normalize_string_list(policy_value(policy, "allow")),
         {:ok, drop} <- normalize_string_list(policy_value(policy, "drop")),
         {:ok, inject} <- normalize_string_map(policy_value(policy, "inject")) do
      {:ok,
       %{
         "allow" => allow,
         "drop" => drop,
         "inject" => inject
       }}
    end
  end

  defp normalize_cookie_policy(policy) do
    policy = normalize_map(policy)
    isolation = policy_string(policy, "isolation") || "session"

    if isolation in ["session", "none"] do
      {:ok,
       %{
         "isolation" => isolation,
         "store" => truthy?(policy_value(policy, "store"))
       }}
    else
      {:error, :invalid_remote_access_target_policy}
    end
  end

  defp normalize_app_quota_policy(policy) do
    policy = normalize_map(policy)

    with {:ok, max_request_bytes} <-
           positive_policy_int(policy, "max_request_bytes", @default_request_bytes),
         {:ok, max_response_bytes} <-
           positive_policy_int(policy, "max_response_bytes", @default_response_bytes),
         {:ok, idle_timeout_seconds} <-
           optional_positive_policy_int(policy, "idle_timeout_seconds"),
         {:ok, absolute_timeout_seconds} <-
           optional_positive_policy_int(policy, "absolute_timeout_seconds") do
      {:ok,
       drop_nil_values(%{
         "max_request_bytes" => max_request_bytes,
         "max_response_bytes" => max_response_bytes,
         "idle_timeout_seconds" => idle_timeout_seconds,
         "absolute_timeout_seconds" => absolute_timeout_seconds
       })}
    end
  end

  defp normalize_tcp_quota_policy(policy) do
    policy = normalize_map(policy)

    with {:ok, max_rx_bytes} <- positive_policy_int(policy, "max_rx_bytes", @default_tcp_bytes),
         {:ok, max_tx_bytes} <- positive_policy_int(policy, "max_tx_bytes", @default_tcp_bytes) do
      {:ok, %{"max_rx_bytes" => max_rx_bytes, "max_tx_bytes" => max_tx_bytes}}
    end
  end

  defp normalize_approval_policy(policy, trigger_reasons) do
    policy = normalize_map(policy)

    explicit_required? =
      truthy?(policy_value(policy, "required")) or
        truthy?(policy_value(policy, "approval_required"))

    reasons =
      policy
      |> policy_value("reasons")
      |> normalize_reason_list()
      |> Kernel.++(trigger_reasons)
      |> Enum.uniq()

    {:ok,
     drop_nil_values(%{
       "required" => explicit_required? or reasons != [],
       "reasons" => reasons,
       "reason" => policy_string(policy, "reason")
     })}
  end

  defp application_approval_triggers(target, methods, path_prefixes, tls_policy, recording_policy) do
    []
    |> maybe_add_trigger(policy_sensitive?(target.approval_policy), "sensitive_application")
    |> maybe_add_trigger(tls_policy["verify"] == "insecure_skip_verify", "insecure_upstream_tls")
    |> maybe_add_trigger(Enum.member?(path_prefixes, "/"), "broad_path_access")
    |> maybe_add_trigger(Enum.any?(methods, &upload_method?/1), "upload_enabled")
    |> maybe_add_trigger(truthy?(recording_policy["capture_bodies"]), "body_recording")
  end

  defp policy_sensitive?(policy) do
    policy = normalize_map(policy)

    truthy?(policy_value(policy, "sensitive")) or
      policy_string(policy, "sensitivity") in ["high", "critical"]
  end

  defp upload_method?(method), do: method not in ["GET", "HEAD", "OPTIONS"]

  defp maybe_add_trigger(reasons, true, reason), do: [reason | reasons]
  defp maybe_add_trigger(reasons, _condition, _reason), do: reasons

  defp normalize_reason_list(values) when is_list(values) do
    values
    |> Enum.map(&string_or_nil/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_reason_list(value) when is_binary(value) do
    value
    |> String.split([",", "\n"], trim: true)
    |> normalize_reason_list()
  end

  defp normalize_reason_list(_value), do: []

  defp normalize_recording_policy(policy) do
    policy = normalize_map(policy)

    {:ok,
     %{
       "enabled" => Map.get(policy, "enabled", true) != false,
       "metadata_only" => Map.get(policy, "metadata_only", true) != false,
       "capture_bodies" => truthy?(policy_value(policy, "capture_bodies")),
       "approval_required" => truthy?(policy_value(policy, "approval_required"))
     }}
  end

  defp normalize_enhanced_recording_policy(policy) do
    policy = normalize_map(policy)

    {:ok,
     %{
       "enabled" => truthy?(policy_value(policy, "enabled")),
       "approval_required" => truthy?(policy_value(policy, "approval_required"))
     }}
  end

  defp positive_policy_int(policy, key, default) do
    case policy_value(policy, key) do
      nil ->
        {:ok, default}

      value ->
        case positive_int(value) do
          nil -> {:error, :invalid_remote_access_target_policy}
          int -> {:ok, int}
        end
    end
  end

  defp optional_positive_policy_int(policy, key) do
    case policy_value(policy, key) do
      nil ->
        {:ok, nil}

      value ->
        case positive_int(value) do
          nil -> {:error, :invalid_remote_access_target_policy}
          int -> {:ok, int}
        end
    end
  end

  defp normalize_string_list(nil), do: {:ok, []}

  defp normalize_string_list(values) when is_list(values) do
    strings = Enum.map(values, &string_or_nil/1)

    if Enum.any?(strings, &is_nil/1),
      do: {:error, :invalid_remote_access_target_policy},
      else: {:ok, Enum.uniq(strings)}
  end

  defp normalize_string_list(_values), do: {:error, :invalid_remote_access_target_policy}

  defp normalize_string_map(nil), do: {:ok, %{}}

  defp normalize_string_map(values) when is_map(values) do
    values =
      Enum.reduce_while(values, %{}, fn {key, value}, acc ->
        with key when is_binary(key) <- string_or_nil(key),
             value when is_binary(value) <- string_or_nil(value) do
          {:cont, Map.put(acc, key, value)}
        else
          _invalid -> {:halt, :error}
        end
      end)

    case values do
      :error -> {:error, :invalid_remote_access_target_policy}
      map -> {:ok, map}
    end
  end

  defp normalize_string_map(_values), do: {:error, :invalid_remote_access_target_policy}

  defp normalize_map(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp normalize_map(_map), do: %{}

  defp policy_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, to_string(key))

  defp policy_value(_map, _key), do: nil

  defp policy_string(map, key) do
    map
    |> policy_value(key)
    |> string_or_nil()
  end

  defp string_or_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value) when is_atom(value), do: value |> Atom.to_string() |> string_or_nil()
  defp string_or_nil(_value), do: nil

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _other -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _other -> nil
    end
  end

  defp non_negative_int(_value), do: nil

  defp valid_path_prefix?(prefix) do
    valid_path_prefix_shape?(prefix) and
      valid_path_prefix_shape?(URI.decode(prefix))
  end

  defp valid_path_prefix_shape?(prefix) do
    String.starts_with?(prefix, "/") and
      not String.starts_with?(prefix, "//") and
      not String.contains?(prefix, "://") and
      not String.contains?(prefix, "\\") and
      not String.contains?(prefix, ["\0", "\r", "\n", "\t"]) and
      not Enum.any?(String.split(prefix, "/"), &(&1 in [".", ".."]))
  end

  defp truthy?(value) when value in [true, "true", "required", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
