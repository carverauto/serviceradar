defmodule ServiceRadar.SweepJobs.Ingestion.WorkerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.SweepJobs.Ingestion.Worker

  @group :sweep_ingestion_worker_test

  defmodule Processor do
    @moduledoc false

    def process(%{outcome: :raise}, _test_pid), do: raise("boom")

    def process(status, test_pid) do
      send(test_pid, {:processed, status.seq})
      status.outcome
    end
  end

  setup do
    scope = :"sweep_ingestion_worker_scope_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: scope, start: {:pg, :start_link, [scope]}})

    worker =
      start_supervised!(
        {Worker, scope: scope, group: @group, processor: {Processor, :process, [self()]}}
      )

    %{scope: scope, worker: worker}
  end

  test "joins the ingestion group", ctx do
    assert ctx.worker in :pg.get_members(ctx.scope, @group)
  end

  test "processes chunks in order and acknowledges each one", ctx do
    for seq <- 1..3 do
      send(ctx.worker, {:sweep_ingest, self(), :key, %{seq: seq, outcome: :ok}})
    end

    for seq <- 1..3 do
      assert_receive {:processed, ^seq}
      assert_receive {:sweep_ingested, :key, worker}
      assert worker == ctx.worker
    end
  end

  test "acknowledges failed and raising chunks and keeps running", ctx do
    send(ctx.worker, {:sweep_ingest, self(), :key, %{seq: 1, outcome: {:error, :bad}}})
    assert_receive {:processed, 1}
    assert_receive {:sweep_ingested, :key, _}

    send(ctx.worker, {:sweep_ingest, self(), :key, %{seq: 2, outcome: :raise}})
    assert_receive {:sweep_ingested, :key, _}

    send(ctx.worker, {:sweep_ingest, self(), :key, %{seq: 3, outcome: :ok}})
    assert_receive {:processed, 3}
    assert Process.alive?(ctx.worker)
  end
end
