defmodule ServiceRadar.Analytics.StarRocks.QueryTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Analytics.StarRocks.Env
  alias ServiceRadar.Analytics.StarRocks.Query

  @moduletag :db_free

  test "execute submits compiled SQL on the MySQL query path" do
    sql = "SELECT id, bytes_in FROM serviceradar.ocsf_network_activity LIMIT 1"

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

  test "catalog join SQL is a MySQL error, never a PostgreSQL fallback" do
    sql =
      "SELECT f.id FROM serviceradar.ocsf_network_activity AS f " <>
        "INNER JOIN cnpg_platform.platform.flow_process_attribution_current AS attr " <>
        "ON attr.local_ip = f.src_endpoint_ip LIMIT 1"

    mysql = fn submitted ->
      assert submitted == sql
      {:error, :connect_failed}
    end

    assert {:error, :connect_failed} = Query.execute(sql, mysql: mysql)
  end

  test "uninjected execute uses the MySQL pool rather than a stub ACK" do
    assert {:error, :starrocks_mysql_not_started} = Query.execute("SELECT 1")
  end

  test "env derives the FE query host and port for MySQL protocol" do
    previous = %{
      "SERVICERADAR_STARROCKS_FE_HTTP" => System.get_env("SERVICERADAR_STARROCKS_FE_HTTP"),
      "SERVICERADAR_STARROCKS_FE_HOST" => System.get_env("SERVICERADAR_STARROCKS_FE_HOST"),
      "SERVICERADAR_STARROCKS_FE_QUERY_PORT" => System.get_env("SERVICERADAR_STARROCKS_FE_QUERY_PORT")
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
