defmodule ServiceRadar.Observability.MtrMetricsIngestorRowsTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.MtrMetricsIngestor

  @moduletag :db_free

  @trace_id "3f2e1d0c-9b8a-4765-8432-10fedcba9876"
  @other_trace_id "0a1b2c3d-4e5f-4061-8728-394a5b6c7d8e"

  # Hops carry an AS already, so building rows performs no GeoIP lookup.
  defp payload(trace_id, hop_count \\ 3) do
    %{
      "results" => [
        %{
          "trace_uuid" => trace_id,
          "target" => "192.0.2.50",
          "timestamp" => 1_780_000_000,
          "trace" => %{
            "target_ip" => "192.0.2.50",
            "total_hops" => hop_count,
            "hops" =>
              for n <- 1..hop_count do
                %{
                  "hop_number" => n,
                  "addr" => "198.51.100.#{n}",
                  "asn" => %{"asn" => 64_496 + n},
                  "sent" => 3,
                  "received" => 3
                }
              end
          }
        }
      ]
    }
  end

  defp rows(payload) do
    {:ok, built} = MtrMetricsIngestor.rows(payload, %{agent_id: "agent-01"})
    built
  end

  describe "hop_id/2" do
    test "is the same id every time for the same trace and position" do
      assert MtrMetricsIngestor.hop_id(@trace_id, 0) == MtrMetricsIngestor.hop_id(@trace_id, 0)
    end

    test "differs across positions and across traces" do
      ids =
        for trace <- [@trace_id, @other_trace_id], index <- 0..9 do
          MtrMetricsIngestor.hop_id(trace, index)
        end

      assert length(Enum.uniq(ids)) == 20
    end

    test "is a valid RFC 9562 version 8 UUID" do
      id = MtrMetricsIngestor.hop_id(@trace_id, 4)

      assert {:ok, ^id} = Ecto.UUID.cast(id)
      assert String.at(id, 14) == "8"
      assert String.at(id, 19) in ~w(8 9 a b)
    end
  end

  describe "rows/2" do
    test "builds the trace and hop rows keyed by the trace uuid and hop position" do
      built = rows(payload(@trace_id))

      assert [%{id: @trace_id, agent_id: "agent-01", target_ip: "192.0.2.50"}] = built.traces
      assert [%{"trace_uuid" => @trace_id}] = built.results

      assert Enum.map(built.hops, & &1.id) ==
               Enum.map(0..2, &MtrMetricsIngestor.hop_id(@trace_id, &1))

      assert Enum.all?(built.hops, &(&1.trace_id == @trace_id and &1.target_ip == "192.0.2.50"))
    end

    test "a redelivered trace yields identical keys" do
      first = rows(payload(@trace_id))
      again = rows(payload(@trace_id))

      assert Enum.map(first.traces, &{&1.id, &1.time}) ==
               Enum.map(again.traces, &{&1.id, &1.time})

      assert Enum.map(first.hops, &{&1.id, &1.time}) == Enum.map(again.hops, &{&1.id, &1.time})
    end

    test "another trace yields different hop keys" do
      ids = fn built -> MapSet.new(built.hops, & &1.id) end

      assert MapSet.disjoint?(
               ids.(rows(payload(@trace_id))),
               ids.(rows(payload(@other_trace_id)))
             )
    end

    test "a result without a target cannot be built" do
      payload = %{"results" => [%{"trace_uuid" => @trace_id, "trace" => %{"hops" => []}}]}

      assert MtrMetricsIngestor.rows(payload, %{}) == {:error, :missing_target_ip}
    end

    test "a payload that is not a result is invalid" do
      assert MtrMetricsIngestor.rows("not a result", %{}) == {:error, :invalid_payload}
    end

    test "an empty payload builds nothing" do
      assert {:ok, %{results: [], traces: [], hops: []}} =
               MtrMetricsIngestor.rows(%{"results" => []}, %{})
    end
  end
end
