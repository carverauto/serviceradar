defmodule ServiceRadar.Automation.Ansible.AwxMembershipQuarantineReleaseRecord do
  @moduledoc """
  Append-only record of one human release of an AWX host membership from
  quarantine.

  `AwxMembershipQuarantineRelease` writes it in the same transaction as the
  membership update. It keeps what the release is about to overwrite: the prior
  reason, time and full link evidence, alongside the releasing principal and
  the resulting disposition, device and evidence. There are no update or
  destroy actions, and no foreign key to the membership, so the history
  survives a controller deletion that cascades the memberships.
  """

  use Ash.Resource,
    domain: ServiceRadar.Automation.Ansible,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Automation.Ansible.AwxHostMembership
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "ansible.runs.view"}

  postgres do
    table "ansible_awx_membership_quarantine_releases"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :record, action: :record
    define :list_for_membership, action: :for_membership, args: [:membership_id]
  end

  actions do
    read :read do
      primary? true
    end

    read :for_membership do
      argument :membership_id, :uuid, allow_nil?: false
      filter expr(membership_id == ^arg(:membership_id))
      prepare build(sort: [released_at: :asc, id: :asc])
    end

    create :record do
      accept [
        :membership_id,
        :controller_id,
        :inventory_id,
        :awx_host_id,
        :released_by_principal_id,
        :released_at,
        :prior_quarantine_reason,
        :prior_quarantined_at,
        :prior_link_evidence,
        :source_generation,
        :source_fingerprint,
        :released_link_disposition,
        :released_canonical_device_uid,
        :released_link_evidence
      ]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    action_with_permission([:read, :for_membership], @view_check)
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :membership_id, :uuid, allow_nil?: false, public?: true
    attribute :controller_id, :uuid, allow_nil?: false, public?: true

    attribute :inventory_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :awx_host_id, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :released_by_principal_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1
    end

    attribute :released_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :prior_quarantine_reason, :atom do
      allow_nil? false
      public? true

      constraints one_of: AwxHostMembership.quarantine_reasons()
    end

    attribute :prior_quarantined_at, :utc_datetime_usec, allow_nil?: true, public?: true
    attribute :prior_link_evidence, :map, allow_nil?: false, public?: true

    attribute :source_generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :source_fingerprint, :string, allow_nil?: false, public?: true

    attribute :released_link_disposition, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:proposed, :unlinked]
    end

    attribute :released_canonical_device_uid, :string, allow_nil?: true, public?: true
    attribute :released_link_evidence, :map, allow_nil?: false, public?: true

    create_timestamp :inserted_at
  end
end
