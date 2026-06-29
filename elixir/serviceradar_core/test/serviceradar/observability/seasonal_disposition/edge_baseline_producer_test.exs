defmodule ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducerTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Observability.SeasonalDisposition.EdgeBaselineProducer
  alias ServiceRadar.Observability.SeasonalDisposition.Source
  alias ServiceRadar.Plugins.ConfigSchema

  # A fake SRQL runner that returns hour-of-week profile rows shaped exactly as the
  # `stats:profile_hour_of_week` SQL emits them (string keys, device_id AS series),
  # branching on the source's metric_type so cpu and memory get distinct profiles.
  defmodule ProfileRunner do
    @moduledoc false
    @device "default:192.168.1.50"

    def query(query, _opts) do
      cond do
        String.contains?(query, "sysmon.cpu") -> {:ok, rows(35.0, 70.0)}
        String.contains?(query, "sysmon.memory") -> {:ok, rows(55.0, 88.0)}
        true -> {:ok, []}
      end
    end

    # Two buckets: a low normal hour and a HIGH recurring peak hour (Mon 09:00).
    defp rows(normal_center, peak_center) do
      [
        row(0, 3, normal_center),
        row(1, 9, peak_center)
      ]
    end

    defp row(dow, hod, center) do
      %{
        "series" => @device,
        "dow" => dow,
        "hod" => hod,
        "sample_value" => center,
        "bucket" => "2026-06-22T#{pad(hod)}:00:00Z",
        "bucket_count" => 8,
        "center" => center,
        "mad" => 2.0
      }
    end

    defp pad(n) when n < 10, do: "0#{n}"
    defp pad(n), do: "#{n}"

    def device, do: @device
  end

  defp sources do
    # The two seeded seasonal sources (cpu + memory); both supported.
    Source.defaults()
  end

  test "build keys each baseline by <device_uid>|<metric_name> with no cpu/memory collision" do
    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: sources(), runner: ProfileRunner)

    device = ProfileRunner.device()
    cpu_key = "#{device}|cpu.usage_percent"
    mem_key = "#{device}|memory.used_percent"

    assert baselines |> Map.keys() |> Enum.sort() == Enum.sort([cpu_key, mem_key])

    # The peak Monday-09:00 bucket carries the robust median center for each metric.
    assert %{"buckets" => cpu_buckets} = baselines[cpu_key]
    peak = Enum.find(cpu_buckets, &(&1["dow"] == 1 and &1["hod"] == 9))
    assert peak["center"] == 70.0
    # MAD 2.0 * 1.4826 MAD->sigma consistency constant.
    assert_in_delta peak["scale"], 2.9652, 1.0e-6
    assert peak["sample_count"] == 8

    assert %{"buckets" => mem_buckets} = baselines[mem_key]
    assert Enum.find(mem_buckets, &(&1["dow"] == 1 and &1["hod"] == 9))["center"] == 88.0
  end

  test "the built payload validates against the add-on config schema" do
    {:ok, baselines} = EdgeBaselineProducer.build(sources: sources(), runner: ProfileRunner)

    schema = load_addon_schema()
    assert :ok = ConfigSchema.validate_params(schema, %{"seasonal_baselines" => baselines})
  end

  test "reconcile writes seasonal_baselines into profile params, preserving metric_feed" do
    test_pid = self()

    profiles = [
      %{id: "profile-1", params: %{"metric_feed" => %{"sources" => ["sysmon", "snmp"]}}}
    ]

    updater = fn profile, params, _actor ->
      send(test_pid, {:updated, profile.id, params})
      {:ok, Map.put(profile, :params, params)}
    end

    assert {:ok, summary} =
             EdgeBaselineProducer.reconcile(
               sources: sources(),
               runner: ProfileRunner,
               profiles_loader: fn _actor -> {:ok, profiles} end,
               profile_updater: updater
             )

    assert summary.profiles_updated == 1
    assert summary.series == 2

    assert_received {:updated, "profile-1", params}
    # Existing feed ownership is preserved.
    assert params["metric_feed"] == %{"sources" => ["sysmon", "snmp"]}
    # The delivered baseline is keyed by the canonical device-uid|metric.
    device = ProfileRunner.device()
    assert Map.has_key?(params["seasonal_baselines"], "#{device}|memory.used_percent")
    assert Map.has_key?(params["seasonal_baselines"], "#{device}|cpu.usage_percent")
  end

  defmodule EmptyRunner do
    @moduledoc false
    def query(_query, _opts), do: {:ok, []}
  end

  test "build returns an empty payload when no profile rows exist (rolling-only)" do
    assert {:ok, baselines} =
             EdgeBaselineProducer.build(sources: sources(), runner: EmptyRunner)

    assert baselines == %{}
  end

  defp load_addon_schema do
    path =
      Path.expand("../../../../../../addons/anomaly-addon/config.schema.json", __DIR__)

    path
    |> File.read!()
    |> Jason.decode!()
  end
end
