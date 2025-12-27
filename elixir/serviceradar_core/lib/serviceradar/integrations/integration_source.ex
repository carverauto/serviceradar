defmodule ServiceRadar.Integrations.IntegrationSource do
  @moduledoc """
  Configuration for external data source integrations (Armis, SNMP, etc.).

  This resource stores integration configuration in Postgres. When configs
  are created or updated, they are pushed to the datasvc KV store for
  consumption by Go/Rust services.

  ## Source Types

  - `:armis` - Armis security platform
  - `:snmp` - SNMP polling
  - `:syslog` - Syslog/flowgger ingestion
  - `:nmap` - Network scanning
  - `:custom` - Custom webhook/API

  ## Workflow

  1. Admin creates/edits source config via UI
  2. Config is saved to Postgres
  3. After-save hook pushes config to datasvc KV
  4. Go/Rust services read config from datasvc on their poll interval
  """

  use Ash.Resource,
    domain: ServiceRadar.Integrations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "integration_sources"
    repo ServiceRadar.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
    global? true
  end

  cloak do
    vault(ServiceRadar.Vault)
    # Encrypt the entire credentials map as JSON
    attributes([:credentials_encrypted])
    decrypt_by_default([:credentials_encrypted])
  end

  code_interface do
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :list_by_type, action: :by_type, args: [:source_type]
  end

  actions do
    defaults [:read]

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      description "All enabled integration sources"
      filter expr(enabled == true)
    end

    read :by_type do
      argument :source_type, :atom, allow_nil?: false
      filter expr(source_type == ^arg(:source_type))
    end

    read :by_agent do
      argument :agent_id, :string, allow_nil?: false
      filter expr(agent_id == ^arg(:agent_id))
    end

    create :create do
      accept [
        :name,
        :source_type,
        :endpoint,
        :agent_id,
        :poller_id,
        :partition,
        :poll_interval_seconds,
        :discovery_interval_seconds,
        :sweep_interval_seconds,
        :page_size,
        :network_blacklist,
        :queries,
        :custom_fields,
        :settings
      ]

      argument :credentials, :map do
        description "Credentials map (will be encrypted)"
        allow_nil? true
      end

      change fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :credentials) do
          nil ->
            changeset

          credentials when is_map(credentials) ->
            # Serialize to JSON for encrypted storage
            json = Jason.encode!(credentials)
            Ash.Changeset.change_attribute(changeset, :credentials_encrypted, json)
        end
      end

      # Sync to datasvc after create
      change after_action(fn changeset, record, _context ->
               sync_to_datasvc(record)
               {:ok, record}
             end)
    end

    update :update do
      require_atomic? false

      accept [
        :name,
        :endpoint,
        :agent_id,
        :poller_id,
        :partition,
        :poll_interval_seconds,
        :discovery_interval_seconds,
        :sweep_interval_seconds,
        :page_size,
        :network_blacklist,
        :queries,
        :custom_fields,
        :settings
      ]

      argument :credentials, :map do
        description "New credentials (will be encrypted)"
        allow_nil? true
      end

      change fn changeset, _context ->
        case Ash.Changeset.get_argument(changeset, :credentials) do
          nil ->
            changeset

          credentials when is_map(credentials) ->
            json = Jason.encode!(credentials)
            Ash.Changeset.change_attribute(changeset, :credentials_encrypted, json)
        end
      end

      # Sync to datasvc after update
      change after_action(fn changeset, record, _context ->
               sync_to_datasvc(record)
               {:ok, record}
             end)
    end

    update :enable do
      require_atomic? false
      change set_attribute(:enabled, true)

      change after_action(fn _changeset, record, _context ->
               sync_to_datasvc(record)
               {:ok, record}
             end)
    end

    update :disable do
      require_atomic? false
      change set_attribute(:enabled, false)

      change after_action(fn _changeset, record, _context ->
               # Remove from datasvc when disabled
               remove_from_datasvc(record)
               {:ok, record}
             end)
    end

    update :record_sync do
      description "Record sync execution results"
      require_atomic? false

      argument :result, :atom do
        allow_nil? false
        constraints one_of: [:success, :partial, :failed, :timeout]
      end

      argument :device_count, :integer, default: 0
      argument :error_message, :string

      change fn changeset, _context ->
        result = Ash.Changeset.get_argument(changeset, :result)
        current_failures = changeset.data.consecutive_failures || 0

        new_failures =
          if result in [:success, :partial] do
            0
          else
            current_failures + 1
          end

        changeset
        |> Ash.Changeset.change_attribute(:last_sync_at, DateTime.utc_now())
        |> Ash.Changeset.change_attribute(:last_sync_result, result)
        |> Ash.Changeset.change_attribute(
          :last_device_count,
          Ash.Changeset.get_argument(changeset, :device_count)
        )
        |> Ash.Changeset.change_attribute(
          :last_error_message,
          Ash.Changeset.get_argument(changeset, :error_message)
        )
        |> Ash.Changeset.change_attribute(:consecutive_failures, new_failures)
        |> Ash.Changeset.change_attribute(
          :total_syncs,
          (changeset.data.total_syncs || 0) + 1
        )
      end
    end

    destroy :delete do
      require_atomic? false

      # Remove from datasvc before delete
      change before_action(fn changeset, _context ->
               remove_from_datasvc(changeset.data)
               changeset
             end)
    end
  end

  policies do
    # Super admins bypass all policies
    bypass always() do
      authorize_if actor_attribute_equals(:role, :super_admin)
    end

    # Read: admins in same tenant
    policy action_type(:read) do
      authorize_if expr(
                     ^actor(:role) == :admin and
                       tenant_id == ^actor(:tenant_id)
                   )
    end

    # Create/Update/Delete: admins only
    policy action_type([:create, :update, :destroy]) do
      authorize_if expr(
                     ^actor(:role) == :admin and
                       tenant_id == ^actor(:tenant_id)
                   )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      description "Human-readable source name"
    end

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:armis, :snmp, :syslog, :nmap, :custom]
      description "Type of data source"
    end

    attribute :endpoint, :string do
      allow_nil? false
      public? true
      description "API endpoint URL"
    end

    attribute :enabled, :boolean do
      default true
      public? true
      description "Whether this source is active"
    end

    # Assignment
    attribute :agent_id, :string do
      public? true
      description "Agent to assign this source to"
    end

    attribute :poller_id, :string do
      public? true
      description "Poller to assign this source to"
    end

    attribute :partition, :string do
      default "default"
      public? true
      description "Partition for this source"
    end

    # Scheduling
    attribute :poll_interval_seconds, :integer do
      default 300
      public? true
      description "How often to poll (seconds)"
    end

    attribute :discovery_interval_seconds, :integer do
      default 3600
      public? true
      description "How often to run discovery (seconds)"
    end

    attribute :sweep_interval_seconds, :integer do
      default 3600
      public? true
      description "How often to run network sweeps (seconds)"
    end

    # Source-specific settings
    attribute :page_size, :integer do
      default 100
      public? true
      description "Page size for API pagination"
    end

    attribute :network_blacklist, {:array, :string} do
      default []
      public? true
      description "Networks to exclude (CIDR notation)"
    end

    attribute :queries, {:array, :map} do
      default []
      public? true
      description "Query configurations"
    end

    attribute :custom_fields, {:array, :string} do
      default []
      public? true
      description "Custom fields to extract"
    end

    attribute :settings, :map do
      default %{}
      public? true
      description "Additional source-specific settings"
    end

    # Encrypted credentials (stored as encrypted JSON)
    attribute :credentials_encrypted, :string do
      public? false
      sensitive? true
      description "Encrypted credentials JSON"
    end

    # Sync tracking
    attribute :last_sync_at, :utc_datetime do
      public? true
      description "Last successful sync time"
    end

    attribute :last_sync_result, :atom do
      public? true
      constraints one_of: [:success, :partial, :failed, :timeout]
      description "Result of last sync"
    end

    attribute :last_device_count, :integer do
      default 0
      public? true
      description "Devices found in last sync"
    end

    attribute :last_error_message, :string do
      public? true
      description "Error from last failed sync"
    end

    attribute :consecutive_failures, :integer do
      default 0
      public? true
      description "Consecutive failed syncs"
    end

    attribute :total_syncs, :integer do
      default 0
      public? true
      description "Total sync attempts"
    end

    # Multi-tenancy
    attribute :tenant_id, :uuid do
      allow_nil? false
      public? false
      description "Tenant this source belongs to"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  calculations do
    calculate :credentials, :map, fn records, _opts ->
      # Decrypt and parse credentials JSON
      Enum.map(records, fn record ->
        case record.credentials_encrypted do
          nil -> nil
          "" -> %{}
          json -> Jason.decode!(json)
        end
      end)
    end

    calculate :poll_interval_display,
              :string,
              expr(
                cond do
                  poll_interval_seconds >= 3600 ->
                    fragment("? || ' hours'", poll_interval_seconds / 3600)

                  poll_interval_seconds >= 60 ->
                    fragment("? || ' minutes'", poll_interval_seconds / 60)

                  true ->
                    fragment("? || ' seconds'", poll_interval_seconds)
                end
              )

    calculate :status_label,
              :string,
              expr(
                cond do
                  enabled == false -> "Disabled"
                  last_sync_result == :success -> "Healthy"
                  last_sync_result == :partial -> "Partial"
                  last_sync_result in [:failed, :timeout] -> "Failed"
                  is_nil(last_sync_result) -> "Never Run"
                  true -> "Unknown"
                end
              )

    calculate :status_color,
              :string,
              expr(
                cond do
                  enabled == false -> "gray"
                  last_sync_result == :success -> "green"
                  last_sync_result == :partial -> "yellow"
                  last_sync_result in [:failed, :timeout] -> "red"
                  true -> "gray"
                end
              )

    calculate :is_healthy,
              :boolean,
              expr(
                enabled == true and
                  last_sync_result in [:success, :partial] and
                  consecutive_failures < 3
              )
  end

  identities do
    identity :unique_name_per_tenant, [:tenant_id, :name]
  end

  # Private helper functions for datasvc sync

  defp sync_to_datasvc(record) do
    # Build the sync config format expected by Go services
    config = build_sync_config(record)
    key = "sync/sources/#{record.id}"

    # Push to datasvc asynchronously
    Task.start(fn ->
      case ServiceRadar.DataService.Client.put(key, Jason.encode!(config)) do
        :ok ->
          require Logger
          Logger.info("Synced integration source #{record.name} to datasvc")

        {:error, reason} ->
          require Logger
          Logger.error("Failed to sync #{record.name} to datasvc: #{inspect(reason)}")
      end
    end)
  end

  defp remove_from_datasvc(record) do
    key = "sync/sources/#{record.id}"

    Task.start(fn ->
      case ServiceRadar.DataService.Client.delete(key) do
        :ok ->
          require Logger
          Logger.info("Removed integration source #{record.name} from datasvc")

        {:error, reason} ->
          require Logger
          Logger.warning("Failed to remove #{record.name} from datasvc: #{inspect(reason)}")
      end
    end)
  end

  defp build_sync_config(record) do
    credentials =
      case record.credentials_encrypted do
        nil -> %{}
        "" -> %{}
        json -> Jason.decode!(json)
      end

    %{
      "type" => Atom.to_string(record.source_type),
      "endpoint" => record.endpoint,
      "prefix" => "#{record.source_type}/",
      "poll_interval" => format_duration(record.poll_interval_seconds),
      "sweep_interval" => format_duration(record.sweep_interval_seconds),
      "discovery_interval" => format_duration(record.discovery_interval_seconds),
      "agent_id" => record.agent_id,
      "poller_id" => record.poller_id,
      "partition" => record.partition,
      "credentials" => credentials,
      "page_size" => record.page_size,
      "network_blacklist" => record.network_blacklist,
      "queries" => record.queries,
      "custom_fields" => record.custom_fields
    }
  end

  defp format_duration(seconds) when is_integer(seconds) do
    cond do
      rem(seconds, 3600) == 0 -> "#{div(seconds, 3600)}h"
      rem(seconds, 60) == 0 -> "#{div(seconds, 60)}m"
      true -> "#{seconds}s"
    end
  end

  defp format_duration(_), do: "5m"
end
