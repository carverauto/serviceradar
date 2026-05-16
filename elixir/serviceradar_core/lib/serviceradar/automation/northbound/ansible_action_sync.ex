defmodule ServiceRadar.Automation.Northbound.AnsibleActionSync do
  @moduledoc """
  Mirrors launchable AWX playbooks into provider-neutral northbound actions.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Northbound
  alias ServiceRadar.Automation.Northbound.ActionDescriptor
  alias ServiceRadar.Automation.Northbound.ActionProvider

  require Ash.Query
  require Logger

  @system_actor SystemActor.system(:northbound_ansible_action_sync)
  @provider_type :ansible
  @version "1.0.0"

  @spec sync_launchable_playbooks(keyword()) :: {:ok, map()} | {:error, term()}
  def sync_launchable_playbooks(opts \\ []) do
    actor = Keyword.get(opts, :actor, @system_actor)

    with {:ok, playbooks} <- list_launchable_playbooks(actor) do
      playbooks
      |> Enum.group_by(& &1.controller_id)
      |> Enum.reduce_while({:ok, %{providers: [], descriptors: []}}, fn {controller_id, books},
                                                                        {:ok, acc} ->
        with {:ok, controller} <- load_controller(controller_id, actor),
             {:ok, provider} <- upsert_provider(controller, actor),
             {:ok, provider} <- ensure_active(provider, actor),
             {:ok, descriptors} <- upsert_descriptors(provider, controller, books, actor),
             {:ok, _disabled_count} <- disable_stale_descriptors(provider, descriptors, actor) do
          {:cont,
           {:ok,
            %{
              providers: [provider | acc.providers],
              descriptors: descriptors ++ acc.descriptors
            }}}
        else
          {:error, reason} ->
            Logger.warning("Failed to sync Ansible northbound actions: #{inspect(reason)}")
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp list_launchable_playbooks(actor) do
    Playbook
    |> Ash.Query.for_read(:read, %{}, actor: actor)
    |> Ash.Query.filter(source_type == :awx and not is_nil(awx_job_template_id))
    |> Ash.read(actor: actor, domain: Ansible)
  end

  defp load_controller(nil, _actor), do: {:error, :missing_controller_id}

  defp load_controller(controller_id, actor) do
    case Controller.get_by_id(controller_id, actor: actor) do
      {:ok, nil} -> {:error, {:controller_not_found, controller_id}}
      {:ok, controller} -> {:ok, controller}
      {:error, reason} -> {:error, reason}
      nil -> {:error, {:controller_not_found, controller_id}}
    end
  end

  defp upsert_provider(controller, actor) do
    attrs = provider_attrs(controller)

    case read_provider(controller, actor) do
      {:ok, nil} ->
        ActionProvider
        |> Ash.Changeset.for_create(:create, attrs, actor: actor)
        |> Ash.create(actor: actor, domain: Northbound)

      {:ok, provider} ->
        provider
        |> Ash.Changeset.for_update(:update, Map.delete(attrs, :provider_type), actor: actor)
        |> Ash.update(actor: actor, domain: Northbound)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp provider_attrs(%Controller{} = controller) do
    %{
      name: "Ansible: #{controller.name}",
      description: controller.description,
      provider_type: @provider_type,
      source_ref: source_ref(controller),
      approved_capabilities: ["awx.launch_job"],
      credential_requirements: %{"controller_id" => controller.id},
      metadata: %{
        "controller_id" => controller.id,
        "agent_id" => controller.agent_id,
        "base_url" => controller.base_url
      }
    }
  end

  defp read_provider(controller, actor) do
    ActionProvider
    |> Ash.Query.for_read(
      :by_source,
      %{provider_type: @provider_type, source_ref: source_ref(controller)},
      actor: actor
    )
    |> Ash.read_one(actor: actor, domain: Northbound)
  end

  defp ensure_active(%ActionProvider{status: :active} = provider, _actor), do: {:ok, provider}

  defp ensure_active(%ActionProvider{status: :unhealthy} = provider, actor) do
    provider
    |> Ash.Changeset.for_update(
      :mark_recovered,
      %{last_health_summary: "AWX playbooks available for northbound launch"},
      actor: actor
    )
    |> Ash.update(actor: actor, domain: Northbound)
  end

  defp ensure_active(%ActionProvider{} = provider, actor) do
    provider
    |> Ash.Changeset.for_update(:activate, %{}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
  end

  defp upsert_descriptors(provider, controller, playbooks, actor) do
    playbooks
    |> Enum.reduce_while({:ok, []}, fn playbook, {:ok, acc} ->
      attrs = descriptor_attrs(provider, controller, playbook)

      ActionDescriptor
      |> Ash.Changeset.for_create(:upsert, attrs, actor: actor)
      |> Ash.create(actor: actor, domain: Northbound)
      |> case do
        {:ok, descriptor} -> {:cont, {:ok, [descriptor | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, descriptors} -> {:ok, Enum.reverse(descriptors)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp descriptor_attrs(provider, controller, playbook) do
    descriptor = %{
      "controller_id" => controller.id,
      "playbook_id" => playbook.id,
      "awx_job_template_id" => playbook.awx_job_template_id,
      "name" => playbook.name,
      "version" => @version
    }

    %{
      provider_id: provider.id,
      action_id: "ansible.playbook.#{playbook.id}",
      version: @version,
      label: playbook.name,
      description: playbook.description,
      scopes: ["device"],
      required_context: ["device.uid"],
      input_schema: extra_vars_schema(),
      safety_classification: :standard,
      requires_confirmation: true,
      timeout_seconds: 300,
      credential_requirements: %{"controller_id" => controller.id},
      result_schema_version: "serviceradar.northbound_ansible_result.v1",
      descriptor_hash: descriptor_hash(descriptor),
      enabled: true,
      metadata:
        descriptor
        |> Map.put("provider_name", provider.name)
        |> Map.put("source_type", "awx")
    }
  end

  defp disable_stale_descriptors(provider, synced_descriptors, actor) do
    active_keys = MapSet.new(synced_descriptors, &descriptor_key/1)

    with {:ok, existing} <- list_provider_descriptors(provider, actor) do
      existing
      |> Enum.reject(&(descriptor_key(&1) in active_keys))
      |> Enum.reduce_while({:ok, 0}, fn descriptor, {:ok, count} ->
        disable_descriptor(descriptor, actor, count)
      end)
    end
  end

  defp list_provider_descriptors(provider, actor) do
    ActionDescriptor
    |> Ash.Query.for_read(:by_provider, %{provider_id: provider.id}, actor: actor)
    |> Ash.read(actor: actor, domain: Northbound)
  end

  defp disable_descriptor(%ActionDescriptor{enabled: false}, _actor, count),
    do: {:cont, {:ok, count}}

  defp disable_descriptor(%ActionDescriptor{} = descriptor, actor, count) do
    descriptor
    |> Ash.Changeset.for_update(:update, %{enabled: false}, actor: actor)
    |> Ash.update(actor: actor, domain: Northbound)
    |> case do
      {:ok, _descriptor} -> {:cont, {:ok, count + 1}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp descriptor_key(%ActionDescriptor{} = descriptor),
    do: {descriptor.action_id, descriptor.version}

  defp extra_vars_schema do
    %{
      "type" => "object",
      "properties" => %{
        "extra_vars" => %{
          "type" => "object",
          "title" => "Extra Vars",
          "description" => "Optional AWX extra_vars JSON object.",
          "default" => %{},
          "x-order" => 10
        }
      }
    }
  end

  defp source_ref(%Controller{} = controller), do: "ansible:controller:#{controller.id}"

  defp descriptor_hash(descriptor) do
    descriptor
    |> canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value
end
