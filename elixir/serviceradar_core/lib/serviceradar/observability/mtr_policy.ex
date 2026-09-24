defmodule ServiceRadar.Observability.MtrPolicy do
  @moduledoc """
  Policy resource for automated MTR baseline and incident dispatch behavior.

  Controls automated target selection cadence, protocol defaults, fanout bounds,
  cooldown windows, and consensus strategy.
  """

  use Ash.Resource,
    domain: ServiceRadar.Observability,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Observability.Changes.SyncBaselineProtocols

  postgres do
    table "mtr_policies"
    repo ServiceRadar.Repo
    schema "platform"
    migrate? false
  end

  code_interface do
    define :list_enabled, action: :enabled
    define :create_policy, action: :create
    define :update_policy, action: :update
  end

  actions do
    defaults [:read, :destroy]

    read :enabled do
      filter expr(enabled == true)
    end

    create :create do
      accept [
        :name,
        :enabled,
        :scope,
        :partition_id,
        :target_selector,
        :baseline_interval_sec,
        :baseline_protocol,
        :baseline_protocols,
        :tcp_port,
        :baseline_canary_vantages,
        :incident_fanout_max_agents,
        :incident_cooldown_sec,
        :recovery_capture,
        :consensus_mode,
        :consensus_threshold,
        :consensus_min_agents
      ]

      change SyncBaselineProtocols
    end

    update :update do
      accept [
        :name,
        :enabled,
        :scope,
        :partition_id,
        :target_selector,
        :baseline_interval_sec,
        :baseline_protocol,
        :baseline_protocols,
        :tcp_port,
        :baseline_canary_vantages,
        :incident_fanout_max_agents,
        :incident_cooldown_sec,
        :recovery_capture,
        :consensus_mode,
        :consensus_threshold,
        :consensus_min_agents
      ]

      change SyncBaselineProtocols
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if always()
    end

    policy action([:create, :update, :destroy]) do
      authorize_if always()
    end
  end

  @protocol_order ["icmp", "udp", "tcp"]

  @doc """
  The protocols a policy traces with, as lowercase names in icmp/udp/tcp order.

  Accepts a policy struct or a plain map (callers pass either). A policy saved
  before protocol sets existed falls back to its single `baseline_protocol`.
  """
  @spec protocol_names(map()) :: [String.t()]
  def protocol_names(policy) when is_map(policy) do
    names =
      case protocol_list(policy, :baseline_protocols) do
        [] -> protocol_list(policy, :baseline_protocol)
        names -> names
      end

    case Enum.filter(@protocol_order, &(&1 in names)) do
      [] -> ["icmp"]
      ordered -> ordered
    end
  end

  @doc "The TCP destination port a policy's TCP traces use."
  @spec tcp_port(map()) :: pos_integer()
  def tcp_port(policy) when is_map(policy) do
    case policy_value(policy, :tcp_port) do
      port when is_integer(port) and port in 1..65_535 -> port
      _ -> 443
    end
  end

  defp policy_value(policy, key), do: Map.get(policy, key, Map.get(policy, Atom.to_string(key)))

  defp protocol_list(policy, key) do
    policy
    |> policy_value(key)
    |> List.wrap()
    |> Enum.map(&(&1 |> to_string() |> String.downcase()))
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :scope, :string do
      allow_nil? false
      default "managed_devices"
      public? true
    end

    attribute :partition_id, :string do
      public? true
    end

    attribute :target_selector, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :baseline_interval_sec, :integer do
      allow_nil? false
      default 300
      public? true
      constraints min: 30
    end

    attribute :baseline_protocol, :string do
      allow_nil? false
      default "icmp"
      public? true
      description "Legacy single protocol; mirrors the first entry of baseline_protocols"
    end

    attribute :baseline_protocols, {:array, :atom} do
      allow_nil? false
      default [:icmp]
      public? true
      description "Protocols each dispatch traces every target with, in icmp/udp/tcp order"
      constraints items: [one_of: [:icmp, :udp, :tcp]], min_length: 1
    end

    attribute :tcp_port, :integer do
      allow_nil? false
      default 443
      public? true
      description "Destination port for TCP traces"
      constraints min: 1, max: 65_535
    end

    attribute :baseline_canary_vantages, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
    end

    attribute :incident_fanout_max_agents, :integer do
      allow_nil? false
      default 3
      public? true
      constraints min: 1, max: 10
    end

    attribute :incident_cooldown_sec, :integer do
      allow_nil? false
      default 600
      public? true
      constraints min: 30
    end

    attribute :recovery_capture, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :consensus_mode, :string do
      allow_nil? false
      default "majority"
      public? true
    end

    attribute :consensus_threshold, :float do
      allow_nil? false
      default 0.66
      public? true
      constraints min: 0.0, max: 1.0
    end

    attribute :consensus_min_agents, :integer do
      allow_nil? false
      default 2
      public? true
      constraints min: 1
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_name, [:name]
  end
end
