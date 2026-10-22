defmodule ServiceRadar.Inventory.ExposureTransitionRelayTest do
  @moduledoc """
  The outbox relay deletes a transition only after the stream acknowledged it,
  and publishes each one under its sequence as the JetStream message id.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Inventory.ExposureTransitionRelay
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  test "acknowledged transitions leave the outbox; a refused one stays and the stream is ensured" do
    unique = System.unique_integer([:positive])
    accepted_device = "sr:relay-accepted-#{unique}"
    refused_device = "sr:relay-refused-#{unique}"
    insert_actionable_assessment!(accepted_device, unique)
    insert_actionable_assessment!(refused_device, unique)
    parent = self()

    publish = fn subject, body, opts ->
      payload = Jason.decode!(body)

      if payload["device_uid"] in [accepted_device, refused_device],
        do: send(parent, {:published, subject, payload, opts[:msg_id]})

      if payload["device_uid"] == refused_device, do: {:error, :timeout}, else: :ok
    end

    ensure_stream = fn _opts ->
      send(parent, :stream_ensured)
      :ok
    end

    assert {:ok, %{relayed: relayed, failed: 1}} =
             ExposureTransitionRelay.relay_once(
               batch_size: 10_000,
               publish: publish,
               ensure_stream: ensure_stream
             )

    assert relayed >= 1
    assert_received :stream_ensured

    published =
      for _attempt <- 1..2, into: %{} do
        assert_received {:published, subject, payload, msg_id}
        {payload["device_uid"], {subject, payload, msg_id}}
      end

    for device_uid <- [accepted_device, refused_device] do
      {subject, payload, msg_id} = Map.fetch!(published, device_uid)
      assert subject == ExposureTransitionRelay.subject(device_uid)
      assert subject =~ ~r/^vulnerability\.assessment\.transitions\.([0-9]|1[0-5])$/
      assert payload["state"] == "active"
      assert msg_id == "exposure-transition-#{payload["transition_seq"]}"
    end

    assert outbox_devices([accepted_device, refused_device]) == [refused_device]
  end

  defp outbox_devices(device_uids) do
    Repo.all(
      from(o in "exposure_transition_outbox",
        where: o.device_uid in ^device_uids,
        select: o.device_uid
      ),
      prefix: "platform"
    )
  end

  defp insert_actionable_assessment!(device_uid, unique) do
    endpoint_package_ref = Ecto.UUID.dump!(Ecto.UUID.generate())
    now = ~N[2026-01-01 00:00:00]

    Repo.insert_all(
      "endpoint_packages",
      [
        %{
          id: endpoint_package_ref,
          coordinate_key: "relay-#{device_uid}",
          cpes: [],
          package_manager: "dpkg",
          name: "examplelib",
          version: "1.0.0",
          source_scope: "host",
          metadata: %{}
        }
      ],
      prefix: "platform"
    )

    Repo.insert_all(
      "endpoint_vulnerability_assessments",
      [
        %{
          device_uid: device_uid,
          package_identity_key: "pkgkey:relay:#{unique}",
          endpoint_package_ref: endpoint_package_ref,
          cve_id: "CVE-2024-0007",
          status: "active",
          assessment: "confirmed",
          disposition: "affected",
          applicability_reason: "synthetic",
          installed_version: "1.0.0",
          first_seen_at: now,
          last_seen_at: now
        }
      ],
      prefix: "platform"
    )
  end
end
