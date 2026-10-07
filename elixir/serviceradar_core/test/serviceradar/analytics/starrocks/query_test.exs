defmodule ServiceRadar.Analytics.StarRocks.QueryTest do
  # This module mutates shared `:serviceradar_core` application env (via
  # `Application.put_env/3`) and reads it back through `StarRocks.Env`. An async
  # module that writes global env races every other module that reads it, so this
  # is serial like the other StarRocks test modules that also mutate env (#4517).
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query

  @moduletag :db_free

  test "execute submits compiled SQL on the MySQL query path" do
    for sql <- [
          "SELECT id, bytes_in FROM serviceradar.ocsf_network_activity LIMIT 1",
          "SELECT id, bytes_in FROM serviceradar.ocsf_network_activity " <>
            "WHERE flow_source = 'example cnpg_platform.native_query(' LIMIT 1"
        ] do
      mysql = fn submitted ->
        assert submitted == sql

        {:ok,
         %Postgrex.Result{
           command: :select,
           columns: ["id", "bytes_in"],
           rows: [["flow-alpha-0001", 1200]],
           num_rows: 1,
           connection_id: nil
         }}
      end

      assert {:ok, %Postgrex.Result{columns: columns, rows: rows, num_rows: 1}} =
               Query.execute(sql, mysql: mysql)

      assert columns == ["id", "bytes_in"]
      assert rows == [["flow-alpha-0001", 1200]]
    end
  end

  test "catalog join SQL is a MySQL error, never a PostgreSQL fallback" do
    sql =
      "SELECT f.id FROM serviceradar.ocsf_network_activity AS f " <>
        "LEFT JOIN cnpg_platform.platform.ocsf_devices AS dev " <>
        "ON dev.uid = f.device_uid LIMIT 1"

    mysql = fn submitted ->
      assert submitted == sql
      {:error, :connect_failed}
    end

    assert {:error, :connect_failed} = Query.execute(sql, mysql: mysql)
  end

  test "uninjected execute uses the MySQL pool rather than a stub ACK" do
    assert {:error, :starrocks_mysql_not_started} = Query.execute("SELECT 1")
  end

  test "native catalog filters require a compatible FE before submitting the filter" do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous) end)

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(previous, :catalog_enabled, true)
    )

    sql =
      "SELECT ip FROM TABLE(cnpg_platform.native_query(" <>
        "'SELECT ip FROM platform.ip_geo_enrichment_cache'))"

    for version <- ["3.5.99", "4.0.99", "4.1.99-example", "5.0.0-example"] do
      mysql = fn
        "SELECT current_version()" ->
          send(self(), :version_probed)
          {:ok, %Postgrex.Result{rows: [[version]]}}

        ^sql ->
          send(self(), :filter_submitted)
          {:ok, %Postgrex.Result{columns: ["ip"], rows: [["192.0.2.10"]]}}
      end

      if String.starts_with?(version, ["3.", "4.0."]) do
        assert {:error, {:starrocks_native_query_requires_version, "4.1", ^version}} =
                 Query.execute(sql, mysql: mysql)

        refute_received :filter_submitted
      else
        assert {:ok, %Postgrex.Result{rows: [["192.0.2.10"]]}} =
                 Query.execute(sql, mysql: mysql)

        assert_received :filter_submitted
      end

      assert_received :version_probed
    end

    assert {:error, :connect_failed} =
             Query.execute(sql,
               mysql: fn "SELECT current_version()" -> {:error, :connect_failed} end
             )
  end

  test "execute honors a MySQL inject from application env" do
    previous = Application.get_env(:serviceradar_core, StarRocks, [])

    mysql = fn sql ->
      assert sql == "SELECT 1"

      {:ok,
       %Postgrex.Result{
         command: :select,
         columns: ["c"],
         rows: [[1]],
         num_rows: 1,
         connection_id: nil
       }}
    end

    Application.put_env(
      :serviceradar_core,
      StarRocks,
      Keyword.put(previous, :mysql, mysql)
    )

    try do
      assert {:ok, %Postgrex.Result{rows: [[1]]}} = Query.execute("SELECT 1")
    after
      Application.put_env(:serviceradar_core, StarRocks, previous)
    end
  end

  test "env derives the FE query host and port for MySQL protocol" do
    previous = %{
      "SERVICERADAR_STARROCKS_FE_HTTP" => System.get_env("SERVICERADAR_STARROCKS_FE_HTTP"),
      "SERVICERADAR_STARROCKS_FE_HOST" => System.get_env("SERVICERADAR_STARROCKS_FE_HOST"),
      "SERVICERADAR_STARROCKS_FE_QUERY_PORT" =>
        System.get_env("SERVICERADAR_STARROCKS_FE_QUERY_PORT")
    }

    System.put_env("SERVICERADAR_STARROCKS_FE_HTTP", "http://lab-fe-service.starrocks.svc:8030")
    System.delete_env("SERVICERADAR_STARROCKS_FE_HOST")
    System.delete_env("SERVICERADAR_STARROCKS_FE_QUERY_PORT")

    try do
      config = Env.config()
      assert config[:fe_mysql_host] == "lab-fe-service.starrocks.svc"
      assert config[:fe_mysql_port] == 9030
      assert config[:fe_http] == "http://lab-fe-service.starrocks.svc:8030"
    after
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end
  end
end
