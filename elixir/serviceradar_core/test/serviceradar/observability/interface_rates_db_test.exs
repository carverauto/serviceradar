defmodule ServiceRadar.Observability.InterfaceRatesDbTest do
  @moduledoc """
  Executes the shared typed SRQL compiler against migrated scratch CNPG tables.
  Every identity, counter and timestamp here is invented independently.
  """
  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Observability.SRQLRunner
  alias ServiceRadar.Repo

  @moduletag :integration
  @time ~U[2001-02-03 04:05:00Z]

  setup do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(previous, :cutover_datasets, [])
    )

    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)
    :ok
  end

  test "exact pairs prefer valid HC, fall back from invalid HC, and preserve measured zero and sample time" do
    pair_a = {"sr:rate-alpha", 7}
    pair_b = {"sr:rate-beta", 11}
    missing = {"sr:rate-gamma", 9}
    counter(pair_a, "ifInOctets", 32, [100, 700])
    counter(pair_a, "ifHCInOctets", 64, [1_000, 1_100])
    counter(pair_b, "ifHCInOctets", 64, [100, 50])
    counter(pair_b, "ifInOctets", 32, [500, 500])
    counter({elem(pair_a, 0), 11}, "ifHCInOctets", 64, [0, 90_000])
    counter({elem(pair_b, 0), 7}, "ifHCInOctets", 64, [0, 70_000])

    rows = rates([pair_a, pair_b, missing])

    assert MapSet.new(rows, &{&1["device_id"], &1["if_index"]}) ==
             MapSet.new([pair_a, pair_b, missing])

    assert %{"status" => "measured", "rate" => 10.0, "metric_name" => "ifHCInOctets"} =
             row(rows, pair_a)

    assert %{"status" => "measured", "rate" => 0.0, "metric_name" => "ifInOctets"} =
             row(rows, pair_b)

    assert %{"status" => "unknown", "rate" => nil, "observed_at" => nil} = row(rows, missing)
    assert DateTime.compare(row(rows, pair_a)["observed_at"], at(47)) == :eq
    assert DateTime.compare(row(rows, pair_a)["previous_observed_at"], at(37)) == :eq
  end

  test "explicit counter width and producer ceilings distinguish wrap from reset" do
    wrap = {"sr:rate-wrap", 15}
    reset = {"sr:rate-reset", 16}
    implausible = {"sr:rate-ceiling", 17}
    legacy = {"sr:rate-legacy", 18}
    invalid_width = {"sr:rate-invalid-width", 19}
    counter(wrap, "ifInOctets", 32, [4_294_967_290, 14])
    counter(reset, "ifHCInOctets", 64, [20, 5])
    counter(implausible, "ifInOctets", 32, [4_294_967_290, 14], ceiling: 1)
    counter(legacy, "ifInOctets", nil, [4_294_967_290, 14])
    counter(invalid_width, "ifInOctets", 32, [8_589_934_592, 1])

    rows = rates([wrap, reset, implausible, legacy, invalid_width])
    assert %{"status" => "measured", "rate" => 2.0} = row(rows, wrap)
    assert %{"status" => "measured", "rate" => 2.0} = row(rows, legacy)
    assert %{"status" => "unknown", "rate" => nil} = row(rows, reset)
    assert %{"status" => "unknown", "rate" => nil} = row(rows, implausible)
    assert %{"status" => "unknown", "rate" => nil} = row(rows, invalid_width)
  end

  test "physical series never borrow another producer's sample or collapse ambiguous producers" do
    isolated = {"sr:rate-isolated", 21}
    duplicate = {"sr:rate-duplicate", 22}
    sample(isolated, "ifHCInOctets", 64, 37, 100, producer: "one")
    sample(isolated, "ifHCInOctets", 64, 47, 900, producer: "two")
    counter(duplicate, "ifHCInOctets", 64, [0, 100], producer: "one")
    counter(duplicate, "ifHCInOctets", 64, [0, 900], producer: "two")

    rows = rates([isolated, duplicate])

    assert %{"status" => "unknown", "rate" => nil, "eligible_producers" => 0} =
             row(rows, isolated)

    assert %{"status" => "ambiguous", "rate" => nil, "eligible_producers" => 2} =
             row(rows, duplicate)
  end

  test "stale HC does not mask fresh legacy and stale samples are unknown" do
    fallback = {"sr:rate-fallback", 25}
    stale = {"sr:rate-stale", 26}
    counter(fallback, "ifHCInOctets", 64, [0, 900], seconds: [10, 20])
    counter(fallback, "ifInOctets", 32, [0, 30])
    counter(stale, "ifHCInOctets", 64, [0, 500], seconds: [10, 20])

    rows = rates([fallback, stale])

    assert %{"status" => "measured", "rate" => 3.0, "metric_name" => "ifInOctets"} =
             row(rows, fallback)

    assert %{"status" => "unknown", "rate" => nil} = row(rows, stale)
    assert DateTime.compare(row(rows, stale)["observed_at"], at(20)) == :eq
  end

  defp rates(pairs) do
    assert {:ok, rows} = SRQLRunner.interface_rates(pairs, at(0), at(60), fresh_after: at(30))
    assert length(rows) == length(pairs) * 8
    rows
  end

  defp row(rows, {device_id, if_index}) do
    Enum.find(
      rows,
      &(&1["device_id"] == device_id and &1["if_index"] == if_index and
          &1["direction"] == "in" and &1["family"] == "octets")
    )
  end

  defp counter(pair, metric, width, values, opts \\ []) do
    opts
    |> Keyword.get(:seconds, [37, 47])
    |> Enum.zip(values)
    |> Enum.each(fn {second, value} -> sample(pair, metric, width, second, value, opts) end)
  end

  defp sample({device_id, if_index}, metric, width, second, value, opts) do
    producer = Keyword.get(opts, :producer, "primary")
    series = "#{device_id}/#{if_index}/#{metric}/#{producer}"

    metadata =
      case Keyword.fetch(opts, :ceiling) do
        {:ok, ceiling} -> %{"max_counter_rate_per_second" => ceiling}
        :error -> %{}
      end

    Repo.query!(
      """
      INSERT INTO platform.timeseries_metrics
        (timestamp, gateway_id, agent_id, series_key, device_id, if_index,
         metric_type, metric_name, value, counter_width, metadata)
      VALUES ($1, $2, 'rate-agent.example.com', $3, $4, $5, 'snmp', $6, $7, $8, $9)
      """,
      [
        at(second),
        "rate-gateway-#{producer}.example.com",
        series,
        device_id,
        if_index,
        metric,
        value * 1.0,
        width,
        metadata
      ]
    )
  end

  defp at(seconds), do: DateTime.add(@time, seconds, :second)
end
