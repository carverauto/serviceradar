defmodule ServiceRadar.Edge.RemoteAccessSSHCertificatePolicy do
  @moduledoc """
  Pure policy checks for issuing generic SSH remote-access user certificates.

  This module does not sign certificates and does not read secrets. It turns an
  authenticated actor, a registered target, and a principal policy decision into
  the bounded request shape that a ServiceRadar SSH CA issuer can sign.
  """

  alias ServiceRadar.Edge.RemoteAccessSSHPrincipalMapper
  alias ServiceRadar.Identity.RBAC

  @permission "devices.remote_access.ssh.open"
  @default_ttl_seconds 3_600
  @max_ttl_seconds 8 * 3_600
  @max_accounts 128
  @max_principals 16
  @id_max_bytes 128
  @public_key_max_bytes 16_384
  @target_value_max_bytes 512
  @ssh_username_max_bytes 32
  @ssh_username_pattern ~r/^[a-z_][a-z0-9_-]{0,31}$/
  @opaque_principal_pattern ~r/^srp_v1_[A-Za-z0-9_-]{20,96}$/

  @type request :: %{
          session_id: String.t(),
          agent_id: String.t(),
          gateway_id: String.t() | nil,
          protocol: String.t(),
          public_key: String.t(),
          key_id: String.t(),
          principals: [String.t()],
          ssh_username: String.t(),
          ttl_seconds: pos_integer(),
          target: map(),
          credential_mode: String.t(),
          audit: map()
        }

  @spec permission() :: String.t()
  def permission, do: @permission

  @spec authorize(map() | struct(), map(), keyword()) :: {:ok, request()} | {:error, atom()}
  def authorize(actor, attrs, opts \\ [])

  def authorize(actor, attrs, opts) when is_map(attrs) do
    with :ok <- authorize_actor(actor),
         {:ok, session_id} <- required_string(attrs, "session_id", @id_max_bytes),
         {:ok, agent_id} <- required_string(attrs, "agent_id", @id_max_bytes),
         {:ok, protocol} <- resolve_protocol(attrs),
         {:ok, public_key} <- required_string(attrs, "public_key", @public_key_max_bytes),
         {:ok, target} <- normalize_target(value(attrs, "target")),
         {:ok, ssh_username} <- resolve_ssh_username(attrs),
         {:ok, principals} <- resolve_principals(attrs, ssh_username),
         {:ok, ttl_seconds} <- resolve_ttl(attrs, opts) do
      actor_id = actor_ref(actor)
      target_ref = target_ref(target)
      gateway_id = string_value(value(attrs, "gateway_id"))

      {:ok,
       %{
         session_id: session_id,
         agent_id: agent_id,
         gateway_id: gateway_id,
         protocol: protocol,
         public_key: public_key,
         key_id: key_id(session_id, actor_id, agent_id, protocol, target_ref),
         principals: principals,
         ssh_username: ssh_username,
         ttl_seconds: ttl_seconds,
         target: target,
         credential_mode: "ssh_certificate",
         audit: %{
           actor_id: actor_id,
           agent_id: agent_id,
           gateway_id: gateway_id,
           protocol: protocol,
           target_ref: target_ref,
           principals: principals,
           ssh_username: ssh_username,
           ttl_seconds: ttl_seconds,
           permission: @permission
         }
       }}
    end
  end

  def authorize(_actor, _attrs, _opts), do: {:error, :invalid_request}

  defp authorize_actor(%{role: :system}), do: :ok

  defp authorize_actor(actor) when is_map(actor) do
    if RBAC.has_permission?(actor, @permission) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_actor(_actor), do: {:error, :unauthenticated}

  defp required_string(attrs, key, max_bytes) do
    case string_value(value(attrs, key)) do
      nil -> {:error, required_error(key)}
      value when byte_size(value) <= max_bytes -> {:ok, value}
      _value -> {:error, :invalid_size}
    end
  end

  defp required_error("session_id"), do: :session_id_required
  defp required_error("agent_id"), do: :agent_id_required
  defp required_error("public_key"), do: :public_key_required
  defp required_error("username"), do: :ssh_username_required
  defp required_error(_key), do: :invalid_request

  defp resolve_protocol(attrs) do
    case string_value(value(attrs, "protocol")) || "ssh" do
      "ssh" -> {:ok, "ssh"}
      _protocol -> {:error, :unsupported_protocol}
    end
  end

  defp normalize_target(target) when is_map(target) do
    with {:ok, target} <-
           target
           |> stringify_keys()
           |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
             case normalize_target_value(key, value) do
               :invalid_size -> {:halt, {:error, :invalid_size}}
               nil -> {:cont, {:ok, acc}}
               normalized -> {:cont, {:ok, Map.put(acc, key, normalized)}}
             end
           end) do
      if target_ref(target) do
        {:ok, target}
      else
        {:error, :target_required}
      end
    end
  end

  defp normalize_target(_target), do: {:error, :target_required}

  defp normalize_target_value("port", value) do
    case positive_int(value) do
      port when is_integer(port) and port <= 65_535 -> port
      nil -> nil
      _port -> :invalid_size
    end
  end

  defp normalize_target_value(_key, value) do
    case string_value(value) do
      nil -> nil
      string when byte_size(string) <= @target_value_max_bytes -> string
      _string -> :invalid_size
    end
  end

  defp resolve_ssh_username(attrs) do
    with {:ok, username} <- required_string(attrs, "username", @ssh_username_max_bytes),
         true <- username != "root" and Regex.match?(@ssh_username_pattern, username) do
      {:ok, username}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :ssh_username_denied}
    end
  end

  defp resolve_principals(attrs, ssh_username) do
    with {:ok, accounts} <- normalize_accounts(account_policy(attrs)),
         {:ok, account_principals} <- principals_for_account(accounts, ssh_username) do
      apply_identity_mapping(attrs, account_principals)
    end
  end

  defp account_policy(attrs) do
    case value(attrs, "accounts") do
      nil -> value(attrs, "ssh_accounts")
      accounts -> accounts
    end
  end

  defp normalize_accounts(accounts) when is_list(accounts) do
    cond do
      accounts == [] ->
        {:error, :ssh_principal_policy_required}

      length(accounts) > @max_accounts ->
        {:error, :invalid_size}

      true ->
        with {:ok, normalized} <- normalize_account_entries(accounts),
             true <- unique_account_names?(normalized),
             true <- unique_account_principals?(normalized) do
          {:ok, normalized}
        else
          false -> {:error, :ssh_principal_policy_required}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp normalize_accounts(_accounts), do: {:error, :ssh_principal_policy_required}

  defp normalize_account_entries(accounts) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      case normalize_account(account) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_account(account) when is_map(account) do
    with {:ok, name} <- normalize_account_name(value(account, "name")),
         {:ok, principals} <- normalize_opaque_principals(value(account, "principals")) do
      {:ok, %{name: name, principals: principals}}
    end
  end

  defp normalize_account(_account), do: {:error, :ssh_principal_policy_required}

  defp normalize_account_name(name) when is_binary(name) do
    if name == String.trim(name) and name != "root" and
         Regex.match?(@ssh_username_pattern, name) do
      {:ok, name}
    else
      {:error, :ssh_principal_policy_required}
    end
  end

  defp normalize_account_name(_name), do: {:error, :ssh_principal_policy_required}

  defp normalize_opaque_principals(principals) when is_list(principals) do
    cond do
      principals == [] ->
        {:error, :ssh_principal_policy_required}

      length(principals) > @max_principals ->
        {:error, :invalid_size}

      true ->
        with true <- Enum.all?(principals, &valid_opaque_principal?/1),
             true <- length(Enum.uniq(principals)) == length(principals) do
          {:ok, principals}
        else
          false -> {:error, :ssh_principal_policy_required}
        end
    end
  end

  defp normalize_opaque_principals(_principals), do: {:error, :ssh_principal_policy_required}

  defp valid_opaque_principal?(principal) when is_binary(principal) do
    principal == String.trim(principal) and Regex.match?(@opaque_principal_pattern, principal)
  end

  defp valid_opaque_principal?(_principal), do: false

  defp unique_account_names?(accounts) do
    names = Enum.map(accounts, & &1.name)
    length(Enum.uniq(names)) == length(names)
  end

  defp unique_account_principals?(accounts) do
    principals = Enum.flat_map(accounts, & &1.principals)
    length(Enum.uniq(principals)) == length(principals)
  end

  defp principals_for_account(accounts, ssh_username) do
    case Enum.find(accounts, &(&1.name == ssh_username)) do
      nil -> {:error, :ssh_username_denied}
      account -> {:ok, account.principals}
    end
  end

  defp apply_identity_mapping(attrs, account_principals) do
    mappings = value(attrs, "principal_mappings") || value(attrs, "ssh_principal_mappings")

    case mappings do
      nil ->
        {:ok, account_principals}

      [] ->
        {:ok, account_principals}

      mappings when is_list(mappings) ->
        selected = Enum.filter(account_principals, &(&1 in mapped_principals(attrs)))

        if selected == [], do: {:error, :ssh_principal_denied}, else: {:ok, selected}

      _mappings ->
        {:error, :ssh_principal_denied}
    end
  end

  defp mapped_principals(attrs) do
    claims = value(attrs, "claims") || value(attrs, "idp_claims") || %{}
    mappings = value(attrs, "principal_mappings") || value(attrs, "ssh_principal_mappings") || []

    RemoteAccessSSHPrincipalMapper.resolve(claims, mappings)
  end

  defp resolve_ttl(attrs, opts) do
    max_ttl = Keyword.get(opts, :max_ttl_seconds, @max_ttl_seconds)
    ttl = positive_int(value(attrs, "ttl_seconds")) || @default_ttl_seconds

    cond do
      ttl <= 0 -> {:error, :ttl_required}
      max_ttl > 0 and ttl > max_ttl -> {:error, :ttl_exceeds_maximum}
      true -> {:ok, ttl}
    end
  end

  defp key_id(session_id, actor_id, agent_id, protocol, target_ref) do
    "sr:remote-access:#{session_id}:#{actor_id || "unknown-actor"}:#{agent_id}:#{protocol}:#{target_ref}"
  end

  defp actor_ref(actor),
    do: string_value(value(actor, "id")) || string_value(value(actor, "external_id"))

  defp target_ref(target) do
    string_value(value(target, "id")) ||
      string_value(value(target, "device_uid")) ||
      string_value(value(target, "uid")) ||
      string_value(value(target, "host"))
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp positive_int(value) when is_integer(value) and value > 0, do: value

  defp positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp positive_int(_value), do: nil

  defp string_value(nil), do: nil

  defp string_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(_value), do: nil

  defp value(container, key) when is_map(container) do
    Map.get(container, key) || Map.get(container, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(container, key)
  end

  defp value(_container, _key), do: nil
end
