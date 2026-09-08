defmodule ServiceRadar.SweepJobs.SweepProfile.BannerGrab do
  @moduledoc """
  Embedded banner-grab configuration for sweep profiles.
  """

  use Ash.Resource, data_layer: :embedded

  @protocols [:ssh, :http, :smb, :ftp, :telnet, :smtp, :ntp, :dns, :rdp]

  def protocols, do: @protocols

  def default_input do
    input(
      enabled: false,
      protocols: [],
      ports: %{},
      connect_timeout_ms: 2_000,
      read_timeout_ms: 2_000,
      max_banner_bytes: 1_024,
      max_concurrency_per_host: 4,
      max_global_concurrency: 256,
      max_probe_rate_per_second: 0,
      max_candidate_queue: 8_192,
      match_batch_size: 256,
      match_batch_max_bytes: 1_048_576,
      min_reprobe_interval_s: 86_400,
      per_host_rate_limit_ms: 100
    )
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :protocols, {:array, :atom} do
      allow_nil? false
      public? true
      default []
      constraints items: [one_of: @protocols]
    end

    attribute :ports, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :connect_timeout_ms, :integer do
      allow_nil? false
      public? true
      default 2_000
      constraints min: 1, max: 30_000
    end

    attribute :read_timeout_ms, :integer do
      allow_nil? false
      public? true
      default 2_000
      constraints min: 1, max: 30_000
    end

    attribute :max_banner_bytes, :integer do
      allow_nil? false
      public? true
      default 1_024
      constraints min: 1, max: 65_536
    end

    attribute :max_concurrency_per_host, :integer do
      allow_nil? false
      public? true
      default 4
      constraints min: 1, max: 4_096
    end

    attribute :max_global_concurrency, :integer do
      allow_nil? false
      public? true
      default 256
      constraints min: 1, max: 4_096
    end

    attribute :max_probe_rate_per_second, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0, max: 50_000
    end

    attribute :max_candidate_queue, :integer do
      allow_nil? false
      public? true
      default 8_192
      constraints min: 1, max: 1_000_000
    end

    attribute :match_batch_size, :integer do
      allow_nil? false
      public? true
      default 256
      constraints min: 1, max: 4_096
    end

    attribute :match_batch_max_bytes, :integer do
      allow_nil? false
      public? true
      default 1_048_576
      constraints min: 1, max: 4_194_304
    end

    attribute :min_reprobe_interval_s, :integer do
      allow_nil? false
      public? true
      default 86_400
      constraints min: 0
    end

    attribute :per_host_rate_limit_ms, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0
    end
  end
end
