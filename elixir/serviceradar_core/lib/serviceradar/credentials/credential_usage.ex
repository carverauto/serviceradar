defmodule ServiceRadar.Credentials.CredentialUsage do
  @moduledoc """
  Resolves the complete, redacted live-consumer inventory for reusable credentials.

  Calls fail closed. The caller must first be authorized to read every requested
  credential. Cross-domain reads then run under a narrowly identified system
  actor, and a failure or incomplete result from any source makes the entire
  lookup unavailable rather than returning a misleading partial count.
  """

  alias Ash.Resource.Info
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller, as: AnsibleController
  alias ServiceRadar.Automation.Ansible.PlaybookRepository, as: AnsiblePlaybookRepository
  alias ServiceRadar.Credentials.CredentialBrokerGrant
  alias ServiceRadar.Credentials.CredentialUsage.Consumer
  alias ServiceRadar.Credentials.CredentialUsage.LiveGrant
  alias ServiceRadar.Credentials.CredentialUsage.Result
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Credentials.NetworkCredentialSecretBinding
  alias ServiceRadar.Integrations.IntegrationSource
  alias ServiceRadar.Integrations.OutboundMailSettings
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.Inventory.VulnerabilityFeedDefinition
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.Notifications.NotificationChannel
  alias ServiceRadar.Plugins.PluginAssignment
  alias ServiceRadar.Plugins.PluginRepository
  alias ServiceRadar.Plugins.PluginTargetPolicy
  alias ServiceRadar.Plugins.ProducerSchedule
  alias ServiceRadar.SNMPProfiles.SNMPProfile
  alias ServiceRadar.SNMPProfiles.SNMPTarget

  require Ash.Query

  @unavailable :credential_usage_unavailable
  @system_actor SystemActor.system(:credential_usage)

  @type secret_id :: Ecto.UUID.t()
  @type unavailable_reason :: {:credential_usage_unavailable, atom()}

  @spec for_secret(secret_id(), keyword()) :: {:ok, Result.t()} | {:error, unavailable_reason()}
  def for_secret(secret_id, opts \\ []) when is_list(opts) do
    case normalize_id(secret_id) do
      {:ok, normalized_id} ->
        with {:ok, results} <- for_secrets([normalized_id], opts) do
          {:ok, Map.fetch!(results, normalized_id)}
        end

      :error ->
        unavailable(:authorization)
    end
  end

  @spec for_secrets([secret_id()], keyword()) ::
          {:ok, %{secret_id() => Result.t()}} | {:error, unavailable_reason()}
  def for_secrets(secret_ids, opts \\ [])

  def for_secrets(secret_ids, opts) when is_list(secret_ids) and is_list(opts) do
    with {:ok, ids} <- normalize_ids(secret_ids),
         :ok <- authorize_all(ids, opts) do
      resolve_all(ids, opts)
    end
  end

  def for_secrets(_secret_ids, _opts), do: unavailable(:authorization)

  defp resolve_all([], _opts), do: {:ok, %{}}

  defp resolve_all(ids, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, direct} <- load_direct_consumers(ids),
         {:ok, bound} <- load_bound_consumers(ids),
         {:ok, grants} <- load_live_grants(ids, now) do
      consumers_by_secret = group_consumers(ids, direct ++ bound)
      grants_by_secret = group_grants(ids, grants)

      {:ok,
       Map.new(ids, fn id ->
         {id,
          %Result{
            consumers: Map.fetch!(consumers_by_secret, id),
            live_grants: Map.fetch!(grants_by_secret, id)
          }}
       end)}
    end
  end

  defp authorize_all([], _opts), do: :ok

  defp authorize_all(ids, opts) do
    caller_opts = Keyword.take(opts, [:scope, :actor])

    result =
      NetworkCredentialSecret
      |> Ash.Query.for_read(:read, %{}, caller_opts)
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id])
      |> Ash.read(caller_opts)

    case result do
      {:ok, secrets} ->
        returned_ids = MapSet.new(secrets, &to_string(&1.id))

        if returned_ids == MapSet.new(ids) do
          :ok
        else
          unavailable(:authorization)
        end

      {:error, _error} ->
        unavailable(:authorization)
    end
  rescue
    _error -> unavailable(:authorization)
  catch
    _kind, _reason -> unavailable(:authorization)
  end

  defp load_direct_consumers(ids) do
    loaders = [
      {:credential_rules, &load_credential_rules/1},
      {:snmp_profiles, &load_snmp_profiles/1},
      {:snmp_targets, &load_snmp_targets/1},
      {:device_snmp_credentials, &load_device_snmp_credentials/1},
      {:mapper_unifi_controllers, &load_mapper_unifi_controllers/1},
      {:mapper_mikrotik_controllers, &load_mapper_mikrotik_controllers/1},
      {:integration_sources, &load_integration_sources/1},
      {:outbound_mail_settings, &load_outbound_mail_settings/1},
      {:plugin_repositories, &load_plugin_repositories/1},
      {:ansible_controllers, &load_ansible_controllers/1},
      {:ansible_playbook_repositories, &load_ansible_playbook_repositories/1}
    ]

    run_loaders(loaders, ids)
  end

  defp run_loaders(loaders, ids) do
    loaders
    |> Enum.reduce_while({:ok, []}, fn {source, loader}, {:ok, acc} ->
      case safely_load(loader, ids) do
        {:ok, values} -> {:cont, {:ok, [values | acc]}}
        :error -> {:halt, unavailable(source)}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp safely_load(loader, ids) do
    case loader.(ids) do
      {:ok, values} when is_list(values) -> {:ok, values}
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp load_credential_rules(ids) do
    NetworkCredentialRule
    |> read_selected(
      Ash.Query.filter(NetworkCredentialRule, secret_id in ^ids),
      [:id, :secret_id, :name]
    )
    |> map_direct(:credential_rule, :secret_id, :name)
  end

  defp load_snmp_profiles(ids) do
    SNMPProfile
    |> read_selected(
      Ash.Query.filter(SNMPProfile, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name]
    )
    |> map_direct(:snmp_profile, :credential_secret_id, :name)
  end

  defp load_snmp_targets(ids) do
    SNMPTarget
    |> read_selected(
      Ash.Query.filter(SNMPTarget, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name]
    )
    |> map_direct(:snmp_target, :credential_secret_id, :name)
  end

  defp load_device_snmp_credentials(ids) do
    DeviceSNMPCredential
    |> read_selected(
      Ash.Query.filter(DeviceSNMPCredential, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :device_id]
    )
    |> map_direct(:device_snmp_credential, :credential_secret_id, :device_id)
  end

  defp load_mapper_unifi_controllers(ids) do
    MapperUnifiController
    |> read_selected(
      Ash.Query.filter(MapperUnifiController, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name, :base_url],
      unload: [:api_key]
    )
    |> map_direct(:mapper_unifi_controller, :credential_secret_id, &mapper_label/1)
  end

  defp load_mapper_mikrotik_controllers(ids) do
    MapperMikrotikController
    |> read_selected(
      Ash.Query.filter(MapperMikrotikController, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name, :base_url],
      unload: [:password]
    )
    |> map_direct(:mapper_mikrotik_controller, :credential_secret_id, &mapper_label/1)
  end

  defp load_integration_sources(ids) do
    IntegrationSource
    |> read_selected(
      Ash.Query.filter(IntegrationSource, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name],
      unload: [:credentials_encrypted]
    )
    |> map_direct(:integration_source, :credential_secret_id, :name)
  end

  defp load_outbound_mail_settings(ids) do
    query =
      Ash.Query.filter(
        OutboundMailSettings,
        password_secret_id in ^ids or api_key_secret_id in ^ids
      )

    with {:ok, rows} <-
           read_selected(
             OutboundMailSettings,
             query,
             [:id, :password_secret_id, :api_key_secret_id, :from_email],
             unload: [:password, :api_key]
           ) do
      {:ok,
       Enum.flat_map(rows, fn row ->
         label = "Outbound mail (#{row.from_email})"

         Enum.reject(
           [
             direct_entry(
               row.password_secret_id,
               :outbound_mail_settings,
               row.id,
               label,
               :password
             ),
             direct_entry(row.api_key_secret_id, :outbound_mail_settings, row.id, label, :api_key)
           ],
           &is_nil/1
         )
       end)}
    end
  end

  defp load_plugin_repositories(ids) do
    PluginRepository
    |> read_selected(
      Ash.Query.filter(PluginRepository, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name]
    )
    |> map_direct(:plugin_repository, :credential_secret_id, :name)
  end

  defp load_ansible_controllers(ids) do
    query =
      Ash.Query.filter(
        AnsibleController,
        credential_secret_id in ^ids or sync_credential_secret_id in ^ids or
          execution_credential_secret_id in ^ids or callback_credential_secret_id in ^ids
      )

    with {:ok, rows} <-
           read_selected(
             AnsibleController,
             query,
             [
               :id,
               :name,
               :credential_secret_id,
               :sync_credential_secret_id,
               :execution_credential_secret_id,
               :callback_credential_secret_id
             ]
           ) do
      {:ok, Enum.flat_map(rows, &ansible_controller_entries/1)}
    end
  end

  defp load_ansible_playbook_repositories(ids) do
    AnsiblePlaybookRepository
    |> read_selected(
      Ash.Query.filter(AnsiblePlaybookRepository, credential_secret_id in ^ids),
      [:id, :credential_secret_id, :name]
    )
    |> map_direct(:ansible_playbook_repository, :credential_secret_id, :name)
  end

  defp read_selected(resource, query_or_resource, fields, opts \\ []) do
    query_or_resource
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.unload(Keyword.get(opts, :unload, []))
    |> Ash.Query.select(fields)
    |> Ash.read(actor: @system_actor, domain: Info.domain(resource))
  end

  defp map_direct({:ok, rows}, kind, secret_field, label_field_or_fun) do
    {:ok,
     Enum.map(rows, fn row ->
       label =
         case label_field_or_fun do
           field when is_atom(field) -> Map.fetch!(row, field)
           label_fun when is_function(label_fun, 1) -> label_fun.(row)
         end

       direct_entry(Map.fetch!(row, secret_field), kind, row.id, label)
     end)}
  end

  defp map_direct({:error, error}, _kind, _secret_field, _label_field_or_fun), do: {:error, error}

  defp mapper_label(row),
    do: present_label(row.name) || present_label(row.base_url) || to_string(row.id)

  defp ansible_controller_entries(row) do
    legacy_id = row.credential_secret_id && to_string(row.credential_secret_id)
    sync_id = row.sync_credential_secret_id && to_string(row.sync_credential_secret_id)

    sync_entries =
      cond do
        legacy_id && sync_id && legacy_id != sync_id ->
          [
            direct_entry(legacy_id, :ansible_controller, row.id, row.name, :legacy_sync),
            direct_entry(sync_id, :ansible_controller, row.id, row.name, :sync)
          ]

        sync_id ->
          [direct_entry(sync_id, :ansible_controller, row.id, row.name, :sync)]

        legacy_id ->
          [direct_entry(legacy_id, :ansible_controller, row.id, row.name, :sync)]

        true ->
          []
      end

    Enum.reject(
      sync_entries ++
        [
          direct_entry(
            row.execution_credential_secret_id,
            :ansible_controller,
            row.id,
            row.name,
            :execution
          ),
          direct_entry(
            row.callback_credential_secret_id,
            :ansible_controller,
            row.id,
            row.name,
            :callback
          )
        ],
      &is_nil/1
    )
  end

  defp direct_entry(secret_id, kind, owner_id, label, slot \\ nil)

  defp direct_entry(nil, _kind, _owner_id, _label, _slot), do: nil

  defp direct_entry(secret_id, kind, owner_id, label, slot) do
    {to_string(secret_id),
     %Consumer{
       kind: kind,
       id: to_string(owner_id),
       label: present_label(label) || to_string(owner_id),
       slot: slot
     }}
  end

  defp load_bound_consumers(ids) do
    with {:ok, bindings} <- load_bindings(ids),
         {:ok, owner_maps} <- load_binding_owners(bindings),
         {:ok, entries} <- map_bindings(bindings, owner_maps) do
      {:ok, entries}
    else
      _error -> unavailable(:network_credential_secret_bindings)
    end
  rescue
    _error -> unavailable(:network_credential_secret_bindings)
  catch
    _kind, _reason -> unavailable(:network_credential_secret_bindings)
  end

  defp load_bindings(ids) do
    NetworkCredentialSecretBinding
    |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
    |> Ash.Query.filter(secret_id in ^ids)
    |> Ash.Query.select([:secret_id, :owner_kind, :owner_id, :field_path])
    |> Ash.read(actor: @system_actor)
  end

  defp load_binding_owners(bindings) do
    bindings
    |> Enum.group_by(& &1.owner_kind, & &1.owner_id)
    |> Enum.reduce_while({:ok, %{}}, fn {kind, owner_ids}, {:ok, acc} ->
      unique_ids = Enum.uniq(owner_ids)

      case load_owner_kind(kind, unique_ids) do
        {:ok, owners} when map_size(owners) == length(unique_ids) ->
          {:cont, {:ok, Map.put(acc, kind, owners)}}

        _other ->
          {:halt, :error}
      end
    end)
  end

  defp load_owner_kind(:vulnerability_feed_definition, owner_ids) do
    load_owner_labels(
      VulnerabilityFeedDefinition,
      owner_ids,
      [:id, :display_name],
      & &1.display_name
    )
  end

  defp load_owner_kind(:notification_channel, owner_ids) do
    load_owner_labels(NotificationChannel, owner_ids, [:id, :name], & &1.name)
  end

  defp load_owner_kind(:producer_schedule, owner_ids) do
    load_owner_labels(ProducerSchedule, owner_ids, [:id, :display_name], & &1.display_name)
  end

  defp load_owner_kind(:plugin_assignment, owner_ids) do
    load_owner_labels(
      PluginAssignment,
      owner_ids,
      [:id, :plugin_id, :agent_uid],
      &"#{&1.plugin_id} on #{&1.agent_uid}"
    )
  end

  defp load_owner_kind(:plugin_target_policy, owner_ids) do
    load_owner_labels(PluginTargetPolicy, owner_ids, [:id, :name], & &1.name)
  end

  defp load_owner_kind(_unknown, _owner_ids), do: :error

  defp load_owner_labels(resource, owner_ids, fields, label_fun) do
    with {:ok, cast_ids} <- normalize_ids(owner_ids),
         {:ok, rows} <-
           resource
           |> Ash.Query.for_read(:read, %{}, actor: @system_actor)
           |> Ash.Query.filter(id in ^cast_ids)
           |> Ash.Query.select(fields)
           |> Ash.read(actor: @system_actor, domain: Info.domain(resource)) do
      {:ok,
       Map.new(rows, fn row ->
         {to_string(row.id), present_label(label_fun.(row)) || to_string(row.id)}
       end)}
    end
  end

  defp map_bindings(bindings, owner_maps) do
    Enum.reduce_while(bindings, {:ok, []}, fn binding, {:ok, acc} ->
      with {:ok, slot} <- binding_slot(binding.owner_kind, binding.field_path),
           {:ok, owners} <- Map.fetch(owner_maps, binding.owner_kind),
           {:ok, label} <- Map.fetch(owners, binding.owner_id) do
        consumer = %Consumer{
          kind: binding.owner_kind,
          id: binding.owner_id,
          label: label,
          slot: slot
        }

        {:cont, {:ok, [{to_string(binding.secret_id), consumer} | acc]}}
      else
        _error -> {:halt, :error}
      end
    end)
  end

  defp binding_slot(:vulnerability_feed_definition, "$.credential_ref"),
    do: {:ok, :credential_ref}

  defp binding_slot(:notification_channel, path),
    do: path_slot(path, "$.secret_refs", :secret_refs)

  defp binding_slot(:producer_schedule, path) do
    case path_slot(path, "$.credential_refs", :credential_refs) do
      {:ok, slot} -> {:ok, slot}
      :error -> path_slot(path, "$.params", :params)
    end
  end

  defp binding_slot(:plugin_assignment, path), do: path_slot(path, "$.params", :params)

  defp binding_slot(:plugin_target_policy, path),
    do: path_slot(path, "$.params_template", :params_template)

  defp binding_slot(_kind, _path), do: :error

  defp path_slot(path, root, slot) when path == root, do: {:ok, slot}

  defp path_slot(path, root, slot) when is_binary(path),
    do: if(String.starts_with?(path, root <> "."), do: {:ok, slot}, else: :error)

  defp path_slot(_path, _root, _slot), do: :error

  defp load_live_grants(ids, now) do
    query =
      Ash.Query.filter(
        CredentialBrokerGrant,
        secret_id in ^ids and status in [:issued, :active] and expires_at > ^now
      )

    case read_selected(
           CredentialBrokerGrant,
           query,
           [:id, :secret_id, :status, :consumer_kind, :consumer_id, :purpose, :expires_at]
         ) do
      {:ok, grants} ->
        {:ok,
         Enum.map(grants, fn grant ->
           {to_string(grant.secret_id),
            %LiveGrant{
              id: to_string(grant.id),
              status: grant.status,
              consumer_kind: grant.consumer_kind,
              consumer_id: grant.consumer_id,
              purpose: grant.purpose,
              expires_at: grant.expires_at
            }}
         end)}

      {:error, _error} ->
        unavailable(:credential_broker_grants)
    end
  rescue
    _error -> unavailable(:credential_broker_grants)
  catch
    _kind, _reason -> unavailable(:credential_broker_grants)
  end

  defp group_consumers(ids, entries) do
    initial = Map.new(ids, &{&1, %{}})

    entries
    |> Enum.reduce(initial, fn {secret_id, consumer}, acc ->
      Map.update!(acc, secret_id, fn consumers ->
        Map.put_new(consumers, {consumer.kind, consumer.id, consumer.slot}, consumer)
      end)
    end)
    |> Map.new(fn {secret_id, consumers} ->
      {secret_id,
       consumers
       |> Map.values()
       |> Enum.sort_by(&{&1.kind, &1.id, &1.slot})}
    end)
  end

  defp group_grants(ids, entries) do
    initial = Map.new(ids, &{&1, %{}})

    entries
    |> Enum.reduce(initial, fn {secret_id, grant}, acc ->
      Map.update!(acc, secret_id, &Map.put_new(&1, grant.id, grant))
    end)
    |> Map.new(fn {secret_id, grants} ->
      {secret_id, grants |> Map.values() |> Enum.sort_by(& &1.id)}
    end)
  end

  defp normalize_ids(ids) do
    ids
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
      case normalize_id(id) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, unavailable(:authorization)}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  defp normalize_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> :error
    end
  end

  defp present_label(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      label -> label
    end
  end

  defp present_label(_value), do: nil

  defp unavailable(source), do: {:error, {@unavailable, source}}
end
