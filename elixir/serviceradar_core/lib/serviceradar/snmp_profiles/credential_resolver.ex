defmodule ServiceRadar.SNMPProfiles.CredentialResolver do
  @moduledoc """
  Resolves SNMP credentials for devices using per-device overrides and profiles.

  Resolution order:
  1. Device-specific override
  2. Profile credentials (SRQL targeting + default fallback)
  3. None
  """

  require Ash.Query
  require Logger

  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.Vault

  @type credential_map :: %{
          version: atom(),
          community: String.t() | nil,
          username: String.t() | nil,
          security_level: atom() | nil,
          auth_protocol: atom() | nil,
          auth_password: String.t() | nil,
          priv_protocol: atom() | nil,
          priv_password: String.t() | nil
        }

  @doc """
  Resolve credentials for a device UID.
  """
  @spec resolve_for_device(String.t() | nil, map()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_for_device(nil, _actor) do
    {:ok, %{credential: nil, profile: nil, source: :none}}
  end

  def resolve_for_device(device_uid, actor) when is_binary(device_uid) do
    case load_device_override(device_uid, actor) do
      {:ok, %DeviceSNMPCredential{} = override} ->
        {:ok, %{credential: build_credential(override), profile: nil, source: :device_override}}

      {:ok, nil} ->
        profile = resolve_profile(device_uid, actor)
        credential = build_credential(profile)

        if credential_present?(credential) do
          {:ok, %{credential: credential, profile: profile, source: :profile}}
        else
          {:ok, %{credential: nil, profile: profile, source: :none}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve credentials from the instance default SNMP profile.

  Useful when no device UID is available but callers still need a concrete
  SNMP credential instead of an empty v2c fallback.
  """
  @spec resolve_default(map()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_default(actor) do
    profile = get_default_profile(actor)
    credential = build_credential(profile)

    if credential_present?(credential) do
      {:ok, %{credential: credential, profile: profile, source: :default_profile}}
    else
      {:ok, %{credential: nil, profile: profile, source: :none}}
    end
  end

  @doc """
  Resolve credentials for a target host (IP/hostname/device UID).
  """
  @spec resolve_for_host(String.t() | nil, map()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_for_host(nil, _actor), do: {:ok, %{credential: nil, profile: nil, source: :none}}

  def resolve_for_host(host, actor) when is_binary(host) do
    case lookup_device_uid(host, actor) do
      {:ok, device_uid} -> resolve_for_device(device_uid, actor)
      {:error, _} -> {:ok, %{credential: nil, profile: nil, source: :none}}
    end
  end

  @doc """
  Convert a resolved credential map into mapper config credentials.
  """
  @spec to_mapper_credentials(credential_map() | nil) :: map()
  def to_mapper_credentials(nil), do: %{}

  def to_mapper_credentials(%{} = credential) do
    %{
      "version" => format_version(Map.get(credential, :version)),
      "community" => Map.get(credential, :community),
      "username" => Map.get(credential, :username),
      "auth_protocol" => format_auth_protocol(Map.get(credential, :auth_protocol)),
      "auth_password" => Map.get(credential, :auth_password),
      "privacy_protocol" => format_priv_protocol(Map.get(credential, :priv_protocol)),
      "privacy_password" => Map.get(credential, :priv_password)
    }
    |> compact_map()
  end

  defp resolve_profile(device_uid, actor) do
    case SrqlTargetResolver.resolve_for_device(device_uid, actor) do
      {:ok, %SNMPProfile{} = profile} ->
        load_profile(profile.id, actor)

      {:ok, nil} ->
        get_default_profile(actor)

      {:error, reason} ->
        Logger.warning("SNMPCredentialResolver: SRQL targeting failed - #{inspect(reason)}")
        get_default_profile(actor)
    end
  end

  defp get_default_profile(actor) do
    query = Ash.Query.for_read(SNMPProfile, :get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, %SNMPProfile{} = profile} -> load_profile(profile.id, actor)
      {:error, _} -> nil
      _ -> nil
    end
  end

  defp load_profile(nil, _actor), do: nil

  defp load_profile(profile_id, actor) do
    query =
      SNMPProfile
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(id == ^profile_id)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, %SNMPProfile{} = profile} -> profile
      _ -> nil
    end
  end

  defp load_device_override(device_uid, actor) do
    DeviceSNMPCredential
    |> Ash.Query.for_read(:by_device, %{device_id: device_uid})
    |> Ash.read_one(actor: actor)
  end

  defp lookup_device_uid(host, actor) do
    case Device.get_by_uid(host, false, actor: actor) do
      {:ok, %Device{} = device} ->
        {:ok, device.uid}

      _ ->
        case lookup_device_uid_by_fields(host, actor) do
          {:ok, device_uid} ->
            {:ok, device_uid}

          {:error, :device_not_found} ->
            lookup_device_uid_by_ip_alias(host, actor)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp lookup_device_uid_by_fields(host, actor) do
    query =
      Device
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(ip == ^host or hostname == ^host or name == ^host)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, %Device{} = device} -> {:ok, device.uid}
      {:ok, nil} -> {:error, :device_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lookup_device_uid_by_ip_alias(host, actor) do
    query =
      DeviceAliasState
      |> Ash.Query.filter(
        alias_type == :ip and alias_value == ^host and state in [:confirmed, :updated]
      )
      |> Ash.Query.limit(1)

    case Ash.read_one(query, actor: actor) do
      {:ok, %DeviceAliasState{device_id: device_id}} -> {:ok, device_id}
      {:ok, nil} -> {:error, :device_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_credential(nil), do: nil

  defp build_credential(%{version: version} = record) do
    %{
      version: version || :v2c,
      community: decrypt_credential(Map.get(record, :community_encrypted)),
      username: Map.get(record, :username),
      security_level: Map.get(record, :security_level),
      auth_protocol: Map.get(record, :auth_protocol),
      auth_password: decrypt_credential(Map.get(record, :auth_password_encrypted)),
      priv_protocol: Map.get(record, :priv_protocol),
      priv_password: decrypt_credential(Map.get(record, :priv_password_encrypted))
    }
  end

  defp decrypt_credential(nil), do: nil

  defp decrypt_credential(encrypted) do
    case Vault.decrypt(encrypted) do
      {:ok, decrypted} -> decrypted
      {:error, _} -> nil
    end
  end

  defp credential_present?(nil), do: false

  defp credential_present?(credential) when is_map(credential) do
    case Map.get(credential, :version, :v2c) do
      :v3 ->
        present?(Map.get(credential, :username)) or
          present?(Map.get(credential, :auth_password)) or
          present?(Map.get(credential, :priv_password))

      _ ->
        present?(Map.get(credential, :community))
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true

  defp format_version(:v1), do: "v1"
  defp format_version(:v2c), do: "v2c"
  defp format_version(:v3), do: "v3"
  defp format_version(nil), do: "v2c"
  defp format_version(other) when is_binary(other), do: other
  defp format_version(_), do: "v2c"

  defp format_auth_protocol(nil), do: nil
  defp format_auth_protocol(:md5), do: "MD5"
  defp format_auth_protocol(:sha), do: "SHA"
  defp format_auth_protocol(:sha224), do: "SHA224"
  defp format_auth_protocol(:sha256), do: "SHA256"
  defp format_auth_protocol(:sha384), do: "SHA384"
  defp format_auth_protocol(:sha512), do: "SHA512"
  defp format_auth_protocol(protocol) when is_binary(protocol), do: String.upcase(protocol)
  defp format_auth_protocol(_), do: nil

  defp format_priv_protocol(nil), do: nil
  defp format_priv_protocol(:des), do: "DES"
  defp format_priv_protocol(:aes), do: "AES"
  defp format_priv_protocol(:aes192), do: "AES192"
  defp format_priv_protocol(:aes256), do: "AES256"
  defp format_priv_protocol(:aes192c), do: "AES192"
  defp format_priv_protocol(:aes256c), do: "AES256"
  defp format_priv_protocol(protocol) when is_binary(protocol), do: String.upcase(protocol)
  defp format_priv_protocol(_), do: nil

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end
end
