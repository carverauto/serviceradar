defmodule ServiceRadar.Edge.RemoteAccessSSHSessionCredentials do
  @moduledoc """
  Builds in-memory SSH credential grants for remote-access session opens.

  This boundary combines a user-present private key with a ServiceRadar-issued
  short-lived SSH certificate. The returned value is intended to be passed
  directly to `RemoteAccessBroker.start_link/3`; callers must not persist it.
  """

  alias ServiceRadar.Edge.RemoteAccessSSHCertificates

  @type grant :: %{
          broker_opts: keyword(),
          ssh_certificate: map(),
          audit: map()
        }

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

  defp ssh_session_key(private_key, nil), do: %{"private_key" => private_key}

  defp ssh_session_key(private_key, passphrase),
    do: %{"private_key" => private_key, "passphrase" => passphrase}

  defp audit(issued) do
    issued
    |> Map.get(:audit, %{})
    |> Map.put(:credential_custody_mode, "user_present")
    |> Map.put(:credential_mode, Map.get(issued, :credential_mode))
    |> Map.put(:session_id, Map.get(issued, :session_id))
  end

  defp required_string(attrs, key) do
    case optional_string(attrs, key) do
      nil -> {:error, required_error(key)}
      value -> {:ok, value}
    end
  end

  defp required_error("private_key"), do: :session_private_key_required
  defp required_error(_key), do: :invalid_request

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
