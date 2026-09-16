defmodule ServiceRadar.Analytics.StarRocks.AttributionTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Attribution
  alias ServiceRadar.Analytics.StarRocks.Rows

  @moduletag :db_free

  test "attribution updates omit traffic totals and are monotonic" do
    event =
      Attribution.update_event(%{id: "flow-alpha-0001", bytes_in: 1200, pid: 42, comm: "sshd"}, 3)

    assert event["id"] == "flow-alpha-0001"
    assert event["attribution_version"] == 3
    assert event["pid"] == 42
    refute Map.has_key?(event, "bytes_in")
    refute Map.has_key?(event, "bytes_out")
    assert Attribution.apply_monotonic(3, 2) == :ignore
    assert Attribution.apply_monotonic(3, 3) == :ignore
    assert Attribution.apply_monotonic(3, 4) == :apply
  end

  test "load_columns are declared on the StarRocks ocsf_network_activity table" do
    columns = ocsf_network_activity_columns()
    missing = Enum.reject(Attribution.load_columns(), &MapSet.member?(columns, &1))

    assert missing == [],
           "Stream Load attribution columns missing from ocsf_network_activity: #{inspect(missing)}"
  end

  test "flow_attribution encoder emits only attribution columns and drops traffic" do
    [row] =
      Rows.encode(:flow_attribution, [
        %{
          "id" => "flow-alpha-0001",
          "attribution_version" => 3,
          "pid" => 9,
          "comm" => "sshd",
          "bytes_in" => 1200,
          "bytes_out" => 80,
          "time" => "1999-06-15 12:00:00",
          "device_uid" => "sr:host-alpha"
        }
      ])

    assert Map.keys(row) -- Attribution.load_columns() == []
    assert row["id"] == "flow-alpha-0001"
    assert row["attribution_version"] == 3
    assert row["pid"] == 9
    refute Map.has_key?(row, "bytes_in")
    refute Map.has_key?(row, "bytes_out")
    refute Map.has_key?(row, "time")
    refute Map.has_key?(row, "device_uid")
  end

  test "default publisher uses NATS.Connection rather than a no-op" do
    assert {:error, {:nats_not_connected, :not_connected}} =
             Attribution.publish_updates([%{id: "flow-alpha-0001", pid: 9}])
  end

  test "publish_updates emit JetStream payloads without clobbering traffic totals" do
    parent = self()
    row = %{id: "flow-alpha-0001", pid: 9, comm: "nginx", bytes_in: 1200}

    assert :ok =
             Attribution.publish_updates([row],
               publish: fn message ->
                 send(parent, {:published, message})
                 :ok
               end
             )

    assert_received {:published, %{subject: "events.flow.attribution", payload: payload}}
    assert payload["id"] == "flow-alpha-0001"
    assert payload["attribution_version"] == 1
    refute Map.has_key?(payload, "bytes_in")
  end

  defp ocsf_network_activity_columns do
    schema_dir()
    |> Path.join("*.sql")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map_join("\n", &File.read!/1)
    |> extract_table_columns("ocsf_network_activity")
  end

  defp schema_dir do
    cwd = File.cwd!()

    runfiles_root = System.get_env("RUNFILES_DIR") || System.get_env("TEST_SRCDIR")
    workspace = System.get_env("TEST_WORKSPACE") || "_main"

    env_dir =
      if is_binary(runfiles_root) do
        Path.join([runfiles_root, workspace, "elixir/serviceradar_core/priv/starrocks"])
      end

    priv_dir =
      case :code.priv_dir(:serviceradar_core) do
        dir when is_list(dir) -> Path.join(List.to_string(dir), "starrocks")
        _ -> nil
      end

    [
      Path.join(cwd, "priv/starrocks"),
      Path.join(cwd, "elixir/serviceradar_core/priv/starrocks"),
      Path.join(Path.expand("../..", cwd), "elixir/serviceradar_core/priv/starrocks"),
      Path.expand("../../../priv/starrocks", __DIR__),
      env_dir,
      priv_dir
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.find(&(Path.wildcard(Path.join(&1, "*.sql")) != []))
    |> case do
      nil ->
        flunk("StarRocks schema SQL not found (cwd=#{cwd})")

      dir ->
        dir
    end
  end

  defp extract_table_columns(sql, table) do
    create =
      ~r/CREATE TABLE IF NOT EXISTS serviceradar\.#{table}\s*\((.*?)\)\s*PRIMARY KEY/s
      |> Regex.scan(sql)
      |> Enum.flat_map(fn [_, body] -> create_table_column_names(body) end)

    alters =
      ~r/ALTER TABLE serviceradar\.#{table}\s+ADD COLUMN(?: IF NOT EXISTS)?\s+`?([A-Za-z0-9_]+)`?/i
      |> Regex.scan(sql)
      |> Enum.map(fn [_, name] -> name end)

    MapSet.new(create ++ alters)
  end

  defp create_table_column_names(body) do
    body
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^`?([A-Za-z_][A-Za-z0-9_]*)`?\s+[A-Za-z]/, line) do
        [_, name] -> [name]
        _ -> []
      end
    end)
  end
end
