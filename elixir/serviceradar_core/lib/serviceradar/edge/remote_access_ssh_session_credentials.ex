defmodule ServiceRadar.Edge.RemoteAccessSSHSessionCredentials do
  @moduledoc """
  Builds in-memory SSH credential grants for remote-access session opens.

  This boundary combines a user-present private key with a ServiceRadar-issued
  short-lived SSH certificate. The returned value is intended to be passed
  directly to `RemoteAccessBroker.start_link/3`; callers must not persist it.
  """

  alias ServiceRadar.Edge.RemoteAccessSSHCertificates
  alias ServiceRadar.Edge.RemoteAccessSSHIdentityIssuer

  @type grant :: %{
          broker_opts: keyword(),
          ssh_certificate: map() | nil,
          audit: map()
        }

  @spec build_user_present_grant(map(), keyword()) :: {:ok, grant()} | {:error, term()}
  def build_user_present_grant(attrs, opts \\ [])

  def build_user_present_grant(attrs, opts) when is_map(attrs) do
    with {:ok, username} <- required_string(attrs, "username"),
         {:ok, ssh_auth} <- user_present_ssh_auth(attrs, username) do
      credential_mode = Keyword.get(opts, :credential_mode, "user_present")
      metadata = session_metadata(ssh_auth, attrs)

      {:ok,
       %{
         broker_opts: [
           metadata: metadata,
           credential_mode: credential_mode
         ],
         ssh_certificate: nil,
         audit: user_present_audit(attrs, credential_mode)
       }}
    end
  end

  def build_user_present_grant(_attrs, _opts), do: {:error, :invalid_request}

  @spec build_certificate_grant(map() | struct(), map(), keyword()) ::
          {:ok, grant()} | {:error, term()}
  def build_certificate_grant(actor, attrs, opts \\ [])

  def build_certificate_grant(actor, attrs, opts) when is_map(attrs) do
    with {:ok, private_key} <- required_string(attrs, "private_key"),
         passphrase = optional_string(attrs, "passphrase"),
         {:ok, issued} <- RemoteAccessSSHCertificates.issue(actor, attrs, opts) do
      {:ok,
       %{
         broker_opts: [
           metadata: %{"ssh" => ssh_session_key(private_key, passphrase)},
           ssh_certificate: issued
         ],
         ssh_certificate: issued,
         audit: audit(issued)
       }}
    end
  end

  def build_certificate_grant(_actor, _attrs, _opts), do: {:error, :invalid_request}

  @spec build_identity_certificate_grant(map() | struct(), map(), keyword()) ::
          {:ok, grant()} | {:error, term()}
  def build_identity_certificate_grant(actor, attrs, opts \\ [])

  def build_identity_certificate_grant(actor, attrs, opts) when is_map(attrs) do
    with {:ok, private_key} <- required_string(attrs, "private_key"),
         passphrase = optional_string(attrs, "passphrase"),
         {:ok, issued} <- RemoteAccessSSHIdentityIssuer.issue(actor, attrs, opts) do
      {:ok,
       %{
         broker_opts: [
           metadata: %{"ssh" => ssh_session_key(private_key, passphrase)},
           ssh_certificate: issued
         ],
         ssh_certificate: issued,
         audit: audit(issued)
       }}
    end
  end

  def build_identity_certificate_grant(_actor, _attrs, _opts), do: {:error, :invalid_request}

  defp session_metadata(ssh_auth, attrs) do
    maybe_put(%{"ssh" => ssh_auth}, "target", normalize_target(value(attrs, "target")))
  end

  defp user_present_ssh_auth(attrs, username) do
    private_key = optional_string(attrs, "private_key")
    passphrase = optional_string(attrs, "passphrase")
    password = optional_string(attrs, "password")

    cond do
      private_key ->
        {:ok,
         maybe_put(
           %{"username" => username, "private_key" => private_key},
           "passphrase",
           passphrase
         )}

      password ->
        {:ok, %{"username" => username, "password" => password}}

      true ->
        {:error, :session_credential_required}
    end
  end

  defp ssh_session_key(private_key, nil), do: %{"private_key" => private_key}

  defp ssh_session_key(private_key, passphrase),
    do: %{"private_key" => private_key, "passphrase" => passphrase}

  defp user_present_audit(attrs, credential_mode) do
    %{
      credential_custody_mode: "user_present",
      credential_mode: credential_mode,
      session_id: optional_string(attrs, "session_id"),
      agent_id: optional_string(attrs, "agent_id"),
      target_ref: target_ref(value(attrs, "target")),
      ssh_username: optional_string(attrs, "username"),
      credential_kind: credential_kind(attrs)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp audit(issued) do
    issued
    |> Map.get(:audit, %{})
    |> Map.put(:credential_custody_mode, "short_lived_certificate")
    |> Map.put(:credential_mode, Map.get(issued, :credential_mode))
    |> Map.put(:session_id, Map.get(issued, :session_id))
  end

  defp credential_kind(attrs) do
    cond do
      optional_string(attrs, "private_key") -> "private_key"
      optional_string(attrs, "password") -> "password"
      true -> nil
    end
  end

  defp target_ref(target) when is_map(target) do
    optional_string(target, "id") ||
      optional_string(target, "device_uid") ||
      optional_string(target, "uid") ||
      optional_string(target, "host")
  end

  defp target_ref(_target), do: nil

  defp normalize_target(target) when is_map(target) do
    target
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case target_value(value) do
        nil -> acc
        normalized -> Map.put(acc, to_string(key), normalized)
      end
    end)
    |> empty_to_nil()
  end

  defp normalize_target(_target), do: nil

  defp target_value(value) when is_integer(value) and value > 0, do: value
  defp target_value(value), do: string_or_nil(value)

  defp empty_to_nil(map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map

  defp required_string(attrs, key) do
    case optional_string(attrs, key) do
      nil -> {:error, required_error(key)}
      value -> {:ok, value}
    end
  end

  defp required_error("username"), do: :ssh_username_required
  defp required_error("private_key"), do: :session_private_key_required
  defp required_error(_key), do: :invalid_request

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp optional_string(attrs, key), do: attrs |> value(key) |> string_or_nil()

  defp value(container, key) when is_map(container) do
    atom_key = safe_existing_atom(key)
    Map.get(container, key) || (atom_key && Map.get(container, atom_key))
  end

  defp value(_container, _key), do: nil

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp string_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_or_nil(_value), do: nil
end
