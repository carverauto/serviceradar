defmodule ServiceRadar.WorkloadIdentitySkipGuardTest do
  @moduledoc """
  Pure (DB-free) unit tests for the workload-identity change-detection skip-guard
  (fj #33). These exercise the fingerprint, the pure `skip_decision/4`, and the
  `guarded_write/3` seam with a recording writer stub -- no Repo, no integration
  tag, so they run in the default `mix test`.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.WorkloadIdentity

  # ---------------------------------------------------------------------------
  # Fingerprint stability (the LANDMINE proof): identical identity content with a
  # DIFFERENT observed_at must produce the SAME fingerprint, otherwise the guard
  # never skips.
  # ---------------------------------------------------------------------------

  test "identical snapshot content with different observed_at -> same fingerprint" do
    status = status_for(unique_partition())

    {:ok, rows_a} = snapshot_rows(status, observed_at_unix_nano: 1_700_000_000_000_000_000)
    {:ok, rows_b} = snapshot_rows(status, observed_at_unix_nano: 1_700_000_999_000_000_000)

    # Prove the volatile field genuinely differs in the built rows ...
    refute hd(rows_a).observed_at == hd(rows_b).observed_at

    # ... yet the identity-content fingerprint is identical, so the guard can skip.
    assert WorkloadIdentity.rows_fingerprint(rows_a) ==
             WorkloadIdentity.rows_fingerprint(rows_b)
  end

  test "fingerprint is independent of row order (sorted by container_id)" do
    status = status_for(unique_partition())
    {:ok, rows} = snapshot_rows(status, identities: [identity("c-a"), identity("c-b")])

    assert WorkloadIdentity.rows_fingerprint(rows) ==
             WorkloadIdentity.rows_fingerprint(Enum.reverse(rows))
  end

  test "changed identity content -> different fingerprint" do
    status = status_for(unique_partition())
    {:ok, rows_a} = snapshot_rows(status, image: "redis:7")
    {:ok, rows_b} = snapshot_rows(status, image: "redis:8")

    refute WorkloadIdentity.rows_fingerprint(rows_a) ==
             WorkloadIdentity.rows_fingerprint(rows_b)
  end

  # ---------------------------------------------------------------------------
  # Pure skip_decision/4
  # ---------------------------------------------------------------------------

  test "skip_decision/4: cold start, unchanged-within-heartbeat, expiry, and change" do
    # cold start (nil stored) -> proceed
    assert :proceed = WorkloadIdentity.skip_decision(123, nil, 1_000, 0)
    # unchanged + within heartbeat -> skip
    assert :skip = WorkloadIdentity.skip_decision(123, {123, 0}, 1_000, 500)
    # unchanged + heartbeat elapsed -> proceed
    assert :proceed = WorkloadIdentity.skip_decision(123, {123, 0}, 1_000, 1_000)
    # changed fingerprint within heartbeat -> proceed
    assert :proceed = WorkloadIdentity.skip_decision(999, {123, 0}, 1_000, 10)
  end

  # ---------------------------------------------------------------------------
  # guarded_write/3 with a recording writer stub
  # ---------------------------------------------------------------------------

  test "(1) identical snapshot within heartbeat SKIPS the second write" do
    status = status_for(unique_partition())
    {:ok, rows} = snapshot_rows(status)
    {writer, _} = recording_writer()

    opts = [writer: writer, heartbeat_ms: 60_000]

    assert :ok = WorkloadIdentity.guarded_write(rows, status, Keyword.put(opts, :now_ms, 0))
    assert_received {:wrote, ^rows}

    # 30s later (< 60s heartbeat), identical content -> SKIP, no DB work.
    assert :ok = WorkloadIdentity.guarded_write(rows, status, Keyword.put(opts, :now_ms, 30_000))
    refute_received {:wrote, _}
  end

  test "(2) changed identity WRITES again even within the heartbeat" do
    status = status_for(unique_partition())
    {:ok, rows_a} = snapshot_rows(status, image: "redis:7")
    {:ok, rows_b} = snapshot_rows(status, image: "redis:8")
    {writer, _} = recording_writer()

    opts = [writer: writer, heartbeat_ms: 60_000]

    assert :ok = WorkloadIdentity.guarded_write(rows_a, status, Keyword.put(opts, :now_ms, 0))
    assert_received {:wrote, _}

    # 1s later but content changed -> WRITE despite being within the heartbeat.
    assert :ok = WorkloadIdentity.guarded_write(rows_b, status, Keyword.put(opts, :now_ms, 1_000))
    assert_received {:wrote, ^rows_b}
  end

  test "(3) heartbeat expiry WRITES again even when content is unchanged" do
    status = status_for(unique_partition())
    {:ok, rows} = snapshot_rows(status)
    {writer, _} = recording_writer()

    opts = [writer: writer, heartbeat_ms: 60_000]

    assert :ok = WorkloadIdentity.guarded_write(rows, status, Keyword.put(opts, :now_ms, 0))
    assert_received {:wrote, _}

    # 60s later (>= heartbeat), identical content -> WRITE (refresh observed_at).
    assert :ok = WorkloadIdentity.guarded_write(rows, status, Keyword.put(opts, :now_ms, 60_000))
    assert_received {:wrote, ^rows}
  end

  test "(4) a guard exception FAILS OPEN and still writes" do
    status = status_for(unique_partition())
    {:ok, rows} = snapshot_rows(status)
    {writer, _} = recording_writer()

    boom = fn _rows -> raise "boom" end

    assert :ok =
             WorkloadIdentity.guarded_write(rows, status,
               writer: writer,
               fingerprint_fun: boom
             )

    assert_received {:wrote, ^rows}
  end

  test "a write error does NOT record the guard, so the next call retries" do
    status = status_for(unique_partition())
    {:ok, rows} = snapshot_rows(status)
    pid = self()

    failing = fn r ->
      send(pid, {:wrote, r})
      {:error, :boom}
    end

    opts = [heartbeat_ms: 60_000]

    assert {:error, :boom} =
             WorkloadIdentity.guarded_write(rows, status, [writer: failing, now_ms: 0] ++ opts)

    assert_received {:wrote, _}

    # Guard was NOT recorded (write failed), so an immediate retry must WRITE again.
    {ok_writer, _} = recording_writer()

    assert :ok =
             WorkloadIdentity.guarded_write(rows, status, [writer: ok_writer, now_ms: 1] ++ opts)

    assert_received {:wrote, ^rows}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp recording_writer do
    pid = self()

    writer = fn rows ->
      send(pid, {:wrote, rows})
      :ok
    end

    {writer, pid}
  end

  defp unique_partition, do: "wi-guard-#{System.unique_integer([:positive])}"

  defp status_for(partition) do
    %{
      message: snapshot_message([]),
      partition: partition,
      agent_id: "agent-#{partition}",
      gateway_id: "gateway-test"
    }
  end

  defp snapshot_rows(status, overrides \\ []) do
    WorkloadIdentity.snapshot_rows(%{status | message: snapshot_message(overrides)})
  end

  defp snapshot_message(overrides) do
    observed_at = Keyword.get(overrides, :observed_at_unix_nano, 1_700_000_000_000_000_000)

    identities =
      Keyword.get_lazy(overrides, :identities, fn ->
        [identity("container-redis", Keyword.get(overrides, :image, "redis:7"))]
      end)

    Jason.encode!(%{
      "observed_at_unix_nano" => observed_at,
      "enabled" => true,
      "identities" => identities
    })
  end

  defp identity(container_id, image \\ "redis:7") do
    %{
      "container_id" => container_id,
      "identity" => %{
        "container_id" => container_id,
        "pod_uid" => "pod-uid-#{container_id}",
        "pod_namespace" => "demo",
        "pod_name" => "redis-0",
        "container_name" => "redis",
        "image" => image,
        "runtime_source" => "Containerd",
        "confidence" => "High"
      }
    }
  end
end
