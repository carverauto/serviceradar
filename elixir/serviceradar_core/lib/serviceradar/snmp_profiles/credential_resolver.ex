defmodule ServiceRadar.SNMPProfiles.CredentialResolver do
  @moduledoc """
  Resolves SNMP credentials for devices using per-device overrides,
  credential rules, and profiles.

  Resolution order:
  1. Device-specific override
  2. Matching SNMP credential rule (provider snmp, purpose snmp_monitoring)
  3. Profile credentials (SRQL targeting + default fallback)
  4. None

  `resolve_for_devices/3` is the one implementation of that order;
  `resolve_for_device/3` is the same resolution for a single device.
  """

  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
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
    [device_uid]
    |> resolve_for_devices(actor, opts)
    |> Map.fetch!(device_uid)
  end

  @doc """
  Resolve credentials for many device UIDs with a fixed number of reads.

  Every device gets the result `resolve_for_device/3` gives it, with the same
  precedence. The reads are per kind, not per device: one for the device
  overrides, one per rule scope, one per credential rule and one per targeting
  profile to find which devices each selects, one per distinct profile and
  credential secret used, and one insert for the resolution audit rows of the
  whole call. Callers page their devices and call this once per page.

  A failed read is reported on every device whose result depended on it, so a
  caller that fails on the first read failure behaves as it did device by
  device.

  `opts` takes `:agent_id` and `:partition` (the credential rule scopes),
  `:fallback_profile`: a profile whose own credential is used for a device
  that resolves no credential, reported with source `:fallback_profile`, and
  `:bulk_audit`: the handle `with_bulk_audit/2` yields. Without that handle
  every brokered resolution writes its own audit row, as a single resolution
  does.
  """
  @spec resolve_for_devices([String.t()], map(), keyword()) ::
          %{
            String.t() =>
              {:ok,
               %{
                 credential: credential_map() | nil,
                 profile: SNMPProfile.t() | nil,
                 source: atom()
               }}
              | {:error, term()}
          }
  def resolve_for_devices(device_uids, actor, opts \\ []) when is_list(device_uids) do
    device_uids = Enum.uniq(device_uids)

    case Keyword.get(opts, :bulk_audit) do
      nil ->
        with_collected_audits(fn audit_sink ->
          resolve_devices(device_uids, actor, opts, fn attrs, _device_uid ->
            audit_sink.(attrs)
          end)
        end)

      bulk_audit ->
        resolve_devices(device_uids, actor, opts, &collect_bulk_audit(bulk_audit, &1, &2))
    end
  end

  @doc """
  Runs `fun` as one bulk resolution pass and audits it as one.

  `fun` receives a handle to pass as `opts[:bulk_audit]` to every
  `resolve_for_devices/3` call of the pass, typically one compile of one
  config. Brokered resolutions made with it are not audited one row per device.
  When `fun` returns or raises, one audit row is written for each distinct
  secret, consumer and outcome the pass resolved, with the usual columns and
  this `metadata`:

  - `resolution_count`: how many device resolutions the row stands for
  - `first_device_uid` and `last_device_uid`: the first and last device, in
    resolution order
  - `device_set_sha256`: SHA-256 over those device UIDs in resolution order,
    each followed by a newline, to check a claimed device set against
  - `run_id`: one value shared by every row of the pass
  - `partition`: the pass's partition, when it has one

  A row whose resolutions each targeted a device has `target_kind`
  `device_set` and the digest as `target_id`. `context` gives `:agent_id` and
  `:partition`; the agent is recorded in the row's `agent_id`.
  """
  @spec with_bulk_audit(keyword(), (term() -> result)) :: result when result: term()
  def with_bulk_audit(context, fun) when is_list(context) and is_function(fun, 1) do
    bulk_audit = {__MODULE__, :bulk_audit, make_ref()}
    Process.put(bulk_audit, %{})

    try do
      fun.(bulk_audit)
    after
      bulk_audit
      |> Process.delete()
      |> bulk_audit_rows(context)
      |> SecretBroker.write_audits()
    end
  end

  @bulk_audit_group_fields [
    :secret_id,
    :secret_provider_id,
    :grant_id,
    :consumer_kind,
    :consumer_id,
    :purpose,
    :target_kind,
    :agent_id,
    :resolution_location,
    :outcome,
    :error_class,
    :cache_status
  ]

  # Resolutions that differ only in the device they were made for share a row.
  defp collect_bulk_audit(bulk_audit, attrs, device_uid) do
    group = {Map.take(attrs, @bulk_audit_group_fields), shared_target_id(attrs)}
    groups = Process.get(bulk_audit, %{})

    entry =
      case Map.get(groups, group) do
        nil ->
          %{
            attrs: attrs,
            count: 1,
            first: device_uid,
            last: device_uid,
            digest: digest_device(:crypto.hash_init(:sha256), device_uid)
          }

        entry ->
          %{
            entry
            | count: entry.count + 1,
              last: device_uid,
              digest: digest_device(entry.digest, device_uid)
          }
      end

    Process.put(bulk_audit, Map.put(groups, group, entry))
  end

  defp shared_target_id(%{target_kind: "device"}), do: nil
  defp shared_target_id(attrs), do: Map.get(attrs, :target_id)

  defp digest_device(digest, device_uid), do: :crypto.hash_update(digest, [device_uid, "\n"])

  defp bulk_audit_rows(groups, context) when is_map(groups) do
    run_id = Ecto.UUID.generate()

    Enum.map(groups, fn {_group, entry} ->
      digest = entry.digest |> :crypto.hash_final() |> Base.encode16(case: :lower)

      metadata =
        Map.reject(
          %{
            "resolution_count" => entry.count,
            "first_device_uid" => entry.first,
            "last_device_uid" => entry.last,
            "device_set_sha256" => digest,
            "run_id" => run_id,
            "partition" => Keyword.get(context, :partition)
          },
          fn {_key, value} -> is_nil(value) end
        )

      entry.attrs
      |> Map.put(:metadata, Map.merge(Map.get(entry.attrs, :metadata) || %{}, metadata))
      |> Map.put(:agent_id, Map.get(entry.attrs, :agent_id) || Keyword.get(context, :agent_id))
      |> put_device_set_target(digest)
    end)
  end

  defp bulk_audit_rows(_groups, _context), do: []

  defp put_device_set_target(%{target_kind: "device"} = attrs, digest),
    do: %{attrs | target_kind: "device_set", target_id: digest}

  defp put_device_set_target(attrs, _digest), do: attrs

  # Resolution audit rows are collected while the devices resolve and written
  # together, including when resolution raises part-way.
  defp with_collected_audits(fun) do
    key = {__MODULE__, :resolution_audits, make_ref()}
    Process.put(key, [])

    try do
      fun.(fn attrs -> Process.put(key, [attrs | Process.get(key, [])]) end)
    after
      key
      |> Process.delete()
      |> List.wrap()
      |> Enum.reverse()
      |> SecretBroker.write_audits()
    end
  end

  defp resolve_devices(device_uids, actor, opts, audit_collector) do
    case load_device_overrides(device_uids, actor) do
      {:ok, overrides} ->
        {overridden, others} = Enum.split_with(device_uids, &is_map_key(overrides, &1))
        secrets = load_secrets(%{}, Map.values(overrides), actor)
        build_opts = [loaded_secrets: secrets, audit_collector: audit_collector]

        overridden
        |> Map.new(&{&1, override_result(Map.fetch!(overrides, &1), &1, actor, build_opts)})
        |> Map.merge(resolve_rules_and_profiles(others, actor, opts, build_opts))
        |> apply_fallback_profile(Keyword.get(opts, :fallback_profile), actor, build_opts)

      {:error, reason} ->
        put_all(%{}, device_uids, {:error, reason})
    end
  end

  defp override_result(override, device_uid, actor, build_opts) do
    credential =
      build_credential(
        override,
        actor,
        [
          consumer_id: "device_snmp_credential:#{override.id}",
          target_kind: "device",
          target_id: device_uid
        ] ++ for_device(build_opts, device_uid)
      )

    case credential do
      {:error, reason} -> {:error, reason}
      credential -> {:ok, %{credential: credential, profile: nil, source: :device_override}}
    end
  end

  defp resolve_rules_and_profiles([], _actor, _opts, _build_opts), do: %{}

  defp resolve_rules_and_profiles(device_uids, actor, opts, build_opts) do
    rule_matches = match_snmp_rules(device_uids, actor, opts)
    matched_rules = for {:ok, rule} <- Map.values(rule_matches), uniq: true, do: rule
    build_opts = put_loaded_secrets(build_opts, Enum.map(matched_rules, &rule_record/1), actor)

    rule_credentials =
      Map.new(device_uids, fn device_uid ->
        case Map.fetch!(rule_matches, device_uid) do
          {:ok, rule} ->
            {device_uid, build_rule_credential(rule, actor, for_device(build_opts, device_uid))}

          other ->
            {device_uid, other}
        end
      end)

    # A device whose rule credential failed never reaches profile resolution.
    pending = Enum.reject(device_uids, &match?({:error, _}, Map.fetch!(rule_credentials, &1)))
    profiles = resolve_profiles(pending, actor)

    build_opts =
      put_loaded_secrets(build_opts, profiles |> Map.values() |> Enum.filter(&is_struct/1), actor)

    Map.new(device_uids, fn device_uid ->
      result =
        case Map.fetch!(rule_credentials, device_uid) do
          {:error, reason} ->
            {:error, reason}

          rule_credential ->
            rule_or_profile_result(
              rule_credential,
              Map.fetch!(profiles, device_uid),
              device_uid,
              actor,
              build_opts
            )
        end

      {device_uid, result}
    end)
  end

  defp rule_or_profile_result(_rule_credential, {:error, reason}, _uid, _actor, _build_opts),
    do: {:error, reason}

  defp rule_or_profile_result({:ok, credential}, profile, _uid, _actor, _build_opts),
    do: {:ok, %{credential: credential, profile: profile, source: :credential_rule}}

  defp rule_or_profile_result(:none, profile, device_uid, actor, build_opts) do
    credential =
      build_credential(
        profile,
        actor,
        [
          consumer_id: profile && "snmp_profile:#{profile.id}",
          target_kind: "device",
          target_id: device_uid
        ] ++ for_device(build_opts, device_uid)
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

  defp apply_fallback_profile(results, nil, _actor, _build_opts), do: results

  defp apply_fallback_profile(results, fallback, actor, build_opts) do
    build_opts =
      [
        consumer_id: "snmp_profile:#{fallback.id}",
        target_kind: "snmp_profile",
        target_id: fallback.id
      ] ++ put_loaded_secrets(build_opts, [fallback], actor)

    Map.new(results, fn
      {device_uid, {:ok, %{credential: credential} = resolution}} when not is_map(credential) ->
        case build_credential(fallback, actor, for_device(build_opts, device_uid)) do
          {:error, reason} ->
            {device_uid, {:error, reason}}

          credential when is_map(credential) ->
            {device_uid, {:ok, %{resolution | credential: credential, source: :fallback_profile}}}

          _no_credential ->
            {device_uid, {:ok, resolution}}
        end

      resolved ->
        resolved
    end)
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
    case resolve_unscoped_rule_credential(opts, actor) do
      {:ok, credential} ->
        case get_default_profile(actor) do
          {:error, reason} ->
            {:error, reason}

          profile ->
            {:ok,
             %{
               credential: credential,
               profile: profile,
               source: :credential_rule
             }}
        end

      {:error, reason} ->
        {:error, reason}

      :none ->
        case get_default_profile(actor) do
          {:error, reason} ->
            {:error, reason}

          profile ->
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

      {:error, reason} ->
        if credential_read_failure?(reason) do
          {:error, reason}
        else
          resolve_unbound_host(actor, opts)
        end
    end
  end

  defp resolve_unbound_host(actor, opts) do
    case resolve_unscoped_rule_credential(opts, actor) do
      {:ok, credential} ->
        {:ok, %{credential: credential, profile: nil, source: :credential_rule}}

      {:error, reason} ->
        {:error, reason}

      :none ->
        {:ok, %{credential: nil, profile: nil, source: :none}}
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
        with {:ok, targeting} <- profile_result(targeting_profile(device_uid, actor)),
             {:ok, default} <- profile_result(get_default_profile(actor)) do
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
  end

  defp profile_result({:error, reason}), do: {:error, reason}
  defp profile_result(profile), do: {:ok, profile}

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
      {:ok, nil} -> nil
      {:error, reason} -> {:error, reason}
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

  Returns `{:error, {:unknown_security_level, value}}` when the credential
  carries a present-but-unrecognised level instead of downgrading it: a
  mapper polling with noAuthNoPriv on the operator's behalf must be a
  decision, never a fallback. An absent level is omitted.
  """
  @spec to_mapper_credentials(credential_map() | nil) ::
          {:ok, map()} | {:error, {:unknown_security_level, term()}}
  def to_mapper_credentials(nil), do: {:ok, %{}}

  def to_mapper_credentials(%{} = credential) do
    raw_level = Map.get(credential, :security_level)

    with {:ok, level} <- mapper_security_level(raw_level) do
      {:ok,
       compact_map(%{
         "version" =>
           ProtocolFormatter.version(Map.get(credential, :version), allow_binary?: true),
         "community" => Map.get(credential, :community),
         "username" => Map.get(credential, :username),
         "security_level" => level,
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
       })}
    end
  end

  # An absent level is omitted (v2c credentials carry none); a present but
  # unrecognised level refuses rather than downgrading to noAuthNoPriv. The
  # wire spelling comes from ProtocolFormatter.security_level/1, which is
  # total over the normalised atoms that reach it.
  defp mapper_security_level(raw) do
    cond do
      not present?(raw) ->
        {:ok, nil}

      (level = ProtocolFormatter.normalize_security_level(raw)) != nil ->
        {:ok, ProtocolFormatter.security_level(level)}

      true ->
        {:error, {:unknown_security_level, raw}}
    end
  end

  @doc false
  @spec credential_read_failure?(term()) :: boolean()
  def credential_read_failure?({:credential_resolution_failed, inner}),
    do: credential_read_failure?(inner)

  def credential_read_failure?(%Ash.Error.Invalid{}), do: false

  def credential_read_failure?(reason), do: Ash.Error.ash_error?(reason)

  @doc """
  Builds a concrete SNMP credential from either a broker-backed secret reference
  or the legacy encrypted SNMP fields on the record.

  Broker payloads can be either a raw community string for SNMPv1/v2c, or a JSON
  object with SNMP keys such as `version`, `community`, `username`,
  `security_level`, `auth_protocol`, `auth_password`, `priv_protocol`, and
  `priv_password`.

  `opts[:loaded_secrets]` maps a secret ID to `{:ok, secret}` or
  `{:error, reason}` for secrets the caller already read, and
  `opts[:audit_sink]` defers the resolution audit row; `resolve_for_devices/3`
  uses both to resolve one secret for many devices without a read or an insert
  per device.
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

  # The profile each device's credentials come from: the profile targeting it,
  # else the default. A profile is read once however many devices share it.
  defp resolve_profiles([], _actor), do: %{}

  defp resolve_profiles(device_uids, actor) do
    targeting = SrqlTargetResolver.resolve_for_devices(device_uids, nil, actor)

    {resolved, _loaded} =
      Enum.map_reduce(device_uids, %{}, fn device_uid, loaded ->
        case Map.fetch!(targeting, device_uid) do
          {:ok, %SNMPProfile{id: id}} ->
            loaded = Map.put_new_lazy(loaded, id, fn -> load_profile(id, actor) end)
            {{device_uid, Map.fetch!(loaded, id)}, loaded}

          {:ok, nil} ->
            loaded = Map.put_new_lazy(loaded, :default, fn -> get_default_profile(actor) end)
            {{device_uid, Map.fetch!(loaded, :default)}, loaded}

          {:error, reason} ->
            Logger.error("SNMPCredentialResolver: SRQL targeting failed - #{inspect(reason)}")
            {{device_uid, {:error, reason}}, loaded}
        end
      end)

    Map.new(resolved)
  end

  defp get_default_profile(actor) do
    query = Ash.Query.for_read(SNMPProfile, :get_default, %{})

    case Ash.read_one(query, actor: actor) do
      {:ok, %SNMPProfile{} = profile} -> load_profile(profile.id, actor)
      {:ok, nil} -> nil
      {:error, reason} -> {:error, reason}
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
      {:ok, nil} -> nil
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_device_overrides(device_uids, actor) do
    DeviceSNMPCredential
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(device_id in ^device_uids)
    |> Ash.read(actor: actor)
    |> case do
      {:ok, overrides} -> {:ok, Map.new(overrides, &{&1.device_id, &1})}
      {:error, reason} -> {:error, reason}
    end
  end

  # Reads the secrets `records` reference that are not loaded yet, in one
  # query. A secret that query does not return is read on its own once, so its
  # failure is the one a single resolution reports.
  defp load_secrets(loaded, records, actor) do
    secret_ids =
      records
      |> Enum.map(&credential_secret_id/1)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()
      |> Enum.reject(&is_map_key(loaded, &1))

    case secret_ids do
      [] ->
        loaded

      secret_ids ->
        case NetworkCredentialSecret.list_secrets_by_ids(secret_ids, actor: actor) do
          {:ok, secrets} ->
            found = Map.new(secrets, &{to_string(&1.id), {:ok, &1}})

            Enum.reduce(secret_ids, loaded, fn secret_id, loaded ->
              Map.put(
                loaded,
                secret_id,
                Map.get_lazy(found, secret_id, fn ->
                  NetworkCredentialSecret.get_secret_by_id(secret_id, actor: actor)
                end)
              )
            end)

          {:error, reason} ->
            put_all(loaded, secret_ids, {:error, reason})
        end
    end
  end

  # The broker's audit sink for one device: its row reaches the collector with
  # the device it was resolved for.
  defp for_device(build_opts, device_uid) do
    {collector, build_opts} = Keyword.pop!(build_opts, :audit_collector)
    Keyword.put(build_opts, :audit_sink, &collector.(&1, device_uid))
  end

  defp put_loaded_secrets(build_opts, records, actor) do
    Keyword.update!(build_opts, :loaded_secrets, &load_secrets(&1, records, actor))
  end

  defp put_all(results, keys, value), do: Enum.reduce(keys, results, &Map.put(&2, &1, value))

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
      |> Ash.Query.sort(DeviceAliasState.holder_sort())
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
          resolution_location: Keyword.get(opts, :resolution_location, :control_plane),
          audit_sink: Keyword.get(opts, :audit_sink)
        ],
        fn {_key, value} -> is_nil(value) end
      )

    resolution =
      case opts |> Keyword.get(:loaded_secrets, %{}) |> Map.get(secret_id) do
        {:ok, secret} -> SecretBroker.resolve_loaded_secret(secret, broker_opts)
        {:error, reason} -> {:error, reason}
        nil -> SecretBroker.resolve_network_credential_secret(secret_id, broker_opts)
      end

    case resolution do
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

    with {:ok, level} <- broker_security_level(payload, record) do
      {:ok,
       %{
         version: version,
         community: map_value(payload, "community"),
         username:
           map_value(payload, "username") || Map.get(record, :username) ||
             Map.get(secret, :username),
         security_level: level,
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
         priv_password:
           map_value(payload, "priv_password") || map_value(payload, "privacy_password")
       }}
    end
  end

  defp broker_security_level(payload, record) do
    # A bound secret can omit its level and infer it from its passwords. The
    # consumer's no-auth default must not suppress that inference; an explicit
    # level in the secret still wins, including an intentional noAuthNoPriv.
    # An explicit level that is not a known spelling refuses: inferring from
    # passwords would silently discard what the operator wrote.
    raw = map_value(payload, "security_level")

    cond do
      not present?(raw) ->
        {:ok,
         case normalize_security_level(Map.get(record, :security_level)) do
           :no_auth_no_priv -> nil
           level -> level
         end}

      (level = normalize_security_level(raw)) != nil ->
        {:ok, level}

      true ->
        {:error, {:unknown_security_level, raw}}
    end
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

  # One vocabulary for every reader: the same normalisers the forms' option
  # lists and the agent-config compiler use, so a spelling accepted here is
  # accepted there.
  defp normalize_security_level(value), do: ProtocolFormatter.normalize_security_level(value)
  defp normalize_auth_protocol(value), do: ProtocolFormatter.normalize_auth_protocol(value)
  defp normalize_priv_protocol(value), do: ProtocolFormatter.normalize_priv_protocol(value)

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

  # The first enabled SNMP monitoring rule in scope, for a caller with no device.
  defp resolve_unscoped_rule_credential(opts, actor) do
    case load_snmp_rules(opts, actor) do
      {:ok, [rule | _]} -> build_rule_credential(rule, actor, [])
      {:ok, []} -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_snmp_rules(opts, actor) do
    opts
    |> snmp_rule_scopes()
    |> Enum.reduce_while({:ok, []}, fn {scope_type, scope_value}, {:ok, rules} ->
      case NetworkCredentialRule.list_enabled_for_scope("snmp", scope_type, scope_value,
             actor: actor
           ) do
        {:ok, scoped} -> {:cont, {:ok, rules ++ List.wrap(scoped)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.filter(rules, &snmp_monitoring_rule?/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Gives each device its first matching rule, in rule order, as
  # `{:ok, rule}`, `:none`, or the read failure that stopped its matching.
  defp match_snmp_rules(device_uids, actor, opts) do
    case load_snmp_rules(opts, actor) do
      {:ok, rules} -> assign_snmp_rules(rules, device_uids, actor, %{})
      {:error, reason} -> put_all(%{}, device_uids, {:error, reason})
    end
  end

  defp assign_snmp_rules(_rules, [], _actor, matches), do: matches

  defp assign_snmp_rules([], unmatched, _actor, matches), do: put_all(matches, unmatched, :none)

  defp assign_snmp_rules([rule | rest], unmatched, actor, matches) do
    case snmp_rule_matches(rule, unmatched, actor) do
      {:ok, matched} ->
        {hits, misses} = Enum.split_with(unmatched, &MapSet.member?(matched, &1))
        assign_snmp_rules(rest, misses, actor, put_all(matches, hits, {:ok, rule}))

      {:error, reason} ->
        put_all(matches, unmatched, {:error, reason})
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

  defp snmp_rule_matches(rule, device_uids, actor) do
    query = rule.target_query |> to_string() |> String.trim()

    if query in ["", "in:devices"] do
      {:ok, MapSet.new(device_uids)}
    else
      case SRQLAst.parse(query) do
        {:ok, ast} ->
          ast
          |> SRQLDeviceMatcher.extract_filters()
          |> SRQLDeviceMatcher.matching_uids(device_uids, actor,
            log_prefix: "SNMPCredentialResolver"
          )
          |> case do
            {:ok, matched} ->
              {:ok, matched}

            {:error, reason} ->
              if credential_read_failure?(reason),
                do: {:error, reason},
                else: {:ok, MapSet.new()}
          end

        _ ->
          {:ok, MapSet.new()}
      end
    end
  end

  defp rule_record(rule) do
    %{
      version: rule_version(rule),
      credential_secret_id: Map.get(rule, :secret_id),
      id: Map.get(rule, :id)
    }
  end

  defp build_rule_credential(rule, actor, build_opts) do
    record = rule_record(rule)

    if record.credential_secret_id in [nil, ""] do
      :none
    else
      case build_credential(
             record,
             actor,
             [
               consumer_id: "credential_rule:#{rule.id}",
               target_kind: "credential_rule",
               target_id: rule.id,
               purpose: "snmp_monitoring"
             ] ++ build_opts
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

  defp finalize_credential({:error, _reason} = error), do: error

  defp finalize_credential({:ok, credential}) when is_map(credential) do
    finalize_credential(credential)
  end

  # Success keeps the historical bare-map shape; only refusals are tagged.
  defp finalize_credential(credential) when is_map(credential) do
    credential
    |> infer_version()
    |> copy_privacy_password()
    |> infer_security_level()
    |> case do
      {:ok, finalized} -> finalized
      {:error, _reason} = error -> error
    end
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

  # A level that is present but unrecognised refuses instead of inferring:
  # inferring from passwords would silently discard what the operator wrote
  # and could downgrade an authenticated poll to noAuthNoPriv. Absent levels
  # (nil or blank) keep the historical password inference.
  defp infer_security_level(credential) do
    raw = Map.get(credential, :security_level)

    case ProtocolFormatter.normalize_security_level(raw) do
      level when level in [:no_auth_no_priv, :auth_no_priv, :auth_priv] ->
        {:ok, Map.put(credential, :security_level, level)}

      nil ->
        if present?(raw) do
          {:error, {:unknown_security_level, raw}}
        else
          {:ok, Map.put(credential, :security_level, inferred_security_level(credential))}
        end
    end
  end

  defp inferred_security_level(credential) do
    cond do
      present?(Map.get(credential, :priv_password)) -> :auth_priv
      present?(Map.get(credential, :auth_password)) -> :auth_no_priv
      true -> :no_auth_no_priv
    end
  end
end
