defmodule ServiceRadar.ColdTier.CaggWindowTest do
  @moduledoc """
  Continuous-aggregate retention widening is gated on the cold tier actually
  being enabled (OpenSpec add-tiered-telemetry-offload, task 2.8).

  This started life as an unconditional migration. That was wrong: widening a
  rollup's retention window costs storage on EVERY deployment, and the reason
  to pay for it -- raw history being served from cold objects, leaving the
  in-database rollups as the only source for the stats surfaces over that same
  range -- only exists once an operator turns the cold tier on. A deployment
  that never enables it would have inherited 90-day rollups for nothing.

  The DDL itself needs a live TimescaleDB and belongs to the integration tier.
  What is pinned here is the part that matters to the ~all deployments that
  never enable the cold tier: nothing happens, and nothing is even asked.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.ColdTier.RetentionFence

  @enabled [
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

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:serviceradar_core, ServiceRadar.ColdTier)
        cfg -> Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)
      end
    end)

    :ok
  end

  defp put(cfg), do: Application.put_env(:serviceradar_core, ServiceRadar.ColdTier, cfg)

  # Not a repo. Any query attempt raises out of Ecto.Repo.Registry.lookup/1,
  # which is the assertion: the disabled path must not reach the database at
  # all, not merely decline to change anything once it gets there.
  defmodule NotARepo do
  end

  test "disabled: touches nothing and does not query" do
    put(enabled: false)

    assert RetentionFence.reconcile_cagg_windows(repo: NotARepo) == :ok
  end

  test "intended but misconfigured is not enabled, so it still does not query" do
    # Same rule the fence and exporter follow (review F09): a half-configured
    # deployment stands down rather than acting on partial intent.
    put(Keyword.drop(@enabled, [:head_host, :primary_host]))

    assert ServiceRadar.ColdTier.Config.state() == :misconfigured
    assert RetentionFence.reconcile_cagg_windows(repo: NotARepo) == :ok
  end

  test "enabled: does reach the repo (guards against the gate inverting)" do
    # The mirror of the tests above. Without this, deleting the whole body of
    # reconcile_cagg_windows/1 would leave them all green.
    put(@enabled)

    assert_raise RuntimeError, ~r/could not lookup Ecto repo/, fn ->
      RetentionFence.reconcile_cagg_windows(repo: NotARepo)
    end
  end
end
