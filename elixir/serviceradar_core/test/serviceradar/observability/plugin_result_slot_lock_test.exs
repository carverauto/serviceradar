defmodule ServiceRadar.Observability.PluginResultSlotLockTest do
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Observability.PluginResultIngestor
  alias ServiceRadar.Observability.PluginResultSlot
  alias ServiceRadar.Repo

  @moduletag sandbox: :unboxed
  @slot_bucket_width_microseconds 257

  setup do
    previous_handlers = Application.get_env(:serviceradar_core, :plugin_result_handlers)
    Application.put_env(:serviceradar_core, :plugin_result_handlers, [])

    suffix = System.unique_integer([:positive])
    agent_prefix = "slot-lock-agent-#{suffix}"

    status = %{
      source: "plugin-result",
      agent_id: agent_prefix,
      gateway_id: "slot-lock-gateway-#{suffix}",
      partition: "default",
      service_type: "plugin",
      service_name: "slot-lock-service-#{suffix}"
    }

    observed_at =
      DateTime.utc_now()
      |> DateTime.add(-30, :second)
      |> DateTime.truncate(:microsecond)

    payload = %{
      "status" => "OK",
      "summary" => "slot lock result",
      "observed_at" => DateTime.to_iso8601(observed_at)
    }

    on_exit(fn ->
      restore_handlers(previous_handlers)

      Repo.query!("DELETE FROM platform.service_state WHERE agent_id LIKE $1", [
        "#{agent_prefix}%"
      ])

      Repo.query!("DELETE FROM platform.service_status WHERE agent_id LIKE $1", [
        "#{agent_prefix}%"
      ])
    end)

    {:ok, payload: payload, status: status, observed_at: observed_at}
  end

  test "new writers remain serialized with the legacy global slot lock", context do
    %{payload: payload, status: status} = context
    parent = self()

    legacy_lock = Jason.encode!(["service-status-slots", status.gateway_id, status.service_name])
    holder = hold_advisory_lock(legacy_lock, parent, :legacy_lock_held, :release_legacy_lock)
    assert_receive :legacy_lock_held, 5_000

    ingest =
      Task.async(fn ->
        result = PluginResultIngestor.ingest(payload, status)
        send(parent, {:legacy_locked_ingest_done, result})
        result
      end)

    refute_receive {:legacy_locked_ingest_done, _result}, 200
    send(holder.pid, :release_legacy_lock)

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert :ok = Task.await(ingest, 5_000)
  end

  test "a busy preferred bucket spills without blocking distant identities", context do
    %{payload: payload, status: near_status, observed_at: observed_at} = context
    far_status = %{near_status | agent_id: "#{near_status.agent_id}-far", partition: "far"}
    far_observed_at = DateTime.add(observed_at, 1_028, :microsecond)
    far_payload = Map.put(payload, "observed_at", DateTime.to_iso8601(far_observed_at))
    parent = self()

    preferred_base =
      near_status
      |> Map.put(:timestamp, observed_at)
      |> Map.put(:details, nil)
      |> PluginResultSlot.block_base(0)

    held_bucket =
      div(DateTime.to_unix(preferred_base, :microsecond), @slot_bucket_width_microseconds)

    bucket_lock =
      Jason.encode!([
        "service-status-slots-v2",
        near_status.gateway_id,
        near_status.service_name,
        held_bucket
      ])

    holder = hold_advisory_lock(bucket_lock, parent, :bucket_lock_held, :release_bucket_lock)
    assert_receive :bucket_lock_held, 5_000

    near_ingest =
      Task.async(fn ->
        result = PluginResultIngestor.ingest(payload, near_status)
        send(parent, {:near_ingest_done, result})
        result
      end)

    far_ingest =
      Task.async(fn ->
        result = PluginResultIngestor.ingest(far_payload, far_status)
        send(parent, {:far_ingest_done, result})
        result
      end)

    assert_receive {:far_ingest_done, :ok}, 5_000
    assert_receive {:near_ingest_done, :ok}, 5_000
    assert :ok = Task.await(far_ingest, 5_000)
    assert :ok = Task.await(near_ingest, 5_000)

    assert [[near_base, details]] =
             Repo.query!(
               """
               SELECT timestamp, details
               FROM platform.service_status
               WHERE agent_id = $1
                 AND gateway_id = $2
                 AND service_name = $3
               """,
               [near_status.agent_id, near_status.gateway_id, near_status.service_name]
             ).rows

    refute near_base == preferred_base

    assert get_in(Jason.decode!(details), ["_serviceradar_plugin_result", "slot"]) == %{
             "base_timestamp" => DateTime.to_iso8601(near_base),
             "version" => 1,
             "width_microseconds" => @slot_bucket_width_microseconds
           }

    send(holder.pid, :release_bucket_lock)
    assert {:ok, :ok} = Task.await(holder, 5_000)
  end

  defp hold_advisory_lock(lock_identity, parent, held_message, release_message) do
    Task.async(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_identity])
        send(parent, held_message)

        receive do
          ^release_message -> :ok
        after
          5_000 -> raise "timed out waiting to release advisory lock"
        end
      end)
    end)
  end

  defp restore_handlers(nil),
    do: Application.delete_env(:serviceradar_core, :plugin_result_handlers)

  defp restore_handlers(handlers),
    do: Application.put_env(:serviceradar_core, :plugin_result_handlers, handlers)
end
