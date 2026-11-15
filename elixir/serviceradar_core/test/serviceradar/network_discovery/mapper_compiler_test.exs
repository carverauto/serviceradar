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
  alias ServiceRadar.Inventory.DeviceSNMPCredential
  alias ServiceRadar.NetworkDiscovery.MapperJob
  alias ServiceRadar.NetworkDiscovery.MapperMikrotikController
  alias ServiceRadar.NetworkDiscovery.MapperSeed
  alias ServiceRadar.NetworkDiscovery.MapperUnifiController
  alias ServiceRadar.Repo
  alias ServiceRadar.SNMPProfiles.SNMPProfile

  @tag :integration
  setup do
    ServiceRadar.TestSupport.start_core!()
    :ok
  end

  @tag :integration
  test "compiles scoped switch credentials alongside the job's own SNMP credential" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "example-partition-#{suffix}"
    agent_id = "example-agent-#{suffix}"
    agent_hostname = "collector-#{suffix}.example.com"
    switch_vendor = "Example Switch Vendor #{suffix}"

    [agent_device | _] =
      Enum.map(
        [
          {agent_hostname, "192.0.2.10", "Example Collector"},
          {"switch-a-#{suffix}.example.com", "192.0.2.40", switch_vendor},
          {"switch-b-#{suffix}.example.com", "192.0.2.41", switch_vendor},
          {"legacy-#{suffix}.example.com", "192.0.2.42", "Example Legacy Vendor"}
        ],
        fn {hostname, ip, vendor} ->
          Device
          |> Ash.Changeset.for_create(
            :create,
            %{
              uid: "sr:" <> Ash.UUID.generate(),
              hostname: hostname,
              ip: ip,
              vendor_name: vendor,
              type_id: 10,
              created_time: DateTime.utc_now(),
              modified_time: DateTime.utc_now()
            },
            actor: actor
          )
          |> Ash.create!(actor: actor)
        end
      )

    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example collector profile #{suffix}",
        enabled: true,
        target_query: ~s(in:devices hostname:"#{agent_hostname}"),
        community: "example-fallback"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    {:ok, secret} =
      create_mapper_secret(
        "snmp",
        "Example switch credential #{suffix}",
        Jason.encode!(%{
          "username" => "example-reader",
          "security_level" => "authPriv",
          "auth_protocol" => "SHA",
          "auth_password" => "example-auth-password",
          "priv_protocol" => "AES",
          "priv_password" => "example-privacy-password"
        }),
        actor
      )

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example switches #{suffix}",
        provider: "snmp",
        auth_method: :v3,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices vendor_name:"#{switch_vendor}"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    {:ok, job_secret} =
      create_mapper_secret("snmp", "Example job credential #{suffix}", "example-job", actor)

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example mixed discovery #{suffix}",
          partition: partition,
          discovery_mode: :snmp_api,
          discovery_type: :full,
          snmp_credential_secret_id: job_secret.id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    for ip <- ["192.0.2.40", "192.0.2.42"] do
      MapperSeed
      |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: ip}, actor: actor)
      |> Ash.create!(actor: actor)
    end

    {:ok, config} =
      MapperCompiler.compile(partition, agent_id, actor: actor, device_uid: agent_device.uid)

    compiled = compiled_job(config, job.name)
    assert compiled["discovery_mode"] == "snmp_api"
    # The collector's own polling credential ("example-fallback") is not the
    # fallback: addresses without a device credential use the job's.
    assert compiled["credentials"]["version"] == "v2c"
    assert compiled["credentials"]["community"] == "example-job"

    # Both the seed and a known neighbour discovered later need the scoped rule.
    for ip <- ["192.0.2.40", "192.0.2.41"] do
      target = compiled["credentials"]["target_specific"][ip]
      assert target["version"] == "v3"
      assert target["username"] == "example-reader"
      assert target["security_level"] == "authPriv"
      assert target["auth_password"] == "example-auth-password"
      assert target["privacy_password"] == "example-privacy-password"
    end

    {:ok, other_config} =
      MapperCompiler.compile(partition, "other-#{agent_id}",
        actor: actor,
        device_uid: agent_device.uid
      )

    other_targets = compiled_job(other_config, job.name)["credentials"]["target_specific"]
    refute get_in(other_targets, ["192.0.2.40", "version"]) == "v3"
    refute Map.has_key?(other_targets, "192.0.2.41")
  end

  # Target credentials are resolved a batch of devices at a time. Resolving them
  # one device at a time costs several queries for each of the 200 devices.
  @tag :integration
  @tag timeout: 300_000
  test "resolves a rule's target credentials in a fixed number of queries" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "example-partition-#{suffix}"
    agent_id = "example-agent-#{suffix}"
    vendor = "Example Batch Vendor #{suffix}"

    ips =
      for index <- 1..200 do
        ip = ServiceRadar.TestSupport.unique_device_ip()

        Device
        |> Ash.Changeset.for_create(
          :create,
          %{
            uid: "sr:" <> Ash.UUID.generate(),
            hostname: "batch-#{index}-#{suffix}.example.com",
            ip: ip,
            vendor_name: vendor
          },
          actor: actor
        )
        |> Ash.create!(actor: actor)

        ip
      end

    {:ok, secret} =
      create_mapper_secret("snmp", "Example batch credential #{suffix}", "batch-community", actor)

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example batch rule #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices vendor_name:"#{vendor}"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example batch discovery #{suffix}",
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    handler = "mapper-compiler-queries-#{suffix}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:service_radar, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)
    :telemetry.detach(handler)
    queries = drain_repo_queries(0)

    targets = compiled_job(config, job.name)["credentials"]["target_specific"]
    assert targets |> Map.keys() |> Enum.sort() == Enum.sort(ips)
    assert Enum.all?(targets, fn {_ip, target} -> target["community"] == "batch-community" end)

    # Measured 27 for the whole compile.
    assert queries <= 30,
           "compiling target credentials for 200 devices took #{queries} queries"
  end

  defp drain_repo_queries(count) do
    receive do
      :repo_query -> drain_repo_queries(count + 1)
    after
      0 -> count
    end
  end

  @tag :integration
  test "the default profile and unmatched monitoring rules never select a job's SNMP credential" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "fallback-partition-#{suffix}"
    agent_id = "fallback-agent-#{suffix}"

    {:ok, site_a} = create_mapper_secret("snmp", "Site A #{suffix}", "site-a-community", actor)
    {:ok, site_b} = create_mapper_secret("snmp", "Site B #{suffix}", "site-b-community", actor)
    {:ok, rule_secret} = create_mapper_secret("snmp", "Rule #{suffix}", "rule-community", actor)

    # Before jobs had their own credential, this agent-scoped rule was the
    # fallback for every unknown address on the agent, its target query ignored.
    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "One host #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices hostname:"host01-#{suffix}.example.com"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: rule_secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    default_profile = default_profile_fixture("Default #{suffix}", "default-community", actor)

    jobs =
      for {name, secret} <- [{"Site A #{suffix}", site_a}, {"Site B #{suffix}", site_b}] do
        mapper_job_fixture(name, partition, :snmp, secret.id, ["192.0.2.60"], actor)
      end

    assert base_communities(partition, agent_id, jobs, actor) == [
             "site-a-community",
             "site-b-community"
           ]

    default_profile
    |> Ash.Changeset.for_update(:unset_default, %{}, actor: actor)
    |> Ash.update!(actor: actor)

    assert base_communities(partition, agent_id, jobs, actor) == [
             "site-a-community",
             "site-b-community"
           ]
  end

  @tag :integration
  test "a job without its own SNMP credential compiles an empty base credential, never v2c" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "unbound-partition-#{suffix}"
    agent_id = "unbound-agent-#{suffix}"

    {:ok, rule_secret} =
      create_mapper_secret("snmp", "Agent rule #{suffix}", "rule-community", actor)

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Every device #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: "in:devices",
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: rule_secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    default_profile_fixture("Default #{suffix}", "default-community", actor)

    snmp_job = mapper_job_fixture("SNMP #{suffix}", partition, :snmp, nil, ["192.0.2.70"], actor)
    api_job = mapper_job_fixture("API #{suffix}", partition, :api, nil, [], actor)

    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)

    for job <- [snmp_job, api_job] do
      credentials = compiled_job(config, job.name)["credentials"]
      assert Map.delete(credentials, "target_specific") == %{}
      refute Map.has_key?(credentials["target_specific"], "192.0.2.70")
    end

    assert [true, false] =
             Enum.map([snmp_job, api_job], fn job ->
               job
               |> Ash.load!(:snmp_credential_missing, actor: actor)
               |> Map.fetch!(:snmp_credential_missing)
             end)
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
  test "suppresses SNMP for a target whose credential fails to resolve without failing the compile" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "example-partition-#{suffix}"
    agent_id = "example-agent-#{suffix}"
    good_vendor = "Example Good Vendor #{suffix}"
    bad_vendor = "Example Unresolvable Vendor #{suffix}"
    collector = create_mapper_collector(suffix, actor)

    [good_device, bad_device] =
      Enum.map(
        [
          {"good-#{suffix}.example.com", "192.0.2.50", good_vendor},
          {"bad-#{suffix}.example.com", "192.0.2.51", bad_vendor}
        ],
        fn {hostname, ip, vendor} ->
          Device
          |> Ash.Changeset.for_create(
            :create,
            %{
              uid: "sr:" <> Ash.UUID.generate(),
              hostname: hostname,
              ip: ip,
              vendor_name: vendor,
              type_id: 10,
              created_time: DateTime.utc_now(),
              modified_time: DateTime.utc_now()
            },
            actor: actor
          )
          |> Ash.create!(actor: actor)
        end
      )

    {:ok, good_secret} =
      create_mapper_secret(
        "snmp",
        "Example good credential #{suffix}",
        Jason.encode!(%{"community" => "example-good"}),
        actor
      )

    {:ok, bad_secret} =
      create_external_mapper_secret(
        "snmp",
        "Example unresolvable credential #{suffix}",
        "secret/data/snmp/#{suffix}",
        "unused",
        actor
      )

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example good rule #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices vendor_name:"#{good_vendor}"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: good_secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example bad rule #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices vendor_name:"#{bad_vendor}"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: bad_secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example failure isolation discovery #{suffix}",
          partition: partition,
          discovery_mode: :snmp_api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    for device <- [good_device, bad_device] do
      MapperSeed
      |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: device.ip},
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end

    assert {:ok, config} =
             MapperCompiler.compile(partition, agent_id, actor: actor, device_uid: collector.uid)

    compiled = compiled_job(config, job.name)
    target_specific = compiled["credentials"]["target_specific"]

    assert target_specific["192.0.2.50"]["community"] == "example-good"
    assert target_specific["192.0.2.51"] == %{}
  end

  @tag :integration
  test "suppresses SNMP when one seed matches devices with conflicting profile credentials" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "example-partition-#{suffix}"
    agent_id = "example-agent-#{suffix}"
    shared_ip = "192.0.2.70"
    vendor_a = "Example Conflict Vendor A #{suffix}"
    vendor_b = "Example Conflict Vendor B #{suffix}"
    collector = create_mapper_collector(suffix, actor)

    _device_a =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          hostname: "conflict-a-#{suffix}.example.com",
          ip: shared_ip,
          partition: partition,
          vendor_name: vendor_a,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    _device_b =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          hostname: "conflict-b-#{suffix}.example.com",
          ip: shared_ip,
          partition: "example-other-partition-#{suffix}",
          vendor_name: vendor_b,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    # Profile-only credentials keep discovery dependent on every seed match.
    for {vendor, community} <- [
          {vendor_a, "example-conflict-a"},
          {vendor_b, "example-conflict-b"}
        ] do
      SNMPProfile
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example conflict profile #{vendor}",
          enabled: true,
          target_query: ~s(in:devices vendor_name:"#{vendor}"),
          community: community
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)
    end

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example conflict discovery #{suffix}",
          partition: partition,
          discovery_mode: :snmp_api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    MapperSeed
    |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: shared_ip}, actor: actor)
    |> Ash.create!(actor: actor)

    assert {:ok, config} =
             MapperCompiler.compile(partition, agent_id, actor: actor, device_uid: collector.uid)

    compiled = compiled_job(config, job.name)
    assert compiled["credentials"]["target_specific"][shared_ip] == %{}
  end

  @tag :integration
  test "skips target-specific SNMP credential resolution when no selected job performs SNMP discovery" do
    actor = SystemActor.system(:test)
    suffix = System.unique_integer([:positive])
    partition = "example-partition-#{suffix}"
    agent_id = "example-agent-#{suffix}"
    vendor = "Example Api Only Vendor #{suffix}"
    collector = create_mapper_collector(suffix, actor)

    device =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          hostname: "api-only-#{suffix}.example.com",
          ip: "192.0.2.80",
          vendor_name: vendor,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    {:ok, bad_secret} =
      create_external_mapper_secret(
        "snmp",
        "Example api-only unresolvable credential #{suffix}",
        "secret/data/snmp/#{suffix}",
        "unused",
        actor
      )

    NetworkCredentialRule
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example api-only rule #{suffix}",
        provider: "snmp",
        auth_method: :community,
        purpose: "snmp_monitoring",
        target_query: ~s(in:devices vendor_name:"#{vendor}"),
        scope_type: :agent,
        scope_value: agent_id,
        secret_id: bad_secret.id
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Example api-only discovery #{suffix}",
          partition: partition,
          discovery_mode: :api,
          discovery_type: :full
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    MapperSeed
    |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: device.ip}, actor: actor)
    |> Ash.create!(actor: actor)

    assert {:ok, config} =
             MapperCompiler.compile(partition, agent_id, actor: actor, device_uid: collector.uid)

    compiled = compiled_job(config, job.name)
    assert compiled["credentials"]["target_specific"] == %{}
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

  @tag :integration
  test "a failed job credential read fails the compile instead of compiling an empty credential" do
    actor = SystemActor.system(:test)
    unique = System.unique_integer([:positive])
    partition = "job-credential-read-#{unique}"
    agent_id = "agent-job-credential-read-#{unique}"

    {:ok, secret} = create_mapper_secret("snmp", "Job read #{unique}", "job-community", actor)
    job = mapper_job_fixture("Job read #{unique}", partition, :snmp, secret.id, [], actor)

    Repo.query!(
      "ALTER TABLE platform.network_credential_secrets RENAME TO _network_credential_secrets_hidden"
    )

    try do
      assert {:error, {:credential_resolution_failed, _}} =
               MapperCompiler.compile(partition, agent_id, actor: actor)
    after
      Repo.query!(
        "ALTER TABLE platform._network_credential_secrets_hidden RENAME TO network_credential_secrets"
      )
    end

    assert {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)
    assert compiled_job(config, job.name)["credentials"]["community"] == "job-community"
  end

  @tag :integration
  test "a failed seed credential read fails the compile instead of suppressing that address" do
    actor = SystemActor.system(:test)
    unique = System.unique_integer([:positive])
    partition = "seed-read-#{unique}"
    agent_id = "agent-seed-read-#{unique}"
    collector = create_mapper_collector(unique, actor)
    seed_ip = "192.0.2.#{rem(unique, 200) + 20}"

    {:ok, seed_device} =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          hostname: "seed-#{unique}.example.com",
          ip: seed_ip,
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, secret} = create_mapper_secret("snmp", "Seed secret #{unique}", "seed-community", actor)

    {:ok, _override} =
      DeviceSNMPCredential
      |> Ash.Changeset.for_create(
        :create,
        %{device_id: seed_device.uid, version: :v2c, credential_secret_id: secret.id},
        actor: actor
      )
      |> Ash.create(actor: actor)

    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Seed read #{unique}",
          partition: partition,
          discovery_mode: :snmp,
          discovery_type: :basic
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    MapperSeed
    |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: seed_ip}, actor: actor)
    |> Ash.create!(actor: actor)

    Repo.query!(
      "ALTER TABLE platform.network_credential_secrets RENAME TO _network_credential_secrets_hidden"
    )

    try do
      assert {:error, {:credential_resolution_failed, _}} =
               MapperCompiler.compile(partition, agent_id,
                 actor: actor,
                 device_uid: collector.uid
               )
    after
      Repo.query!(
        "ALTER TABLE platform._network_credential_secrets_hidden RENAME TO network_credential_secrets"
      )
    end

    assert {:ok, config} =
             MapperCompiler.compile(partition, agent_id, actor: actor, device_uid: collector.uid)

    compiled = compiled_job(config, job.name)
    assert compiled["credentials"]["target_specific"][seed_ip]["community"] == "seed-community"
  end

  @tag :integration
  test "a failed mapper controller secret read does not compile an empty password" do
    actor = SystemActor.system(:test)
    unique = System.unique_integer([:positive])
    job_name = "Mapper controller outage #{unique}"

    {:ok, job} =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{name: job_name, discovery_mode: :api, discovery_type: :full},
        actor: actor
      )
      |> Ash.create(actor: actor)

    {:ok, secret} =
      create_mapper_secret(
        "mikrotik",
        "RouterOS outage #{unique}",
        Jason.encode!(%{"password" => "routeros-broker-secret"}),
        actor
      )

    {:ok, _controller} =
      MapperMikrotikController
      |> Ash.Changeset.for_create(
        :create,
        %{
          mapper_job_id: job.id,
          name: "chr-outage-#{unique}",
          base_url: "https://192.0.2.88",
          username: "admin",
          credential_secret_id: secret.id
        },
        actor: actor
      )
      |> Ash.create(actor: actor)

    assert {:ok, before_config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(before_config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-outage-#{unique}" and
               controller["password"] == "routeros-broker-secret"
           end)

    Repo.query!(
      "ALTER TABLE platform.network_credential_secrets RENAME TO _network_credential_secrets_hidden"
    )

    try do
      assert {:error, {:credential_resolution_failed, _}} =
               MapperCompiler.compile("default", nil, actor: actor)
    after
      Repo.query!(
        "ALTER TABLE platform._network_credential_secrets_hidden RENAME TO network_credential_secrets"
      )
    end

    assert {:ok, after_config} = MapperCompiler.compile("default", nil, actor: actor)

    assert Enum.any?(after_config["mikrotik_apis"], fn controller ->
             controller["name"] == "chr-outage-#{unique}" and
               controller["password"] == "routeros-broker-secret"
           end)
  end

  @tag :integration
  test "a failed Proxmox rule read fails the compile instead of disabling the probe" do
    actor = SystemActor.system(:test)
    unique = System.unique_integer([:positive])
    partition = "pve-read-#{unique}"
    agent_id = "agent-pve-read-#{unique}"
    job_name = "Mapper Job Proxmox Read #{unique}"

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

    {:ok, secret} = create_proxmox_secret(unique, actor)

    {:ok, _rule} =
      NetworkCredentialRule
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "PVE Read #{unique}",
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

    assert {:ok, before_config} = MapperCompiler.compile(partition, agent_id, actor: actor)
    before_job = compiled_job(before_config, job_name)
    assert before_job["options"]["proxmox_candidate_probe_enabled"] == "true"

    Repo.query!(
      "ALTER TABLE platform.network_credential_rules RENAME TO _network_credential_rules_hidden"
    )

    try do
      assert {:error, _} = MapperCompiler.compile(partition, agent_id, actor: actor)
    after
      Repo.query!(
        "ALTER TABLE platform._network_credential_rules_hidden RENAME TO network_credential_rules"
      )
    end

    assert {:ok, after_config} = MapperCompiler.compile(partition, agent_id, actor: actor)
    after_job = compiled_job(after_config, job_name)
    assert after_job["options"]["proxmox_candidate_probe_enabled"] == "true"
  end

  defp create_mapper_collector(suffix, actor) do
    hostname = "collector-#{suffix}.example.com"

    device =
      Device
      |> Ash.Changeset.for_create(
        :create,
        %{
          uid: "sr:" <> Ash.UUID.generate(),
          hostname: hostname,
          ip: "192.0.2.10",
          type_id: 10,
          created_time: DateTime.utc_now(),
          modified_time: DateTime.utc_now()
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Example collector profile #{suffix}",
        enabled: true,
        target_query: ~s(in:devices hostname:"#{hostname}"),
        community: "example-fallback"
      },
      actor: actor
    )
    |> Ash.create!(actor: actor)

    device
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

  defp mapper_job_fixture(name, partition, mode, secret_id, seeds, actor) do
    job =
      MapperJob
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: name,
          partition: partition,
          discovery_mode: mode,
          discovery_type: :full,
          snmp_credential_secret_id: secret_id
        },
        actor: actor
      )
      |> Ash.create!(actor: actor)

    for seed <- seeds do
      MapperSeed
      |> Ash.Changeset.for_create(:create, %{mapper_job_id: job.id, seed: seed}, actor: actor)
      |> Ash.create!(actor: actor)
    end

    job
  end

  defp default_profile_fixture(name, community, actor) do
    SNMPProfile
    |> Ash.Changeset.for_create(
      :create,
      %{name: name, enabled: true, version: :v2c, community: community},
      actor: actor
    )
    |> Ash.create!(actor: actor)
    |> Ash.Changeset.for_update(:set_as_default, %{}, actor: actor)
    |> Ash.update!(actor: actor)
  end

  defp base_communities(partition, agent_id, jobs, actor) do
    {:ok, config} = MapperCompiler.compile(partition, agent_id, actor: actor)
    Enum.map(jobs, &compiled_job(config, &1.name)["credentials"]["community"])
  end

  defp compiled_job(config, job_name) do
    Enum.find(config["scheduled_jobs"], fn scheduled_job ->
      scheduled_job["name"] == job_name
    end)
  end
end
