defmodule ServiceRadar.ColdTier.StateTest do
  @moduledoc """
  The single cold-tier activation state (review F09). The load-bearing
  invariant: the retention fence and the exporter must agree, so a partial
  config can never fence retention while the exporter is unable to run.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.ColdTier.Config

  @full [
    enabled: true,
    bucket_url: "s3://tenant-cold",
    s3_endpoint: "obj.example",
    s3_region: "us-east-1",
    s3_access_key_id: "k",
    s3_secret_access_key: "s",
    head_host: "cnpg-analytics",
    head_database: "serviceradar",
    head_username: "serviceradar",
    head_password: "p",
    primary_host: "cnpg",
    primary_database: "serviceradar",
    primary_fdw_username: "cold_reader",
    primary_fdw_password: "p"
  ]

  setup do
    original = Application.get_env(:serviceradar_core, ServiceRadar.ColdTier)
    on_exit(fn -> restore(original) end)
    :ok
  end

  defp put(cfg), do: Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)
  defp restore(nil), do: Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
  defp restore(cfg), do: Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)

  test "no intent is :disabled" do
    put(enabled: false, bucket_url: "s3://x")
    assert Config.state() == :disabled
    refute Config.enabled?()
    refute Config.intended?()

    put(enabled: true, bucket_url: "")
    assert Config.state() == :disabled
  end

  test "full config is :enabled" do
    put(@full)
    assert Config.state() == :enabled
    assert Config.enabled?()
    assert Config.intended?()
    assert Config.misconfiguration_reasons() == []
  end

  test "intended but incomplete is :misconfigured, and names what is missing" do
    put(Keyword.drop(@full, [:head_host, :primary_host]))

    assert Config.state() == :misconfigured
    # Misconfigured is NOT enabled — the fence and exporter both stand down,
    # so retention proceeds normally and the primary cannot fill (F09).
    refute Config.enabled?()
    # But intent is still true, so the deployment believes offload is on.
    assert Config.intended?()

    reasons = Config.misconfiguration_reasons()
    assert :analytics_head in reasons
    assert :primary_fdw in reasons
    refute :object_store in reasons
  end
end
