defmodule ServiceRadar.Observability.Zen.RuleBucketTest do
  @moduledoc """
  The rule bucket on a real, disposable nats-server: what `ensure/0` creates is
  what a collector's key-value reader needs, and `put/2` reports what the
  bucket refuses.
  """
  use ExUnit.Case, async: false

  alias Gnat.Jetstream.API.KV
  alias ServiceRadar.Observability.Zen.RuleBucket
  alias ServiceRadar.TestSupport.ExposureBroker

  @moduletag :db_free
  @moduletag :tmp_dir
  @moduletag timeout: 120_000

  @stream "KV_serviceradar-zen-rules"
  @key "zen/rulesets/events/logs.syslog.json"

  setup do
    original = Application.get_env(:serviceradar_core, RuleBucket)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:serviceradar_core, RuleBucket),
        else: Application.put_env(:serviceradar_core, RuleBucket, original)
    end)
  end

  test "keeps only the latest bundle per key, in a file-backed bucket readers get directly",
       ctx do
    Application.put_env(:serviceradar_core, RuleBucket, max_bytes: 65_536, replicas: 1)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      assert :ok = RuleBucket.ensure()

      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:first"}))
      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:second"}))

      assert KV.get_value(conn, RuleBucket.bucket(), @key) == ~s({"digest":"sha256:second"})

      %{"config" => config, "state" => state} =
        ExposureBroker.request(conn, "$JS.API.STREAM.INFO.#{@stream}", %{})

      assert state["messages"] == 1
      assert config["max_bytes"] == 65_536
      assert config["max_age"] == 0
      assert config["storage"] == "file"
      assert config["allow_direct"] == true
    end)
  end

  test "a bundle the bucket's cap cannot hold is reported as not stored", ctx do
    Application.put_env(:serviceradar_core, RuleBucket, max_bytes: 4_096, replicas: 1)

    ExposureBroker.with_broker(ctx.tmp_dir, fn conn, _port ->
      assert :ok = RuleBucket.ensure()
      assert :ok = RuleBucket.put(@key, ~s({"digest":"sha256:small"}))

      assert {:error, :not_stored} =
               RuleBucket.put("zen/rulesets/events/logs.otel.json", String.duplicate("x", 8_192))

      assert KV.get_value(conn, RuleBucket.bucket(), @key) == ~s({"digest":"sha256:small"})
    end)
  end

  test "without a NATS connection, ensure and put report it instead of raising" do
    assert {:error, :not_connected} = RuleBucket.ensure()
    assert {:error, :not_connected} = RuleBucket.put(@key, "{}")
  end
end
