defmodule ServiceRadar.EventWriter.ReleaseRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Camera.VisualIndexDispatchWorker
  alias ServiceRadar.Repo

  @moduletag :db_free
  # The release loads serviceradar_core_elx's runtime config, not this app's,
  # and it once carried a stale ATTRIBUTED_FLOW registration nothing consumes.
  @runtime_config Path.expand("../../../../serviceradar_core_elx/config/runtime.exs", __DIR__)
  @external_resource @runtime_config

  test "release config provisions no attributed-flow subject, stream, or durable" do
    event_writer = event_writer_config()

    for entry <- provisioned_entries(event_writer) do
      refute entry[:name] in ["ATTRIBUTED_FLOW", "ATTRIBUTED_FLOW_EVENTS_DRAIN"],
             "release config must not provision #{inspect(entry[:name])}"

      refute entry[:stream_name] == "attributed_flow",
             "release config must not consume stream #{inspect(entry[:stream_name])}"

      subject = entry[:subject] || ""

      refute String.starts_with?(subject, "flow.attributed."),
             "release config must not consume #{inspect(subject)}"
    end
  end

  test "release config declares no events-stream flow drains" do
    event_writer = event_writer_config()

    for entry <- provisioned_entries(event_writer) do
      refute String.ends_with?(entry[:name] || "", "_EVENTS_DRAIN"),
             "release config must not declare #{inspect(entry[:name])}"

      refute entry[:stream_name] == "events" and
               String.starts_with?(entry[:subject] || "", "flows.raw."),
             "release config must not drain #{inspect(entry[:subject])} from events"
    end
  end

  test "release config consumes visual index results only where visual indexing is enabled" do
    names = fn env ->
      env |> event_writer_config() |> provisioned_entries() |> Enum.map(& &1[:name])
    end

    assert "CAMERA_VISUAL_INDEX_RESULTS" in names.(%{
             "SERVICERADAR_CAMERA_RECORDING_ENABLED" => "true",
             "SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED" => "true"
           })

    Repo.put_dynamic_repo(:unavailable_visual_index_repo)

    for {recording, indexing} <- [{"true", "false"}, {"false", "true"}] do
      refute "CAMERA_VISUAL_INDEX_RESULTS" in names.(%{
               "SERVICERADAR_CAMERA_RECORDING_ENABLED" => recording,
               "SERVICERADAR_CAMERA_VISUAL_INDEXING_ENABLED" => indexing
             })

      assert :ok = VisualIndexDispatchWorker.perform(%Oban.Job{})
    end
  end

  test "release config consumes camera vantage observations only when SERVICERADAR_VANTAGE_PIPELINES_ENABLED=true" do
    names = fn env ->
      env |> event_writer_config() |> provisioned_entries() |> Enum.map(& &1[:name])
    end

    assert "CAMERA_VANTAGE_OBSERVATIONS" in names.(%{
             "SERVICERADAR_VANTAGE_PIPELINES_ENABLED" => "true"
           })

    refute "CAMERA_VANTAGE_OBSERVATIONS" in names.(%{
             "SERVICERADAR_VANTAGE_PIPELINES_ENABLED" => "false"
           })

    refute "CAMERA_VANTAGE_OBSERVATIONS" in names.(%{})
  end

  defp provisioned_entries(event_writer) do
    Enum.flat_map([:streams, :flow_streams], fn key ->
      entries = event_writer[key]

      assert is_list(entries) and entries != [],
             "release config must declare EventWriter #{inspect(key)}"

      entries
    end)
  end

  # Same minimal env the file needs to evaluate: a syntactically valid
  # cloak key and a dummy database URL (never connected), with EventWriter
  # enabled as the chart deploys it.
  @base_env %{
    "EVENT_WRITER_ENABLED" => "true",
    "CLOAK_KEY" => Base.encode64(:binary.copy(<<7>>, 32)),
    "DATABASE_URL" => "ecto://user:pass@localhost/release_config_test",
    "SERVICERADAR_ASH_OBAN_SCHEDULER_ENABLED" => "false"
  }

  defp event_writer_config(extra_env \\ %{}) do
    env = Map.merge(@base_env, extra_env)
    previous = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(env, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    Config.Reader.read!(@runtime_config, env: :prod)[:serviceradar_core][
      ServiceRadar.EventWriter
    ]
  end
end
