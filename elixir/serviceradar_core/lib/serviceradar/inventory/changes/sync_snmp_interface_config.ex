defmodule ServiceRadar.Inventory.Changes.SyncSnmpInterfaceConfig do
  @moduledoc """
  Sync SNMP target/OID configs from interface settings selections.
  """

  use Ash.Resource.Change

  require Logger
  require Ash.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.ConfigServer
  alias ServiceRadar.Changes.AfterAction
  alias ServiceRadar.Inventory.{Device, Interface, InterfaceSettings}
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.{SNMPOIDConfig, SNMPProfile, SNMPTarget}

  @impl true
  def change(changeset, _opts, _context) do
    AfterAction.after_action(changeset, &sync/1)
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: :ok

  defp sync(%InterfaceSettings{} = settings) do
    actor = SystemActor.system(:snmp_interface_config_sync)
    opts = [actor: actor]
    selected = normalize_selected(settings.metrics_selected, settings.metrics_enabled)

    result =
      if selected == [] do
        cleanup_target(settings, opts)
      else
        with {:ok, interface} <- load_interface(settings, opts),
             {:ok, profile} <- load_default_profile(opts),
             {:ok, target} <- get_or_create_target(settings, interface, profile, opts) do
          sync_target_oids(settings, interface, target, opts)
          prune_empty_target(target, opts)
        else
          {:error, reason} ->
            Logger.debug("SNMP interface config sync skipped: #{inspect(reason)}")
            {:error, reason}
        end
      end

    if match?({:error, _}, result) do
      :ok
    else
      ConfigServer.invalidate(:snmp)
      :ok
    end
  rescue
    error ->
      Logger.warning("SNMP interface config sync failed: #{inspect(error)}")
      :ok
  end

  defp load_interface(settings, opts) do
    query =
      Interface
      |> Ash.Query.for_read(:by_device_and_uid, %{
        device_id: settings.device_id,
        interface_uid: settings.interface_uid
      })
      |> Ash.Query.sort(timestamp: :desc)
      |> Ash.Query.limit(1)

    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:error, :interface_not_found}
      {:ok, interface} -> {:ok, interface}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_default_profile(opts) do
    query = Ash.Query.for_read(SNMPProfile, :get_default, %{})

    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:error, :no_default_profile}
      {:ok, profile} -> {:ok, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_or_create_target(settings, interface, profile, opts) do
    host = resolve_target_host(settings, interface, opts)

    if is_nil(host) or host == "" do
      {:error, :missing_target_host}
    else
      case find_target(profile.id, host, opts) do
        {:ok, target} ->
          update_target_credentials(settings, target, interface, opts)

        {:error, :not_found} ->
          create_target(settings, interface, profile, host, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp cleanup_target(settings, opts) do
    with {:ok, interface} <- load_interface(settings, opts),
         {:ok, profile} <- load_default_profile(opts),
         host when is_binary(host) and host != "" <-
           resolve_target_host(settings, interface, opts),
         {:ok, target} <- find_target(profile.id, host, opts) do
      sync_target_oids(settings, interface, target, opts)
      prune_empty_target(target, opts)
      :ok
    else
      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        Logger.debug("SNMP interface cleanup skipped: #{inspect(reason)}")
        {:error, reason}

      _ ->
        :ok
    end
  end

  defp resolve_target_host(settings, interface, opts) do
    interface.device_ip ||
      load_device_host(settings.device_id, opts)
  end

  defp load_device_host(device_id, opts) do
    case Device.get_by_uid(device_id, false, opts) do
      {:ok, device} -> device.ip || device.hostname || device.name
      {:error, _} -> nil
    end
  end

  defp find_target(profile_id, host, opts) do
    query =
      SNMPTarget
      |> Ash.Query.filter(snmp_profile_id == ^profile_id and host == ^host)
      |> Ash.Query.load(:snmp_profile)

    case Ash.read_one(query, opts) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_target(settings, interface, profile, host, opts) do
    case resolve_snmp_credential(settings, opts) do
      {:ok, nil} ->
        {:error, :missing_snmp_credentials}

      {:ok, credential} ->
        attrs =
          %{
            name: interface_target_name(settings, interface, host),
            host: host,
            port: 161,
            version: credential.version,
            snmp_profile_id: profile.id
          }
          |> Map.merge(credential_attrs(credential))

        SNMPTarget
        |> Ash.Changeset.for_create(:create, attrs, opts)
        |> Ash.create()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_target_credentials(settings, target, interface, opts) do
    target_name =
      if valid_target_name?(target.name) do
        nil
      else
        interface_target_name(settings, interface, target.host)
      end

    case resolve_snmp_credential(settings, opts) do
      {:ok, nil} ->
        if is_nil(target_name) do
          {:ok, target}
        else
          target
          |> Ash.Changeset.for_update(:update, %{name: target_name}, opts)
          |> Ash.update()
        end

      {:ok, credential} ->
        attrs =
          %{
            version: credential.version
          }
          |> Map.merge(credential_attrs(credential))
          |> maybe_put(:name, target_name)

        target
        |> Ash.Changeset.for_update(:update, attrs, opts)
        |> Ash.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_snmp_credential(settings, opts) do
    actor = Keyword.get(opts, :actor)

    case CredentialResolver.resolve_for_device(settings.device_id, actor) do
      {:ok, %{credential: nil}} ->
        Logger.debug("SNMP interface config sync: no credentials for #{settings.device_id}")
        {:ok, nil}

      {:ok, %{credential: credential}} ->
        {:ok, credential}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp credential_attrs(nil), do: %{}

  defp credential_attrs(credential) do
    %{}
    |> maybe_put(:community, Map.get(credential, :community))
    |> maybe_put(:username, Map.get(credential, :username))
    |> maybe_put(:security_level, security_level(credential))
    |> maybe_put(:auth_protocol, normalize_auth_protocol(Map.get(credential, :auth_protocol)))
    |> maybe_put(:auth_password, Map.get(credential, :auth_password))
    |> maybe_put(:priv_protocol, normalize_priv_protocol(Map.get(credential, :priv_protocol)))
    |> maybe_put(:priv_password, Map.get(credential, :priv_password))
  end

  defp security_level(credential) do
    case Map.get(credential, :security_level) do
      nil ->
        has_auth =
          present?(Map.get(credential, :auth_password)) or
            present?(Map.get(credential, :auth_protocol))

        has_priv =
          present?(Map.get(credential, :priv_password)) or
            present?(Map.get(credential, :priv_protocol))

        cond do
          has_auth and has_priv -> :auth_priv
          has_auth -> :auth_no_priv
          true -> :no_auth_no_priv
        end

      level ->
        level
    end
  end

  defp normalize_auth_protocol(nil), do: nil

  defp normalize_auth_protocol(protocol) when is_binary(protocol) do
    case String.downcase(protocol) do
      "md5" -> :md5
      "sha" -> :sha
      "sha224" -> :sha224
      "sha256" -> :sha256
      "sha384" -> :sha384
      "sha512" -> :sha512
      _ -> nil
    end
  end

  defp normalize_auth_protocol(protocol) when is_atom(protocol), do: protocol

  defp normalize_priv_protocol(nil), do: nil

  defp normalize_priv_protocol(protocol) when is_binary(protocol) do
    case String.downcase(protocol) do
      "des" -> :des
      "aes" -> :aes
      "aes192" -> :aes192
      "aes256" -> :aes256
      "aes192c" -> :aes192c
      "aes256c" -> :aes256c
      _ -> nil
    end
  end

  defp normalize_priv_protocol(protocol) when is_atom(protocol), do: protocol

  defp interface_target_name(settings, interface, host) do
    base =
      host ||
        interface.device_ip ||
        settings.device_id ||
        interface.interface_uid ||
        "snmp_target"

    sanitized =
      base
      |> String.trim()
      |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")

    name = "snmp_" <> sanitized

    if String.length(name) > 128 do
      hash =
        :crypto.hash(:sha256, base)
        |> Base.encode16(case: :lower)
        |> String.slice(0, 8)

      String.slice(name, 0, 119) <> "_" <> hash
    else
      name
    end
  end

  defp valid_target_name?(name) when is_binary(name) do
    name != "" and String.length(name) <= 128 and Regex.match?(~r/^[a-zA-Z0-9_-]+$/, name)
  end

  defp valid_target_name?(_), do: false

  defp sync_target_oids(settings, interface, target, opts) do
    selected = normalize_selected(settings.metrics_selected, settings.metrics_enabled)
    metrics = normalize_metrics(interface.available_metrics)

    desired =
      selected
      |> Enum.map(&build_oid_config(&1, metrics, interface))
      |> Enum.reject(&is_nil/1)

    existing = load_target_oids(target.id, opts)

    desired_names = MapSet.new(Enum.map(desired, & &1.name))

    Enum.each(existing, fn oid ->
      if oid_for_interface?(oid, settings.interface_uid) and
           not MapSet.member?(desired_names, oid.name) do
        _ = Ash.destroy(oid, opts)
      end
    end)

    Enum.each(desired, fn attrs ->
      upsert_oid(target.id, attrs, opts)
    end)
  end

  defp normalize_selected(metrics, true) when is_list(metrics) do
    metrics
    |> Enum.map(&normalize_metric_name/1)
    |> expand_packet_metrics()
    |> Enum.uniq()
  end

  defp normalize_selected(_metrics, _enabled), do: []

  # Always include packet counters alongside byte counters so link PPS can be derived
  # without requiring manual per-interface metric selection in the UI.
  defp expand_packet_metrics(selected) when is_list(selected) do
    selected
    |> maybe_add_metric("ifInOctets", "ifInUcastPkts")
    |> maybe_add_metric("ifOutOctets", "ifOutUcastPkts")
    |> maybe_add_metric("ifHCInOctets", "ifHCInUcastPkts")
    |> maybe_add_metric("ifHCOutOctets", "ifHCOutUcastPkts")
  end

  defp maybe_add_metric(selected, source, target) do
    if source in selected and target not in selected do
      [target | selected]
    else
      selected
    end
  end

  defp normalize_metrics(metrics) when is_list(metrics) do
    metrics
    |> Enum.filter(&is_map/1)
    |> Map.new(fn metric ->
      {normalize_metric_name(Map.get(metric, "name") || Map.get(metric, :name)), metric}
    end)
  end

  defp normalize_metrics(_), do: %{}

  defp normalize_metric_name(metric) when is_atom(metric), do: Atom.to_string(metric)
  defp normalize_metric_name(metric) when is_binary(metric), do: metric
  defp normalize_metric_name(metric), do: to_string(metric)

  defp build_oid_config(metric_name, metrics, interface) do
    with metric when is_map(metric) <- Map.get(metrics, metric_name),
         if_index when is_integer(if_index) <- interface.if_index,
         oid when is_binary(oid) and oid != "" <- resolve_metric_oid(metric) do
      %{
        oid: "#{oid}.#{if_index}",
        name: metric_oid_name(metric_name, interface.interface_uid),
        data_type:
          normalize_data_type(Map.get(metric, "data_type") || Map.get(metric, :data_type)),
        scale: 1.0,
        delta: metric_delta?(metric)
      }
    else
      _ -> nil
    end
  end

  defp resolve_metric_oid(metric) do
    oid_base = Map.get(metric, "oid_64bit") || Map.get(metric, :oid_64bit)

    if Map.get(metric, "supports_64bit") || Map.get(metric, :supports_64bit) do
      oid_base || Map.get(metric, "oid") || Map.get(metric, :oid)
    else
      Map.get(metric, "oid") || Map.get(metric, :oid)
    end
  end

  defp metric_oid_name(metric_name, interface_uid) do
    "#{metric_name}::#{interface_uid}"
  end

  defp metric_delta?(metric) do
    data_type = Map.get(metric, "data_type") || Map.get(metric, :data_type)
    normalize_data_type(data_type) == :counter
  end

  defp normalize_data_type(nil), do: :gauge

  defp normalize_data_type(type) when is_binary(type) do
    case String.downcase(type) do
      "counter" -> :counter
      "gauge" -> :gauge
      "boolean" -> :boolean
      "bytes" -> :bytes
      "string" -> :string
      "float" -> :float
      "timeticks" -> :timeticks
      _ -> :gauge
    end
  end

  defp normalize_data_type(type) when is_atom(type), do: type
  defp normalize_data_type(_), do: :gauge

  defp load_target_oids(target_id, opts) do
    SNMPOIDConfig
    |> Ash.Query.filter(snmp_target_id == ^target_id)
    |> Ash.read(opts)
    |> case do
      {:ok, oids} -> oids
      {:error, _} -> []
    end
  end

  defp prune_empty_target(target, opts) do
    if target_has_oids?(target.id, opts) do
      :ok
    else
      _ = Ash.destroy(target, opts)
      :ok
    end
  end

  defp target_has_oids?(target_id, opts) do
    query =
      SNMPOIDConfig
      |> Ash.Query.filter(snmp_target_id == ^target_id)
      |> Ash.Query.limit(1)

    case Ash.read(query, opts) do
      {:ok, []} -> false
      {:ok, _} -> true
      {:error, _} -> true
    end
  end

  defp upsert_oid(target_id, attrs, opts) do
    query =
      SNMPOIDConfig
      |> Ash.Query.filter(snmp_target_id == ^target_id and oid == ^attrs.oid)

    case Ash.read_one(query, opts) do
      {:ok, nil} ->
        create_attrs = Map.put(attrs, :snmp_target_id, target_id)

        SNMPOIDConfig
        |> Ash.Changeset.for_create(:create, create_attrs, opts)
        |> Ash.create()

      {:ok, oid} ->
        oid
        |> Ash.Changeset.for_update(:update, attrs, opts)
        |> Ash.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp oid_for_interface?(oid, interface_uid) do
    String.ends_with?(oid.name || "", "::#{interface_uid}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_), do: true
end
