defmodule Palisade.RateLimit.ETSTest do
  use ExUnit.Case, async: true

  alias Palisade.RateLimit.ETS

  setup context do
    name = :"#{inspect(__MODULE__)}.#{context.test}"
    start_supervised!({ETS, Keyword.merge([name: name], context[:limiter] || [])})
    %{opts: [name: name]}
  end

  test "allows up to the limit, then denies with a retry delay", %{opts: opts} do
    assert {:allow, 2, reset} = ETS.check(:key, 3, 60_000, opts)
    assert reset in 1..60_000
    assert {:allow, 1, _} = ETS.check(:key, 3, 60_000, opts)
    assert {:allow, 0, _} = ETS.check(:key, 3, 60_000, opts)
    assert {:deny, retry_after} = ETS.check(:key, 3, 60_000, opts)
    assert retry_after >= 1
  end

  test "keys are counted separately", %{opts: opts} do
    assert {:allow, 0, _} = ETS.check(:a, 1, 60_000, opts)
    assert {:deny, _} = ETS.check(:a, 1, 60_000, opts)
    assert {:allow, 0, _} = ETS.check(:b, 1, 60_000, opts)
  end

  test "denied requests are not counted", %{opts: opts} do
    assert {:allow, 0, _} = ETS.check(:key, 1, 60_000, opts)

    for _ <- 1..5, do: assert({:deny, _} = ETS.check(:key, 1, 60_000, opts))

    [{_, 1, _}] = :ets.match_object(opts[:name], {{:key, :_, :_}, :_, :_})
  end

  test "a key may send again once its window slides past", %{opts: opts} do
    assert {:allow, 0, _} = ETS.check(:key, 1, 40, opts)
    assert {:deny, retry_after} = ETS.check(:key, 1, 40, opts)
    Process.sleep(retry_after + 5)
    assert {:allow, _, _} = ETS.check(:key, 1, 40, opts)
  end

  test "concurrent checks never admit more than the limit", %{opts: opts} do
    results =
      1..200
      |> Task.async_stream(fn _ -> ETS.check(:shared, 50, 60_000, opts) end, max_concurrency: 50)
      |> Enum.map(fn {:ok, result} -> elem(result, 0) end)

    assert Enum.count(results, &(&1 == :allow)) == 50
  end

  describe "table full" do
    @describetag limiter: [max_entries: 2]

    test "new keys are denied, tracked keys keep their own count", %{opts: opts} do
      assert {:allow, _, _} = ETS.check(:a, 10, 60_000, opts)
      assert {:allow, _, _} = ETS.check(:b, 10, 60_000, opts)

      assert {:deny, retry_after} = ETS.check(:c, 10, 60_000, opts)
      assert retry_after == 60_000

      assert {:allow, 8, _} = ETS.check(:a, 10, 60_000, opts)
    end
  end

  describe "sweeping" do
    @describetag limiter: [max_entries: 1, sweep_interval_ms: 10]

    test "expired rows are deleted, freeing room for new keys", %{opts: opts} do
      assert {:allow, _, _} = ETS.check(:a, 10, 5, opts)
      assert {:deny, _} = ETS.check(:b, 10, 60_000, opts)

      Process.sleep(40)

      assert {:allow, _, _} = ETS.check(:b, 10, 60_000, opts)
    end
  end

  test "a table that is not running raises with how to start it" do
    error =
      assert_raise ArgumentError, fn ->
        ETS.check(:key, 1, 1000, name: :palisade_missing_table)
      end

    assert error.message =~ "supervision tree"
  end

  test "start options are validated" do
    assert_raise ArgumentError, fn ->
      ETS.start_link(name: :palisade_bad_table, max_entries: 0)
    end
  end
end
