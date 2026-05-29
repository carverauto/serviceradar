defmodule ServiceRadar.Repo.Migrations.AddBannerGrabToSweepProfiles do
  @moduledoc false
  use Ecto.Migration

  @default_banner_grab %{
    "enabled" => false,
    "protocols" => [],
    "ports" => %{},
    "connect_timeout_ms" => 2_000,
    "read_timeout_ms" => 2_000,
    "max_banner_bytes" => 1_024,
    "max_concurrency_per_host" => 4,
    "max_global_concurrency" => 256,
    "max_probe_rate_per_second" => 0,
    "max_candidate_queue" => 8_192,
    "match_batch_size" => 256,
    "match_batch_max_bytes" => 1_048_576,
    "min_reprobe_interval_s" => 86_400,
    "per_host_rate_limit_ms" => 100
  }

  def change do
    alter table(:sweep_profiles, prefix: "platform") do
      add :banner_grab, :map, null: false, default: @default_banner_grab
    end
  end
end
