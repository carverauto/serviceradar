defmodule ServiceRadarWebNG.RemoteAccessDesktopTargets do
  @moduledoc """
  Browser-facing access to authorized desktop remote-access targets.

  The default source is static application configuration until the operator
  administration resource is added. Callers receive only policy and routing
  posture; credential material is never returned.
  """

  alias ServiceRadar.Edge.RemoteAccessDesktopTarget

  @secret_keys ~w(
    access_key
    api_key
    ca_key
    certificate_private_key
    client_key
    credential
    credentials
    jwt
    passphrase
    password
    private_key
    secret
    secret_payload
    session_token
    ticket
    token
  )
  @secret_suffixes ~w(_credential _key _password _secret _ticket _token)

  @default_target_port 3389
  @min_port 1
  @max_port 65_535

  @type target :: map()

  @spec list_authorized(term(), keyword()) :: {:ok, [target()]} | {:error, term()}
  def list_authorized(scope, opts \\ []) do
    provider = Keyword.get(opts, :provider) || configured_provider()

    with {:ok, targets} <- load_targets(provider, scope, opts) do
      {:ok, normalize_targets(targets)}
    end
  end

  @spec list_managed(term()) :: {:ok, [RemoteAccessDesktopTarget.t()]} | {:error, term()}
  def list_managed(scope) do
    RemoteAccessDesktopTarget
    |> Ash.Query.for_read(:list, %{}, scope: scope)
    |> Ash.read(scope: scope)
  end

  @spec get_managed(term(), String.t()) :: {:ok, RemoteAccessDesktopTarget.t() | nil} | {:error, term()}
  def get_managed(scope, id) when is_binary(id) do
    RemoteAccessDesktopTarget
    |> Ash.Query.for_read(:by_id, %{id: id}, scope: scope)
    |> Ash.read_one(scope: scope)
  end

  @spec create_managed(term(), map()) :: {:ok, RemoteAccessDesktopTarget.t()} | {:error, term()}
  def create_managed(scope, attrs) when is_map(attrs) do
    with {:ok, target} <-
           RemoteAccessDesktopTarget
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(scope: scope) do
      get_managed(scope, target.id)
    end
  end

  @spec update_managed(term(), RemoteAccessDesktopTarget.t(), map()) ::
          {:ok, RemoteAccessDesktopTarget.t()} | {:error, term()}
  def update_managed(scope, %RemoteAccessDesktopTarget{} = target, attrs) when is_map(attrs) do
    with {:ok, target} <-
           target
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(scope: scope) do
      get_managed(scope, target.id)
    end
  end

  @spec set_managed_enabled(term(), RemoteAccessDesktopTarget.t(), boolean()) ::
          {:ok, RemoteAccessDesktopTarget.t()} | {:error, term()}
  def set_managed_enabled(scope, %RemoteAccessDesktopTarget{} = target, true) do
    with {:ok, target} <-
           target
           |> Ash.Changeset.for_update(:enable, %{})
           |> Ash.update(scope: scope) do
      get_managed(scope, target.id)
    end
  end

  def set_managed_enabled(scope, %RemoteAccessDesktopTarget{} = target, false) do
    with {:ok, target} <-
           target
           |> Ash.Changeset.for_update(:disable, %{})
           |> Ash.update(scope: scope) do
      get_managed(scope, target.id)
    end
  end

  @spec get_authorized(term(), String.t(), keyword()) :: {:ok, target()} | {:error, term()}
  def get_authorized(scope, target_id, opts \\ []) when is_binary(target_id) do
    with {:ok, targets} <- list_authorized(scope, opts) do
      case Enum.find(targets, &(Map.get(&1, "id") == target_id and Map.get(&1, "enabled") == true)) do
        nil -> {:error, :remote_access_desktop_target_not_found}
        target -> {:ok, target}
      end
    end
  end

  defp configured_provider do
    Application.get_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)
  end

  defp load_targets(nil, scope, _opts) do
    case Application.get_env(:serviceradar_web_ng, :remote_access_desktop_targets) do
      targets when is_list(targets) ->
        {:ok, targets}

      _unset ->
        case RemoteAccessDesktopTarget.list_enabled(scope: scope) do
          {:ok, targets} -> {:ok, Enum.map(targets, &resource_target_attrs/1)}
          {:error, error} -> {:error, error}
        end
    end
  end

  defp load_targets(provider, scope, opts) when is_function(provider, 2), do: provider.(scope, opts)

  defp load_targets(provider, scope, opts) when is_atom(provider) do
    if function_exported?(provider, :list_authorized, 2) do
      provider.list_authorized(scope, opts)
    else
      {:error, :invalid_remote_access_desktop_target_provider}
    end
  end

  defp load_targets(_provider, _scope, _opts), do: {:error, :invalid_remote_access_desktop_target_provider}

  defp normalize_targets(targets) when is_list(targets) do
    Enum.flat_map(targets, fn target ->
      case normalize_target(target) do
        {:ok, normalized} -> [normalized]
        :error -> []
      end
    end)
  end

  defp normalize_targets(_targets), do: []

  defp resource_target_attrs(%RemoteAccessDesktopTarget{} = target) do
    %{
      id: target.id,
      label: target.name,
      device_uid: target.device_uid,
      target_kind: target.target_kind,
      target_host: target.target_host,
      target_port: target.target_port,
      agent_id: target.agent_id,
      gateway_id: target.gateway_id,
      credential_custody_mode: target.credential_custody_mode,
      credential_rule_id: target.credential_rule_id,
      approval_required: target.approval_required,
      allowed_principals: target.allowed_principals || [],
      target_tls: target.target_tls,
      nla: target.nla,
      screen_policy: target.screen_policy,
      redirection_policy: target.redirection_policy,
      recording_policy: target.recording_policy,
      metadata: target.metadata || %{}
    }
  end

  defp normalize_target(target) when is_map(target) do
    with {:ok, target_id} <- string_field(target, ["id", :id, "target_id", :target_id]),
         {:ok, target_host} <- string_field(target, ["target_host", :target_host, "host", :host]) do
      metadata = safe_map_field(target, ["metadata", :metadata])

      {:ok,
       reject_empty(%{
         "id" => target_id,
         "enabled" => boolean_field(target, ["enabled", :enabled], true),
         "label" => string_field_value(target, ["label", :label, "name", :name]) || target_host,
         "device_uid" => string_field_value(target, ["device_uid", :device_uid, "uid", :uid]),
         "target_kind" => string_field_value(target, ["target_kind", :target_kind]) || "inventory_device",
         "target_host" => target_host,
         "target_port" => port_field(target),
         "protocol" => "rdp",
         "adapter" => "rdp",
         "credential_custody_mode" =>
           string_field_value(target, ["credential_custody_mode", :credential_custody_mode]) || "user_present",
         "credential_rule_id" => string_field_value(target, ["credential_rule_id", :credential_rule_id]),
         "approval_required" => boolean_field(target, ["approval_required", :approval_required], false),
         "allowed_principals" => string_list_field(target, metadata, ["allowed_principals", :allowed_principals]),
         "route" =>
           compact_map(%{
             "agent_id" => string_field_value(target, ["agent_id", :agent_id]),
             "gateway_id" => string_field_value(target, ["gateway_id", :gateway_id])
           }),
         "desktop_policy" =>
           compact_map(%{
             "target_tls" => first_safe_policy(target, metadata, ["target_tls", :target_tls, "tls", :tls]),
             "nla" => first_safe_policy(target, metadata, ["nla", :nla, "nla_policy", :nla_policy]),
             "screen_policy" => first_safe_policy(target, metadata, ["screen_policy", :screen_policy, "screen", :screen]),
             "redirection_policy" =>
               first_safe_policy(target, metadata, [
                 "redirection_policy",
                 :redirection_policy,
                 "redirection",
                 :redirection
               ]),
             "approval_policy" =>
               first_safe_policy(target, metadata, ["approval_policy", :approval_policy, "approval", :approval])
           }),
         "recording_policy" => first_safe_policy(target, metadata, ["recording_policy", :recording_policy]),
         "metadata" => safe_metadata(metadata)
       })}
    end
  end

  defp normalize_target(_target), do: :error

  defp string_field(map, keys) do
    case string_field_value(map, keys) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp string_field_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) ->
          value = String.trim(value)
          if value == "", do: nil, else: value

        value when is_atom(value) and not is_nil(value) ->
          Atom.to_string(value)

        value when is_integer(value) ->
          Integer.to_string(value)

        _ ->
          nil
      end
    end)
  end

  defp port_field(map) do
    raw = Map.get(map, "target_port", Map.get(map, :target_port, Map.get(map, "port", Map.get(map, :port))))

    case normalize_port(raw) do
      port when is_integer(port) -> port
      nil -> @default_target_port
    end
  end

  defp normalize_port(value) when is_integer(value) and value in @min_port..@max_port, do: value

  defp normalize_port(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {port, ""} when port in @min_port..@max_port -> port
      _ -> nil
    end
  end

  defp normalize_port(_value), do: nil

  defp boolean_field(map, keys, default) do
    Enum.reduce_while(keys, default, fn key, _acc ->
      case Map.get(map, key) do
        value when is_boolean(value) -> {:halt, value}
        value when value in ["true", "1", "yes", "on"] -> {:halt, true}
        value when value in ["false", "0", "no", "off"] -> {:halt, false}
        _ -> {:cont, default}
      end
    end)
  end

  defp first_safe_policy(target, metadata, keys) do
    case first_map_value(target, keys) || first_map_value(metadata, keys) do
      value when is_map(value) -> scrub_secrets(value)
      _ -> nil
    end
  end

  defp first_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp first_map_value(_map, _keys), do: nil

  defp string_list_field(target, metadata, keys) do
    case first_map_value(target, keys) || first_map_value(metadata, keys) do
      values when is_list(values) ->
        values
        |> Enum.flat_map(fn
          value when is_binary(value) ->
            case String.trim(value) do
              "" -> []
              principal -> [principal]
            end

          _value ->
            []
        end)
        |> Enum.uniq()

      _value ->
        []
    end
  end

  defp safe_map_field(map, keys) do
    case first_map_value(map, keys) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> scrub_secrets()
    |> Map.drop([
      "target_tls",
      :target_tls,
      "tls",
      :tls,
      "nla",
      :nla,
      "nla_policy",
      :nla_policy,
      "screen_policy",
      :screen_policy,
      "screen",
      :screen,
      "redirection_policy",
      :redirection_policy,
      "redirection",
      :redirection,
      "approval_policy",
      :approval_policy,
      "approval",
      :approval,
      "recording_policy",
      :recording_policy
    ])
    |> reject_empty()
  end

  defp scrub_secrets(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_string = to_string(key)

      if secret_key?(key_string) do
        acc
      else
        Map.put(acc, key_string, scrub_secrets(value))
      end
    end)
    |> reject_empty()
  end

  defp scrub_secrets(list) when is_list(list), do: Enum.map(list, &scrub_secrets/1)
  defp scrub_secrets(value), do: value

  defp secret_key?(key) do
    normalized = String.downcase(key)
    normalized in @secret_keys or Enum.any?(@secret_suffixes, &String.ends_with?(normalized, &1))
  end

  defp compact_map(map), do: reject_empty(map)

  defp reject_empty(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, "", [], %{}] end)
    |> Map.new()
  end
end
