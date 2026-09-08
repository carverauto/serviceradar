defmodule ServiceRadar.AgentConfig.Compilers.MapperCompilerTest do
  @moduledoc """
  Integration tests for MapperCompiler credential resolution.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.AgentConfig.Compilers.MapperCompiler
  alias ServiceRadar.Credentials.NetworkCredentialRule
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.SNMPProfiles.CredentialResolver
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "uses profile credentials for mapper discovery jobs" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    device_uid = "sr:" <> Ash.UUID.generate()
    hostname = "mapper-target-#{unique_id}"
    job_name = "Mapper Job #{unique_id}"

    {:ok, _device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: device_uid,
          hostname: hostname,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _profile} =
      SNMPProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Default SNMP #{unique_id}",
          enabled: true,
          target_query: ~s(in:devices hostname:"#{hostname}"),
          priority: 1_000_000 + unique_id,
          community: "public"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _seed} =
      MapperSeed
      |> Ash.Changeset.for_create(
        :create,
        %{mapper_job_id: job.id, seed: "192.168.1.0/24"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor, device_uid: device_uid)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job
    assert compiled_job["credentials"]["version"] == "v2c"
    assert compiled_job["credentials"]["community"] == "public"
  end

  @tag :integration
  test "falls back to default SNMP profile credentials when device uid is missing" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job Default #{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _seed} =
      MapperSeed
      |> Ash.Changeset.for_create(
        :create,
        %{mapper_job_id: job.id, seed: "192.168.10.1"},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job
    assert compiled_job["credentials"]["version"] == "v2c"

    case CredentialResolver.resolve_default(actor) do
      {:ok, %{credential: %{community: community}}}
      when is_binary(community) and community != "" ->
        assert compiled_job["credentials"]["community"] == community

      _ ->
        refute Map.has_key?(compiled_job["credentials"], "community")
    end
  end

  @tag :integration
  test "compiles mikrotik controllers into mapper config and job selectors" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job MikroTik #{unique_id}"
    controller_name = "chr-demo-#{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: controller_name,
          base_url: "https://192.168.88.1",
          username: "admin",
          password: "secret"
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == controller_name and
               controller["base_url"] == "https://192.168.88.1/rest"
           end)

    compiled_job =
      Enum.find(config["scheduled_jobs"], fn scheduled_job ->
        scheduled_job["name"] == job_name
      end)

    assert compiled_job
    assert compiled_job["options"]["mikrotik_api_names"] == controller_name
    assert compiled_job["options"]["mikrotik_api_urls"] == "https://192.168.88.1/rest"
  end

  @tag :integration
  test "normalizes nil API secrets to empty strings in mapper config" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job API Nil Secret #{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _mikrotik_controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "chr-demo-#{unique_id}",
          base_url: "https://192.168.88.1",
          username: "admin",
          password: nil
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _unifi_controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "unifi-demo-#{unique_id}",
          base_url: "https://192.168.10.1",
          api_key: nil
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-demo-#{unique_id}" and controller["password"] == ""
           end)

    assert Enum.any?(config["unifi_apis"], fn controller ->
             controller["name"] == "unifi-demo-#{unique_id}" and controller["api_key"] == ""
           end)
  end

  @tag :integration
  test "resolves mapper API controller secrets through credential broker references" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job API Broker Secret #{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, mikrotik_secret} =
      create_mapper_secret(
        "mikrotik",
        "RouterOS Password #{unique_id}",
        Jason.encode!(%{"password" => "routeros-broker-secret"}),
        actor
      )

    {:ok, unifi_secret} =
      create_mapper_secret(
        "unifi",
        "UniFi API Key #{unique_id}",
        "unifi-broker-api-key",
        actor
      )

    {:ok, _mikrotik_controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "chr-broker-#{unique_id}",
          base_url: "https://192.168.88.1",
          username: "admin",
          credential_secret_id: mikrotik_secret.id
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _unifi_controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "unifi-broker-#{unique_id}",
          base_url: "https://192.168.10.1",
          credential_secret_id: unifi_secret.id
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-broker-#{unique_id}" and
               controller["password"] == "routeros-broker-secret"
           end)

    assert Enum.any?(config["unifi_apis"], fn controller ->
             controller["name"] == "unifi-broker-#{unique_id}" and
               controller["api_key"] == "unifi-broker-api-key"
           end)
  end

  @tag :integration
  test "does not compile external mapper controller secrets into plaintext without broker grants" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    job_name = "Mapper Job External API Broker Secret #{unique_id}"
    external_password = "external-routeros-secret-#{unique_id}"
    external_api_key = "external-unifi-secret-#{unique_id}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, mikrotik_secret} =
      create_external_mapper_secret(
        "mikrotik",
        "External RouterOS Password #{unique_id}",
        "secret/data/mapper/mikrotik/#{unique_id}",
        external_password,
        actor
      )

    {:ok, unifi_secret} =
      create_external_mapper_secret(
        "unifi",
        "External UniFi API Key #{unique_id}",
        "secret/data/mapper/unifi/#{unique_id}",
        external_api_key,
        actor
      )

    {:ok, _mikrotik_controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "chr-external-broker-#{unique_id}",
          base_url: "https://192.0.2.88",
          username: "admin",
          credential_secret_id: mikrotik_secret.id
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, _unifi_controller} =
      MapperUnifiController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "unifi-external-broker-#{unique_id}",
          base_url: "https://192.0.2.10",
          credential_secret_id: unifi_secret.id
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile("default", nil, actor: actor)

    refute inspect(config) =~ external_password
    refute inspect(config) =~ external_api_key

    assert Enum.any?(config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-external-broker-#{unique_id}" and
               controller["password"] == ""
           end)

    assert Enum.any?(config["unifi_apis"], fn controller ->
             controller["name"] == "unifi-external-broker-#{unique_id}" and
               controller["api_key"] == ""
           end)
  end

  @tag :integration
  test "enables Proxmox candidate probing on API mapper jobs when scoped credential rule opts in" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    partition = "pve-partition-#{unique_id}"
    agent_id = "agent-pve-#{unique_id}"
    job_name = "Mapper Job Proxmox API #{unique_id}"

    {:ok, _job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          partition: partition,
          discovery_mode: :api,
          discovery_type: :basic
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, secret} = create_proxmox_secret(unique_id, actor)

    {:ok, _rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "PVE Auto Discovery #{unique_id}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :inventory_enrichment,
          target_query: "in:devices metadata.proxmox_candidate:true",
          scope_type: :agent,
          scope_value: agent_id,
          secret_id: secret.id,
          metadata: %{"auto_discovery_enabled" => true}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)

    compiled_job = compiled_job(config, job_name)

    assert compiled_job
    assert compiled_job["options"]["proxmox_candidate_probe_enabled"] == "true"
  end

  @tag :integration
  test "does not enable Proxmox candidate probing for scoped rules without explicit opt in" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    partition = "pve-partition-manual-#{unique_id}"
    agent_id = "agent-pve-manual-#{unique_id}"
    job_name = "Mapper Job Proxmox Manual #{unique_id}"

    {:ok, _job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          partition: partition,
          discovery_mode: :api,
          discovery_type: :basic
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, secret} = create_proxmox_secret(unique_id, actor)

    {:ok, _rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "PVE SRQL Scoped #{unique_id}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :inventory_enrichment,
          target_query: "in:devices metadata.proxmox_candidate:true",
          scope_type: :agent,
          scope_value: agent_id,
          secret_id: secret.id,
          metadata: %{"auto_discovery_enabled" => false}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)

    compiled_job = compiled_job(config, job_name)

    assert compiled_job
    refute Map.has_key?(compiled_job["options"], "proxmox_candidate_probe_enabled")
  end

  @tag :integration
  test "does not enable Proxmox candidate probing on SNMP-only mapper jobs" do
    actor = SystemActor.system(:test)
    unique_id = System.unique_integer([:positive])
    partition = "pve-partition-snmp-#{unique_id}"
    agent_id = "agent-pve-snmp-#{unique_id}"
    job_name = "Mapper Job Proxmox SNMP #{unique_id}"

    {:ok, _job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: job_name,
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :basic
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, secret} = create_proxmox_secret(unique_id, actor)

    {:ok, _rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "PVE SNMP Scoped #{unique_id}",
          provider: "proxmox",
          auth_method: :proxmox_api_token,
          purpose: :inventory_enrichment,
          target_query: "in:devices metadata.proxmox_candidate:true",
          scope_type: :agent,
          scope_value: agent_id,
          secret_id: secret.id,
          metadata: %{"auto_discovery_enabled" => true}
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)

    compiled_job = compiled_job(config, job_name)

    assert compiled_job
    refute Map.has_key?(compiled_job["options"], "proxmox_candidate_probe_enabled")
  end

  defp create_proxmox_secret(unique_id, actor) do
    NetworkCredentialSecret
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "PVE Token #{unique_id}",
        provider: "proxmox",
        credential_kind: :api_token,
        username: "root@pam!serviceradar",
        secret_payload: "token-secret",
        metadata: %{"secret_payload_format" => "proxmox_api_token.v1"}
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp create_mapper_secret(provider, name, secret_payload, actor) do
    NetworkCredentialSecret
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        provider: provider,
        credential_kind: :opaque,
        secret_payload: secret_payload
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp create_external_mapper_secret(provider, name, external_secret_ref, stub_value, actor) do
    NetworkCredentialSecret
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: name,
        provider: provider,
        credential_kind: :opaque,
        source_type: :external_reference,
        external_secret_ref: external_secret_ref,
        metadata: %{"stub_secret_value" => stub_value},
        resolution_location: :agent
      },
      actor: actor
    )
    |> Ash.create(actor: actor)
  end

  defp compiled_job(config, job_name) do
    Enum.find(config["scheduled_jobs"], fn scheduled_job ->
      scheduled_job["name"] == job_name
    end)
  end
end
