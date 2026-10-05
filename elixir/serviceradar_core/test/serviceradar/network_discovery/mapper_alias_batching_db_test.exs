defmodule ServiceRadar.NetworkDiscovery.MapperAliasBatchingDbTest do
  @moduledoc """
  Mapper alias updates read device and alias state once per batch, not once per
  device or per candidate address, and still decide exactly what the one-at-a-time
  path decided.
  """

  use ServiceRadar.DataCase, async: false

  import Ecto.Query

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.DeviceAliasState
  alias ServiceRadar.Inventory.Device
  alias ServiceRadar.NetworkDiscovery.MapperResultsIngestor
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  @role %{role: "switch_l2", confidence: 80, source: "mapper_interfaces"}

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    {:ok, actor: SystemActor.system(:mapper_alias_batching_db_test)}
  end

  test "role inference for a batch reads device metadata once", ctx do
    devices = for n <- 1..20, do: device!(ctx, n, role_metadata(@role))
    updates = Enum.map(devices, &%{device_id: &1.uid, role: @role})

    assert {:ok, queries} =
             counting_queries(fn ->
               MapperResultsIngestor.persist_role_metadata(updates, ctx.actor)
             end)

    assert queries <= 1, "expected one metadata read for 20 unchanged devices, got #{queries}"
  end

  test "role inference writes only the devices whose role changed", ctx do
    unchanged = device!(ctx, 1, Map.merge(%{"keep" => "yes"}, role_metadata(@role)))
    changed = device!(ctx, 2, %{"keep" => "yes", "device_role" => "host"})

    :ok =
      MapperResultsIngestor.persist_role_metadata(
        [
          %{device_id: unchanged.uid, role: @role},
          %{device_id: changed.uid, role: @role},
          %{device_id: "sr:absent", role: @role}
        ],
        ctx.actor
      )

    assert metadata(changed.uid) == Map.merge(%{"keep" => "yes"}, role_metadata(@role))
    assert metadata(unchanged.uid) == Map.merge(%{"keep" => "yes"}, role_metadata(@role))
  end

  test "candidate addresses that are already known are resolved in a few queries", ctx do
    holders = for n <- 1..10, do: device!(ctx, n, %{})
    alias_owner = device!(ctx, 99, %{})

    aliased_ips =
      for n <- 1..10 do
        ip = ip(ctx, 200 + n)
        alias!(ctx, alias_owner.uid, ip, "default")
        ip
      end

    entries =
      Enum.map(holders, &{&1.ip, "default", "sr:source"}) ++
        Enum.map(aliased_ips, &{&1, "default", "sr:source"})

    assert {:ok, queries} =
             counting_queries(fn ->
               MapperResultsIngestor.ensure_candidate_devices(entries, ctx.actor)
             end)

    assert queries <= 4, "expected batched lookups for 20 known addresses, got #{queries}"
    assert devices_at(aliased_ips) == []
  end

  test "an unknown address named in two partitions is seeded once", ctx do
    ip = ip(ctx, 150)

    :ok =
      MapperResultsIngestor.ensure_candidate_devices(
        [{ip, "default", "sr:first-source"}, {ip, "other", "sr:second-source"}],
        ctx.actor
      )

    assert [%{metadata: %{"candidate_from_device_id" => "sr:first-source"}}] = devices_at([ip])
  end

  test "an alias in another partition does not stand in for the address", ctx do
    ip = ip(ctx, 160)
    owner = device!(ctx, 98, %{})
    alias!(ctx, owner.uid, ip, "other")

    :ok =
      MapperResultsIngestor.ensure_candidate_devices([{ip, "default", "sr:source"}], ctx.actor)

    assert [_seeded] = devices_at([ip])
  end

  test "a failing batched alias read falls back to per-IP lookup and suppresses creation", ctx do
    ip = ip(ctx, 170)
    owner = device!(ctx, 97, %{})
    alias!(ctx, owner.uid, ip, "default")

    assert {:ok, uid} =
             MapperResultsIngestor.resolve_alias_device_uid(
               ip,
               "default",
               {:error, :simulated_batch_failure},
               ctx.actor
             )

    assert uid == owner.uid
    assert devices_at([ip]) == []
  end

  defp role_metadata(role) do
    %{
      "device_role" => role.role,
      "device_role_confidence" => role.confidence,
      "device_role_source" => role.source
    }
  end

  # Synthetic addresses from the 192.0.2.0/24 documentation range.
  defp ip(_ctx, n), do: "192.0.2.#{n}"

  defp device!(ctx, n, metadata) do
    Device
    |> Ash.Changeset.for_create(:create, %{
      uid: "sr:" <> Ecto.UUID.generate(),
      ip: ip(ctx, n),
      metadata: metadata
    })
    |> Ash.create!(actor: ctx.actor)
  end

  defp alias!(ctx, device_uid, ip, partition) do
    {:ok, _alias} =
      DeviceAliasState.create_detected(
        %{
          device_id: device_uid,
          partition: partition,
          alias_type: :ip,
          alias_value: ip,
          metadata: %{"source" => "test"}
        },
        actor: ctx.actor
      )
  end

  defp metadata(uid), do: Repo.one!(from(d in Device, where: d.uid == ^uid, select: d.metadata))

  defp devices_at(ips),
    do: Repo.all(from(d in Device, where: d.ip in ^ips and is_nil(d.deleted_at)))

  defp counting_queries(fun) do
    handler_id = "mapper-alias-batching-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:service_radar, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :repo_query)
        end,
        nil
      )

    try do
      :ok = fun.()
      {:ok, drain(0)}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain(count) do
    receive do
      :repo_query -> drain(count + 1)
    after
      0 -> count
    end
  end
end
