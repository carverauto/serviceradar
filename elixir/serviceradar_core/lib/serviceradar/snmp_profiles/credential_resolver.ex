defmodule ServiceRadar.SNMPProfiles.CredentialResolver do
  @moduledoc """
  Resolves SNMP credentials for devices using per-device overrides,
  credential rules, and profiles.

  Resolution order:
  1. Device-specific override
  2. Matching SNMP credential rule (provider snmp, purpose snmp_monitoring)
  3. Profile credentials (SRQL targeting + default fallback)
  4. None
  """

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.SecretBroker
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.SNMPProfiles.ProtocolFormatter
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SrqlTargetResolver
  alias ServiceRadar.SRQLAst
  alias ServiceRadar.SRQLDeviceMatcher
  alias ServiceRadar.Vault

  require Ash.Query
  require Logger

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
  @spec resolve_for_device(String.t() | nil, map(), keyword()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_for_device(device_uid, actor, opts \\ [])

  def resolve_for_device(nil, _actor, _opts) do
    {:ok, %{credential: nil, profile: nil, source: :none}}
  end

  def resolve_for_device(device_uid, actor, opts) when is_binary(device_uid) do
    case load_device_override(device_uid, actor) do
      {:ok, %DeviceSNMPCredential{} = override} ->
        credential =
          build_credential(override, actor,
            consumer_id: "device_snmp_credential:#{override.id}",
            target_kind: "device",
            target_id: device_uid
          )

        case credential do
          {:error, reason} -> {:error, reason}
          credential -> {:ok, %{credential: credential, profile: nil, source: :device_override}}
        end

      {:ok, nil} ->
        resolve_rule_or_profile(device_uid, actor, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Resolve credentials from the instance default SNMP profile.

  Useful when no device UID is available but callers still need a concrete
  SNMP credential instead of an empty v2c fallback.
  """
  @spec resolve_default(map(), keyword()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_default(actor, opts \\ []) do
    case resolve_rule_credential(opts, nil, actor) do
      {:ok, credential} ->
        {:ok,
         %{
           credential: credential,
           profile: get_default_profile(actor),
           source: :credential_rule
         }}

      {:error, reason} ->
        {:error, reason}

      :none ->
        profile = get_default_profile(actor)

        credential =
          build_credential(profile, actor,
            consumer_id: profile && "snmp_profile:#{profile.id}",
            target_kind: "snmp_profile",
            target_id: profile && profile.id
          )

        case credential do
          {:error, reason} ->
            {:error, reason}

          credential ->
            if credential_present?(credential) do
              {:ok, %{credential: credential, profile: profile, source: :default_profile}}
            else
              {:ok, %{credential: nil, profile: profile, source: :none}}
            end
        end
    end
  end

  @doc """
  Resolve credentials for a target host (IP/hostname/device UID).
  """
  @spec resolve_for_host(String.t() | nil, map()) ::
          {:ok,
           %{credential: credential_map() | nil, profile: SNMPProfile.t() | nil, source: atom()}}
          | {:error, term()}
  def resolve_for_host(host, actor, opts \\ [])

  def resolve_for_host(nil, _actor, _opts),
    do: {:ok, %{credential: nil, profile: nil, source: :none}}

  def resolve_for_host(host, actor, opts) when is_binary(host) do
    case lookup_device_uid(host, actor) do
      {:ok, device_uid} ->
        resolve_for_device(device_uid, actor, opts)

      {:error, _} ->
        case resolve_rule_credential(opts, nil, actor) do
          {:ok, credential} ->
            {:ok, %{credential: credential, profile: nil, source: :credential_rule}}

          {:error, reason} ->
            {:error, reason}

          :none ->
            {:ok, %{credential: nil, profile: nil, source: :none}}
        end
    end
  end

  @type description :: %{
          source: :device_override | :profile | :default_profile | :none,
          profile: SNMPProfile.t() | nil,
          override: DeviceSNMPCredential.t() | nil,
          version: atom() | nil,
          credential_secret_id: term(),
          credential_configured?: boolean()
        }

  @doc """
  Metadata-only view of what would poll a device.

  Does not decrypt community strings or broker secrets. Use this from UI
  surfaces that need to name the profile/credential without creating an
  audit event.
  """
  @spec describe_for_device(String.t() | nil, map()) :: {:ok, description()} | {:error, term()}
  def describe_for_device(nil, _actor), do: {:ok, empty_description()}

  def describe_for_device(device_uid, actor) when is_binary(device_uid) do
    override =
      case load_device_override(device_uid, actor) do
        {:ok, %DeviceSNMPCredential{} = cred} -> cred
        {:ok, nil} -> nil
        {:error, reason} -> {:error, reason}
      end

    case override do
      {:error, reason} ->
        {:error, reason}

      override ->
        targeting = targeting_profile(device_uid, actor)
        default = get_default_profile(actor)
        profile = targeting || default

        source =
          cond do
            not is_nil(override) -> :device_override
            not is_nil(targeting) -> :profile
            not is_nil(default) -> :default_profile
            true -> :none
          end

        record = override || profile

        {:ok,
         %{
           source: source,
           profile: profile,
           override: override,
           version: record && Map.get(record, :version),
           credential_secret_id: record && Map.get(record, :credential_secret_id),
           credential_configured?: record_has_credential?(record)
         }}
    end
  end

  defp empty_description do
    %{
      source: :none,
      profile: nil,
      override: nil,
      version: nil,
      credential_secret_id: nil,
      credential_configured?: false
    }
  end

  defp targeting_profile(device_uid, actor) do
    case SrqlTargetResolver.resolve_for_device(device_uid, actor) do
      {:ok, %SNMPProfile{} = profile} -> load_profile(profile.id, actor)
      _ -> nil
    end
  end

  @doc """
  Whether a profile or target record names any credential source at all.

  This is the question an operator can act on: a profile with no bound
  credential rule and no inline material compiles to zero targets, because
  `SNMPCompiler` skips every device whose credential fails to resolve. It is
  deliberately weaker than the compiler's `valid_credentials?/1`, which inspects
  the *decrypted* credential - that answer needs secret material the interface
  should never hold, and an operator cannot fix a missing password from a list
  view anyway.

  Public so the settings UI warns using the same predicate the resolver uses,
  rather than a copy that can drift away from it.
  """
  @spec record_has_credential?(map() | nil) :: boolean()
  def record_has_credential?(nil), do: false

  def record_has_credential?(record) do
    present?(Map.get(record, :credential_secret_id)) or
      present?(Map.get(record, :community_encrypted)) or
      present?(Map.get(record, :username)) or
      present?(Map.get(record, :auth_password_encrypted))
  end

  @doc """
  Convert a resolved credential map into mapper config credentials.
  """
  @spec to_mapper_credentials(credential_map() | nil) :: map()
  def to_mapper_credentials(nil), do: %{}

  def to_mapper_credentials(%{} = credential) do
    compact_map(%{
      "version" => ProtocolFormatter.version(Map.get(credential, :version), allow_binary?: true),
      "community" => Map.get(credential, :community),
      "username" => Map.get(credential, :username),
      "security_level" => ProtocolFormatter.security_level(Map.get(credential, :security_level)),
      "auth_protocol" =>
        ProtocolFormatter.auth_protocol(Map.get(credential, :auth_protocol),
          style: :compact,
          allow_binary?: true
        ),
      "auth_password" => Map.get(credential, :auth_password),
      "privacy_protocol" =>
        ProtocolFormatter.priv_protocol(Map.get(credential, :priv_protocol),
          style: :compact,
          allow_binary?: true
        ),
      "privacy_password" => Map.get(credential, :priv_password)
    })
  end

  @doc """
  Builds a concrete SNMP credential from either a broker-backed secret reference
  or the legacy encrypted SNMP fields on the record.

  Broker payloads can be either a raw community string for SNMPv1/v2c, or a JSON
  object with SNMP keys such as `version`, `community`, `username`,
  `security_level`, `auth_protocol`, `auth_password`, `priv_protocol`, and
  `priv_password`.
  """
  @spec build_credential(map() | nil, map(), keyword()) ::
          credential_map() | nil | {:error, term()}
  def build_credential(record, actor, opts \\ [])

  def build_credential(nil, _actor, _opts), do: nil

  def build_credential(%{version: version} = record, actor, opts) do
    case credential_secret_id(record) do
      secret_id when is_binary(secret_id) and secret_id != "" ->
        build_broker_credential(record, secret_id, actor, opts)

      _ ->
        finalize_credential(build_legacy_credential(record, version))
    end
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
    with false <- ip_literal?(host),
         {:ok, %Device{} = device} <- Device.get_by_uid(host, false, actor: actor) do
      {:ok, device.uid}
    else
      true ->
        lookup_device_uid_for_ip(host, actor)

      _ ->
        lookup_device_uid_by_identity(host, actor)
    end
  end

  defp lookup_device_uid_for_ip(host, actor) do
    case lookup_device_uid_by_ip_alias(host, actor) do
      {:ok, device_uid} ->
        {:ok, device_uid}

      {:error, :device_not_found} ->
        lookup_device_uid_by_identity(host, actor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_device_uid_by_identity(host, actor) do
    case Device.get_by_uid(host, false, actor: actor) do
      {:ok, %Device{} = device} ->
        {:ok, device.uid}

      _ ->
        lookup_device_uid_by_fields(host, actor)
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

  defp ip_literal?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _address} -> true
      {:error, _reason} -> false
    end
  end

  defp build_legacy_credential(record, version) do
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

  defp build_broker_credential(record, secret_id, actor, opts) do
    broker_opts =
      Keyword.reject(
        [
          actor: actor,
          audit?: true,
          consumer_kind: :snmp,
          consumer_id: Keyword.get(opts, :consumer_id) || record_consumer_id(record),
          purpose: Keyword.get(opts, :purpose, "snmp_monitoring"),
          target_kind: Keyword.get(opts, :target_kind) || record_target_kind(record),
          target_id: Keyword.get(opts, :target_id) || record_id(record),
          resolution_location: Keyword.get(opts, :resolution_location, :control_plane)
        ],
        fn {_key, value} -> is_nil(value) end
      )

    case SecretBroker.resolve_network_credential_secret(secret_id, broker_opts) do
      {:ok, %{value: payload, secret: secret}} ->
        finalize_credential(parse_broker_payload(payload, record, secret))

      {:error, reason} ->
        Logger.warning(
          "SNMPCredentialResolver: failed to resolve broker credential #{secret_id} - #{inspect(reason)}"
        )

        {:error, {:credential_resolution_failed, reason}}
    end
  end

  defp parse_broker_payload(payload, record, secret) when is_binary(payload) do
    trimmed = String.trim(payload)

    case Jason.decode(trimmed) do
      {:ok, decoded} when is_map(decoded) ->
        broker_json_credential(decoded, record, secret)

      _ ->
        broker_raw_credential(trimmed, record, secret)
    end
  end

  defp parse_broker_payload(_payload, _record, _secret), do: nil

  defp broker_json_credential(payload, record, secret) do
    version =
      normalize_version(map_value(payload, "version") || Map.get(record, :version) || :v2c)

    %{
      version: version,
      community: map_value(payload, "community"),
      username:
        map_value(payload, "username") || Map.get(record, :username) || Map.get(secret, :username),
      security_level:
        normalize_security_level(
          map_value(payload, "security_level") || Map.get(record, :security_level)
        ),
      auth_protocol:
        normalize_auth_protocol(
          map_value(payload, "auth_protocol") || Map.get(record, :auth_protocol)
        ),
      auth_password: map_value(payload, "auth_password"),
      priv_protocol:
        normalize_priv_protocol(
          map_value(payload, "priv_protocol") ||
            map_value(payload, "privacy_protocol") ||
            Map.get(record, :priv_protocol)
        ),
      priv_password: map_value(payload, "priv_password") || map_value(payload, "privacy_password")
    }
  end

  defp broker_raw_credential("", _record, _secret), do: nil

  defp broker_raw_credential(payload, record, secret) do
    version = normalize_version(Map.get(record, :version) || :v2c)

    %{
      version: version,
      community: if(version in [:v1, :v2c], do: payload),
      username: Map.get(record, :username) || Map.get(secret, :username),
      security_level: Map.get(record, :security_level),
      auth_protocol: Map.get(record, :auth_protocol),
      auth_password: nil,
      priv_protocol: Map.get(record, :priv_protocol),
      priv_password: nil
    }
  end

  defp credential_secret_id(record), do: Map.get(record, :credential_secret_id)

  defp record_id(record), do: Map.get(record, :id) && to_string(Map.get(record, :id))

  defp record_consumer_id(record) do
    cond do
      match?(%DeviceSNMPCredential{}, record) -> "device_snmp_credential:#{record.id}"
      match?(%SNMPProfile{}, record) -> "snmp_profile:#{record.id}"
      true -> record_id(record)
    end
  end

  defp record_target_kind(record) do
    cond do
      match?(%DeviceSNMPCredential{}, record) -> "device"
      match?(%SNMPProfile{}, record) -> "snmp_profile"
      true -> "snmp_target"
    end
  end

  defp map_value(map, key), do: Map.get(map, key) || Map.get(map, known_atom_key(key))

  defp known_atom_key("version"), do: :version
  defp known_atom_key("community"), do: :community
  defp known_atom_key("username"), do: :username
  defp known_atom_key("security_level"), do: :security_level
  defp known_atom_key("auth_protocol"), do: :auth_protocol
  defp known_atom_key("auth_password"), do: :auth_password
  defp known_atom_key("priv_protocol"), do: :priv_protocol
  defp known_atom_key("privacy_protocol"), do: :privacy_protocol
  defp known_atom_key("priv_password"), do: :priv_password
  defp known_atom_key("privacy_password"), do: :privacy_password
  defp known_atom_key(_key), do: nil

  defp normalize_version(value) when value in [:v1, :v2c, :v3], do: value
  defp normalize_version("v1"), do: :v1
  defp normalize_version("1"), do: :v1
  defp normalize_version("v2c"), do: :v2c
  defp normalize_version("2c"), do: :v2c
  defp normalize_version("v3"), do: :v3
  defp normalize_version("3"), do: :v3
  defp normalize_version(_value), do: :v2c

  defp normalize_security_level(value)
       when value in [:no_auth_no_priv, :auth_no_priv, :auth_priv], do: value

  defp normalize_security_level("noAuthNoPriv"), do: :no_auth_no_priv
  defp normalize_security_level("authNoPriv"), do: :auth_no_priv
  defp normalize_security_level("authPriv"), do: :auth_priv
  defp normalize_security_level("no_auth_no_priv"), do: :no_auth_no_priv
  defp normalize_security_level("auth_no_priv"), do: :auth_no_priv
  defp normalize_security_level("auth_priv"), do: :auth_priv
  defp normalize_security_level(_value), do: nil

  defp normalize_auth_protocol(value)
       when value in [:md5, :sha, :sha224, :sha256, :sha384, :sha512], do: value

  defp normalize_auth_protocol(value) when is_binary(value) do
    case value |> String.downcase() |> String.replace("-", "") do
      "md5" -> :md5
      "sha" -> :sha
      "sha1" -> :sha
      "sha224" -> :sha224
      "sha256" -> :sha256
      "sha384" -> :sha384
      "sha512" -> :sha512
      _ -> nil
    end
  end

  defp normalize_auth_protocol(_value), do: nil

  defp normalize_priv_protocol(value)
       when value in [:des, :aes, :aes192, :aes256, :aes192c, :aes256c], do: value

  defp normalize_priv_protocol(value) when is_binary(value) do
    case value |> String.downcase() |> String.replace("-", "") do
      "des" -> :des
      "aes" -> :aes
      "aes128" -> :aes
      "aes192" -> :aes192
      "aes256" -> :aes256
      "aes192c" -> :aes192c
      "aes256c" -> :aes256c
      _ -> nil
    end
  end

  defp normalize_priv_protocol(_value), do: nil

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

  defp compact_map(map) do
    Map.reject(map, fn {_key, value} -> value in [nil, ""] end)
  end

  defp resolve_rule_or_profile(device_uid, actor, opts) do
    case resolve_rule_credential(opts, device_uid, actor) do
      {:ok, credential} ->
        {:ok,
         %{
           credential: credential,
           profile: resolve_profile(device_uid, actor),
           source: :credential_rule
         }}

      {:error, reason} ->
        {:error, reason}

      :none ->
        profile = resolve_profile(device_uid, actor)

        credential =
          build_credential(profile, actor,
            consumer_id: profile && "snmp_profile:#{profile.id}",
            target_kind: "device",
            target_id: device_uid
          )

        case credential do
          {:error, reason} ->
            {:error, reason}

          credential ->
            if credential_present?(credential) do
              {:ok, %{credential: credential, profile: profile, source: :profile}}
            else
              {:ok, %{credential: nil, profile: profile, source: :none}}
            end
        end
    end
  end

  defp resolve_rule_credential(opts, device_uid, actor) do
    scopes = snmp_rule_scopes(opts)

    if scopes == [] do
      :none
    else
      scopes
      |> Enum.reduce_while([], fn {scope_type, scope_value}, acc ->
        case NetworkCredentialRule.list_enabled_for_scope(
               "snmp",
               scope_type,
               scope_value,
               actor: actor
             ) do
          {:ok, rules} -> {:cont, acc ++ List.wrap(rules)}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:error, reason} ->
          {:error, reason}

        rules ->
          rules
          |> Enum.filter(&snmp_monitoring_rule?/1)
          |> Enum.find(&snmp_rule_matches?(&1, device_uid, actor))
          |> case do
            nil ->
              :none

            rule ->
              build_rule_credential(rule, actor)
          end
      end
    end
  end

  defp snmp_rule_scopes(opts) do
    Enum.reject(
      [
        {:agent, Keyword.get(opts, :agent_id)},
        {:partition, Keyword.get(opts, :partition)}
      ],
      fn {_type, value} -> is_nil(value) or value == "" end
    )
  end

  defp snmp_monitoring_rule?(rule) do
    case to_string(Map.get(rule, :purpose) || "") do
      "" -> true
      "snmp_monitoring" -> true
      _ -> false
    end
  end

  defp snmp_rule_matches?(_rule, nil, _actor), do: true

  defp snmp_rule_matches?(rule, device_uid, actor) when is_binary(device_uid) do
    query = rule.target_query |> to_string() |> String.trim()

    if query in ["", "in:devices"] do
      true
    else
      case SRQLAst.parse(query) do
        {:ok, ast} ->
          filters = SRQLDeviceMatcher.extract_filters(ast)

          Device
          |> Ash.Query.for_read(:read, %{}, actor: actor)
          |> Ash.Query.filter(uid == ^device_uid)
          |> SRQLDeviceMatcher.apply_filters(filters, log_prefix: "SNMPCredentialResolver")
          |> Ash.Query.limit(1)
          |> Ash.read_one(actor: actor)
          |> case do
            {:ok, %Device{}} -> true
            _ -> false
          end

        _ ->
          false
      end
    end
  end

  defp build_rule_credential(rule, actor) do
    secret_id = Map.get(rule, :secret_id)

    if is_nil(secret_id) or secret_id == "" do
      :none
    else
      record = %{
        version: rule_version(rule),
        credential_secret_id: secret_id,
        id: Map.get(rule, :id)
      }

      case build_credential(record, actor,
             consumer_id: "credential_rule:#{rule.id}",
             target_kind: "credential_rule",
             target_id: rule.id,
             purpose: "snmp_monitoring"
           ) do
        {:error, reason} -> {:error, reason}
        nil -> :none
        credential -> {:ok, credential}
      end
    end
  end

  defp rule_version(rule) do
    case to_string(Map.get(rule, :auth_method) || "") do
      "v3" -> :v3
      "community" -> :v2c
      _ -> :v2c
    end
  end

  defp finalize_credential(nil), do: nil

  defp finalize_credential(credential) when is_map(credential) do
    credential
    |> infer_version()
    |> copy_privacy_password()
    |> infer_security_level()
  end

  defp infer_version(%{version: :v3} = credential), do: credential

  defp infer_version(credential) do
    if present?(Map.get(credential, :username)) or present?(Map.get(credential, :auth_password)) or
         present?(Map.get(credential, :priv_password)) do
      Map.put(credential, :version, :v3)
    else
      Map.put(credential, :version, Map.get(credential, :version) || :v2c)
    end
  end

  defp copy_privacy_password(credential) do
    if present?(Map.get(credential, :priv_protocol)) and
         not present?(Map.get(credential, :priv_password)) and
         present?(Map.get(credential, :auth_password)) do
      Map.put(credential, :priv_password, Map.get(credential, :auth_password))
    else
      credential
    end
  end

  defp infer_security_level(credential) do
    case Map.get(credential, :security_level) do
      level when level in [:no_auth_no_priv, :auth_no_priv, :auth_priv] ->
        credential

      _ ->
        level =
          cond do
            present?(Map.get(credential, :priv_password)) -> :auth_priv
            present?(Map.get(credential, :auth_password)) -> :auth_no_priv
            true -> :no_auth_no_priv
          end

        Map.put(credential, :security_level, level)
    end
  end
end
