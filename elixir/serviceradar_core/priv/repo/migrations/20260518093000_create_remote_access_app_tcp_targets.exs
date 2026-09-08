defmodule ServiceRadar.Repo.Migrations.CreateRemoteAccessAppTcpTargets do
  @moduledoc """
  Creates trusted remote-access application and TCP target registrations.

  Browser clients reference these records by ID; upstream route, host, TLS,
  quota, approval, and recording policy stay server-owned.
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    create table(:remote_access_application_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:device_uid, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)
      add(:upstream_scheme, :text, null: false, default: "https")
      add(:upstream_host, :text, null: false)
      add(:upstream_port, :integer, null: false)
      add(:upstream_host_header, :text)
      add(:upstream_sni, :text)
      add(:tls_policy, :map, null: false, default: %{"verify" => "required"})
      add(:ca_bundle_ref, :text)
      add(:allowed_methods, {:array, :text}, null: false, default: [])
      add(:allowed_path_prefixes, {:array, :text}, null: false, default: ["/"])
      add(:header_policy, :map, null: false, default: %{})
      add(:cookie_policy, :map, null: false, default: %{})
      add(:quota_policy, :map, null: false, default: %{})
      add(:approval_policy, :map, null: false, default: %{})
      add(:recording_policy, :map, null: false, default: %{})
      add(:enhanced_recording_policy, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:remote_access_application_targets, [:device_uid, :enabled],
        name: :remote_access_application_targets_device_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_application_targets, [:agent_id, :enabled],
        name: :remote_access_application_targets_agent_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_application_targets,
        :remote_access_application_targets_scheme_valid,
        check: "upstream_scheme IN ('http', 'https')",
        prefix: @prefix
      )
    )

    create(
      constraint(
        :remote_access_application_targets,
        :remote_access_application_targets_port_valid,
        check: "upstream_port > 0 AND upstream_port <= 65535",
        prefix: @prefix
      )
    )

    create table(:remote_access_tcp_targets, primary_key: false, prefix: @prefix) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:name, :text, null: false)
      add(:description, :text)
      add(:device_uid, :text, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:agent_id, :text, null: false)
      add(:gateway_id, :text)
      add(:upstream_host, :text, null: false)
      add(:upstream_port, :integer, null: false)
      add(:protocol_name, :text, null: false, default: "tcp")
      add(:idle_timeout_seconds, :integer, null: false, default: 900)
      add(:absolute_timeout_seconds, :integer, null: false, default: 3600)
      add(:quota_policy, :map, null: false, default: %{})
      add(:approval_policy, :map, null: false, default: %{})
      add(:recording_policy, :map, null: false, default: %{})
      add(:enhanced_recording_policy, :map, null: false, default: %{})
      add(:metadata, :map, null: false, default: %{})

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(
      index(:remote_access_tcp_targets, [:device_uid, :enabled],
        name: :remote_access_tcp_targets_device_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      index(:remote_access_tcp_targets, [:agent_id, :enabled],
        name: :remote_access_tcp_targets_agent_enabled_idx,
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_tcp_targets, :remote_access_tcp_targets_port_valid,
        check: "upstream_port > 0 AND upstream_port <= 65535",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_tcp_targets, :remote_access_tcp_targets_idle_timeout_positive,
        check: "idle_timeout_seconds > 0",
        prefix: @prefix
      )
    )

    create(
      constraint(:remote_access_tcp_targets, :remote_access_tcp_targets_absolute_timeout_positive,
        check: "absolute_timeout_seconds > 0",
        prefix: @prefix
      )
    )
  end

  def down do
    drop_if_exists(table(:remote_access_tcp_targets, prefix: @prefix))
    drop_if_exists(table(:remote_access_application_targets, prefix: @prefix))
  end
end
