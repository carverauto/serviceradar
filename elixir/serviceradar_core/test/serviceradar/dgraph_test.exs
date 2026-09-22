defmodule ServiceRadar.DgraphTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.Dgraph.Native

  @dgraph_url System.get_env("DGRAPH_URL")

  setup do
    previous_url = Application.get_env(:serviceradar_core, :dgraph_url)
    previous_host = Application.get_env(:serviceradar_core, :dgraph_host)
    previous_port = Application.get_env(:serviceradar_core, :dgraph_port)
    previous_tls = Application.get_env(:serviceradar_core, :dgraph_tls_mode)

    on_exit(fn ->
      put_app(:dgraph_url, previous_url)
      put_app(:dgraph_host, previous_host)
      put_app(:dgraph_port, previous_port)
      put_app(:dgraph_tls_mode, previous_tls)
    end)

    :ok
  end

  test "url prefers DGRAPH_URL over application env" do
    Application.put_env(:serviceradar_core, :dgraph_url, "dgraph://app.example:9080")

    env_url = System.get_env("DGRAPH_URL")

    System.put_env(
      "DGRAPH_URL",
      "dgraph://groot:password@alpha.example:9080?sslmode=disable"
    )

    try do
      assert {:ok, "dgraph://groot:password@alpha.example:9080?sslmode=disable"} = Dgraph.url()
    after
      restore_env("DGRAPH_URL", env_url)
    end
  end

  test "url assembles host/port/tls when DGRAPH_URL is unset" do
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")
    env_port = System.get_env("DGRAPH_PORT")
    env_tls = System.get_env("DGRAPH_TLS_MODE")

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    System.delete_env("DGRAPH_PORT")
    System.delete_env("DGRAPH_TLS_MODE")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.put_env(:serviceradar_core, :dgraph_host, "alpha.example")
    Application.put_env(:serviceradar_core, :dgraph_port, 9080)
    Application.put_env(:serviceradar_core, :dgraph_tls_mode, "require")

    try do
      assert {:ok, "dgraph://alpha.example:9080?sslmode=require"} = Dgraph.url()
    after
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
      restore_env("DGRAPH_PORT", env_port)
      restore_env("DGRAPH_TLS_MODE", env_tls)
    end
  end

  test "url errors when nothing is configured" do
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    try do
      assert {:error, reason} = Dgraph.url()
      assert reason =~ "not configured"
    after
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
    end
  end

  test "query refuses mutations without contacting dgraph" do
    env_url = System.get_env("DGRAPH_URL")
    System.delete_env("DGRAPH_URL")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    try do
      assert {:error, reason} = Dgraph.query("mutation { set { _:x <dgraph.type> \"Device\" } }")
      assert reason =~ "refuses mutations"

      assert {:error, _} = Dgraph.query("set { _:x <device.id> \"sr:host01.example.com\" }")
      assert {:error, _} = Dgraph.query("delete { uid(v) * * . }")
      assert {:error, _} = Dgraph.query("upsert { query { q(func: uid(0x1)) { uid } } }")
      assert {:error, "dql query is empty"} = Dgraph.query("   ")
    after
      restore_env("DGRAPH_URL", env_url)
    end
  end

  test "mutation?/1 allows read-only DQL" do
    refute Dgraph.mutation?("{ q(func: eq(device.id, \"sr:host01.example.com\")) { uid } }")
    refute Dgraph.mutation?("{ q(func: eq(device.id, \"mutation-lab\")) { uid } }")
    assert Dgraph.mutation?("MUTATION{\n  set { _:x <dgraph.type> \"Device\" }\n}")
  end

  test "native query_dql refuses mutations when the nif is loaded" do
    result =
      try do
        Native.query_dql(
          "dgraph://unused:9080",
          "mutation { set { _:x <dgraph.type> \"Device\" } }"
        )
      rescue
        ErlangError -> :nif_not_loaded
      end

    case result do
      {:error, reason} ->
        assert reason =~ "refuses mutations"

      :nif_not_loaded ->
        :ok

      other ->
        flunk("expected mutation refusal or nif_not_loaded, got #{inspect(other)}")
    end
  end

  @tag :dgraph
  @tag skip: @dgraph_url in [nil, ""]
  test "upserts a synthetic device against the configured cluster" do
    id = "sr:host01.example.com"

    assert :ok =
             Dgraph.upsert_device(%{
               id: id,
               hostname: "host01.example.com",
               ip: "192.0.2.10"
             })

    assert {:ok, payload} =
             Dgraph.query("{ q(func: eq(device.id, \"#{id}\")) { device.id device.hostname } }")

    nodes = Map.get(payload, "q", [])
    assert Enum.any?(nodes, fn node -> node["device.id"] == id end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)

  defp restore_env(name, value) when is_binary(value) do
    System.put_env(name, value)
  end

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
