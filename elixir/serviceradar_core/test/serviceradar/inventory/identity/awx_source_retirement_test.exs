defmodule ServiceRadar.Inventory.Identity.AwxSourceRetirementTest do
  @moduledoc """
  Integration coverage for AWX source retirement: a complete AWX observation that no longer
  reports a host retires the AWX source of the host's record, a partial observation retires
  nothing, a record with another source loses only its AWX source, and a record keyed by the
  pre-v2 AWX identity is retired once the host's v2 record exists.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Inventory.DeviceDiscoveryIngestor
  alias ServiceRadar.Inventory.DeviceIdentifier
  alias ServiceRadar.Inventory.HypervisorEnrichmentIngestor
  alias ServiceRadar.Inventory.Identity.AwxSourceRetirement
  alias ServiceRadar.Inventory.Identity.AwxSourceRetirementWorker
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  @actor SystemActor.system(:awx_source_retirement_test)
  @fingerprint "sha256:2222222222222222222222222222222222222222222222222222222222222222"

  @settings %{
    source_retirement_enabled: true,
    source_retirement_min_absence_hours: 24,
    source_retirement_max_fraction: 1.0,
    source_retirement_guard_override: false
  }

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    %{controller: controller_fixture()}
  end

  test "a complete observation without a host retires its record; a partial one retires nothing",
       %{controller: controller} do
    # Both hosts reported by a partial observation only: nothing proves either gone.
    assert :ok = ingest(controller, 10, [10, 11], complete: false)
    kept = record_of(controller, 10)
    absent = record_of(controller, 11)
    assert retirement_jobs(controller) == 0

    assert {:ok, %{status: :incomplete_observation}} = run(controller, hours: 25)
    assert live_unmarked?(absent)
    assert holds_v2?(absent, controller, 11)

    assert :ok = ingest(controller, 20, [10])
    assert retirement_jobs(controller) == 1

    # A later partial observation is the controller's latest: it proves nothing either.
    assert :ok = ingest(controller, 25, [10], complete: false)
    assert {:ok, %{status: :incomplete_observation}} = run(controller, hours: 25)
    assert live_unmarked?(absent)

    assert :ok = ingest(controller, 30, [10])

    # Reported moments ago: not yet unreported for the minimum absence.
    assert {:ok, %{retired: 0}} = run(controller, hours: 0)
    assert live_unmarked?(absent)

    assert {:ok, %{devices: 1, marked: 1}} = run(controller, hours: 25)

    assert source_retired?(absent)
    refute holds_v2?(absent, controller, 11)
    assert archived?(absent, v2(controller, 11))
    assert retirement_decision?(absent, v2(controller, 11))

    assert live_unmarked?(kept)
    assert holds_v2?(kept, controller, 10)
  end

  test "a record with another source loses only its AWX source", %{controller: controller} do
    assert :ok = ingest(controller, 10, [10, 11])
    shared = record_of(controller, 11)

    Repo.query!(
      "UPDATE platform.ocsf_devices SET discovery_sources = discovery_sources || ARRAY['sweep'] WHERE uid = $1",
      [shared]
    )

    assert :ok = ingest(controller, 20, [10])
    assert {:ok, %{devices: 1, marked: 0, stripped: 1}} = run(controller, hours: 25)

    assert live_unmarked?(shared)
    refute holds_v2?(shared, controller, 11)

    %{rows: [[sources, metadata]]} =
      Repo.query!(
        "SELECT discovery_sources, metadata FROM platform.ocsf_devices WHERE uid = $1",
        [shared]
      )

    assert sources == ["sweep"]
    refute Map.has_key?(metadata, "awx")
    refute Map.has_key?(metadata, "integration_id")
  end

  test "a record keyed by the pre-v2 identity is retired once the v2 record exists",
       %{controller: controller} do
    assert :ok = ingest(controller, 10, [10])
    current = record_of(controller, 10)
    legacy = legacy_record(controller, 10)

    assert {:ok, %{devices: 1, marked: 1}} = run(controller, hours: 25)

    assert source_retired?(legacy)
    assert archived?(legacy, "awx:host:host10.example.com")
    assert live_unmarked?(current)
    assert holds_v2?(current, controller, 10)
  end

  test "a record another source keeps fresh loses its AWX source on its membership's clock",
       %{controller: controller} do
    assert :ok = ingest(controller, 10, [10, 11])
    shared = record_of(controller, 11)

    # Linked by metadata alone, with no AWX id row, and seen by a sweep at the pass's own time.
    Repo.query!(
      "DELETE FROM platform.device_identifiers WHERE device_id = $1 AND identifier_type = 'integration_id'",
      [shared]
    )

    Repo.query!(
      """
      UPDATE platform.ocsf_devices
      SET discovery_sources = discovery_sources || ARRAY['sweep'], last_seen_time = $2
      WHERE uid = $1
      """,
      [shared, DateTime.utc_now() |> DateTime.shift(hour: 25) |> DateTime.to_naive()]
    )

    assert :ok = ingest(controller, 20, [10])
    assert {:ok, %{devices: 1, marked: 0, stripped: 1}} = run(controller, hours: 25)

    assert live_unmarked?(shared)

    %{rows: [[sources, metadata]]} =
      Repo.query!(
        "SELECT discovery_sources, metadata FROM platform.ocsf_devices WHERE uid = $1",
        [shared]
      )

    assert sources == ["sweep"]
    refute Map.has_key?(metadata, "awx")
  end

  test "Proxmox enrichment does not adopt a source_retired record by address, MAC or name",
       %{controller: controller} do
    assert :ok = ingest(controller, 10, [10, 11])
    retired = record_of(controller, 11)
    assert :ok = ingest(controller, 20, [10])
    assert {:ok, %{marked: 1}} = run(controller, hours: 25)
    assert source_retired?(retired)

    suffix = System.unique_integer([:positive])
    host_ref = "testhv:node:pve-retired-#{suffix}"
    # One guest carries the record's address and MAC; the other only shares its hostname.
    guest_ref = "testhv:guest:pve-retired-#{suffix}:qemu:311"
    named_ref = "testhv:guest:pve-retired-#{suffix}:qemu:312"

    payload = %{
      "details" => %{
        "schema" => "serviceradar.hypervisor_enrichment.v1",
        "provider" => "testhv",
        "hosts" => [
          %{
            "provider_ref" => host_ref,
            "name" => "pve-retired-#{suffix}",
            "status" => "online",
            "metadata" => %{"ip" => "203.0.113.200"}
          }
        ],
        "guests" => [
          %{
            "provider_ref" => guest_ref,
            "host_provider_ref" => host_ref,
            "name" => "vm311-#{suffix}.example.com",
            "guest_type" => "vm",
            "vmid" => 311,
            "status" => "running"
          },
          %{
            "provider_ref" => named_ref,
            "host_provider_ref" => host_ref,
            "name" => "host11.example.com",
            "guest_type" => "vm",
            "vmid" => 312,
            "status" => "running"
          }
        ],
        "network_interfaces" => [
          %{
            "provider_ref" => "#{guest_ref}:net0",
            "host_provider_ref" => host_ref,
            "guest_provider_ref" => guest_ref,
            "name" => "net0",
            "mac_address" => mac(11),
            "ip_addresses" => ["203.0.113.11/24"],
            "source" => "qemu_agent",
            "metadata" => %{"partition" => "default"}
          }
        ]
      }
    }

    assert :ok = HypervisorEnrichmentIngestor.ingest(payload, %{}, actor: @actor)

    %{rows: guest_devices} =
      Repo.query!(
        "SELECT device_uid FROM platform.virtualization_guests WHERE provider = 'testhv' AND provider_ref = ANY ($1)",
        [[guest_ref, named_ref]]
      )

    assert length(guest_devices) == 2
    refute [retired] in guest_devices
    assert source_retired?(retired)
  end

  test "a complete observation that reports no host is refused by the mass guard",
       %{controller: controller} do
    assert :ok = ingest(controller, 10, [10, 11])
    assert :ok = ingest(controller, 20, [])

    assert {:error, {:mass_retirement_refused, %{candidates: 2, live: 2}}} =
             run(controller, hours: 25, max_fraction: 0.5)

    assert live_unmarked?(record_of(controller, 10))
    assert live_unmarked?(record_of(controller, 11))
  end

  defp run(controller, opts) do
    settings = %{@settings | source_retirement_max_fraction: opts[:max_fraction] || 1.0}

    AwxSourceRetirement.run(controller.id,
      settings: settings,
      actor: @actor,
      now: DateTime.shift(DateTime.utc_now(), hour: opts[:hours])
    )
  end

  defp ingest(controller, generation, host_ids, opts \\ []) do
    DeviceDiscoveryIngestor.ingest(payload(controller, generation, host_ids, opts), %{},
      actor: @actor
    )
  end

  defp payload(controller, generation, host_ids, opts) do
    %{
      "device_discovery" => [
        %{
          "schema" => "serviceradar.device_discovery.v1",
          "source" => "awx",
          "observed_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "collection_id" => "synthetic-awx-#{generation}",
          "metadata" => %{
            "controller_id" => controller.id,
            "source_generation" => generation,
            "source_fingerprint" => @fingerprint,
            "complete" => Keyword.get(opts, :complete, true)
          },
          "devices" => Enum.map(host_ids, &host(controller, &1))
        }
      ]
    }
  end

  defp host(controller, host_id) do
    ip = "203.0.113.#{host_id}"

    %{
      "hostname" => "host#{host_id}.example.com",
      "ip" => ip,
      "mac" => mac(host_id),
      "is_available" => true,
      "metadata" => %{
        "integration_id" => v2(controller, host_id),
        "legacy_integration_ids" => ["awx:host:host#{host_id}.example.com"],
        "awx" => %{
          "controller_id" => controller.id,
          "inventory_id" => 7,
          "host_id" => host_id,
          "host_name" => "host#{host_id}.example.com",
          "inventory_name" => "Example inventory",
          "ansible_host" => ip
        }
      }
    }
  end

  # A record written under the pre-v2 identity, last reported months ago, beside the v2 record.
  defp legacy_record(controller, host_id) do
    uid = "sr:" <> Ecto.UUID.generate()
    long_ago = DateTime.utc_now() |> DateTime.shift(day: -90) |> DateTime.to_naive()
    name = "host#{host_id}.example.com"

    Repo.query!(
      """
      INSERT INTO platform.ocsf_devices
        (uid, hostname, discovery_sources, metadata, first_seen_time, last_seen_time)
      VALUES ($1, $2, ARRAY['awx'], $3, $4, $4)
      """,
      [
        uid,
        name,
        %{
          "integration_id" => "awx:host:" <> name,
          "awx" => %{"controller_id" => controller.id, "inventory_id" => 7, "host_id" => host_id}
        },
        long_ago
      ]
    )

    {:ok, _identifier} =
      DeviceIdentifier
      |> Ash.Changeset.for_create(:register, %{
        device_id: uid,
        identifier_type: :integration_id,
        identifier_value: "awx:host:" <> name,
        partition: "default",
        confidence: :strong,
        source: "test"
      })
      |> Ash.create(actor: @actor)

    Repo.query!(
      "UPDATE platform.device_identifiers SET first_seen = $2, last_seen = $2 WHERE device_id = $1",
      [uid, long_ago]
    )

    uid
  end

  defp controller_fixture do
    id = Ash.UUIDv7.generate()

    Seed.seed!(Controller, %{
      id: id,
      name: "Synthetic controller #{id}",
      base_url: "https://controller.example.com",
      agent_id: "synthetic-agent-#{id}",
      credential_secret_id: CredentialIntegrationFixtures.secret_id!()
    })
  end

  defp retirement_jobs(controller) do
    worker = Oban.Worker.to_string(AwxSourceRetirementWorker)

    from(job in Oban.Job, where: job.worker == ^worker)
    |> Repo.all()
    |> Enum.count(&(&1.args["controller_id"] == controller.id))
  end

  # A locally administered address, invented per host.
  defp mac(host_id),
    do: "02:00:00:00:00:#{host_id |> Integer.to_string(16) |> String.pad_leading(2, "0")}"

  defp v2(controller, host_id), do: "awx:v2:#{controller.id}:host:#{host_id}"

  defp record_of(controller, host_id) do
    %{rows: [[uid]]} =
      Repo.query!(
        "SELECT device_id FROM platform.device_identifiers WHERE identifier_type = 'integration_id' AND identifier_value = $1",
        [v2(controller, host_id)]
      )

    uid
  end

  defp holds_v2?(uid, controller, host_id) do
    Repo.query!(
      "SELECT 1 FROM platform.device_identifiers WHERE device_id = $1 AND identifier_type = 'integration_id' AND identifier_value = $2",
      [uid, v2(controller, host_id)]
    ).num_rows == 1
  end

  defp archived?(uid, value) do
    Repo.query!(
      "SELECT 1 FROM platform.device_identifier_archive WHERE device_id = $1 AND identifier_value = $2 AND archive_reason = 'source_absent'",
      [uid, value]
    ).num_rows == 1
  end

  defp retirement_decision?(uid, value) do
    Repo.query!(
      "SELECT 1 FROM platform.identity_decisions WHERE decision_kind = 'source_id_retired' AND subject = $2 AND $1 = ANY (device_uids)",
      [uid, value]
    ).num_rows == 1
  end

  defp live_unmarked?(uid) do
    Repo.query!(
      "SELECT 1 FROM platform.ocsf_devices WHERE uid = $1 AND deleted_at IS NULL AND source_retired_at IS NULL",
      [uid]
    ).num_rows == 1
  end

  defp source_retired?(uid) do
    Repo.query!(
      "SELECT 1 FROM platform.ocsf_devices WHERE uid = $1 AND deleted_at IS NULL AND source_retired_at IS NOT NULL",
      [uid]
    ).num_rows == 1
  end
end
