defmodule ServiceRadar.Catalog.CatalogRepository do
  @moduledoc """
  Solution Pack catalog source (`platform.catalog_repositories`), supporting both
  signed release catalogs (`mode: :release_catalog`) and two-way private Git
  directory trees (`mode: :gitops_tree`) across GitHub, GitLab, and Gitea/Forgejo.

  Harmonized with `ServiceRadar.Plugins.PluginRepository`:
  - Seeds the official `https://github.com/carverauto/serviceradar`
    `:release_catalog` source as an immutable `builtin: true, is_default: true`
    trust anchor (allowing `:enable` / `:disable` while rejecting `:update` /
    `:destroy`). Also supports direct HTTPS catalog portal endpoints such as
    `https://developer.serviceradar.cloud/packs/index.json`.
  - Enforces a restrictive SQL foreign key (`on_delete: :restrict`) to
    `ServiceRadar.Credentials.NetworkCredentialSecret` (`:api_token`), registered
    in `CredentialUsage` and `GuardCredentialDestroy`.
  - Emits redacted OCSF audit events via `ServiceRadar.Catalog.CatalogNotifier`.
  """

  use Ash.Resource,
    domain: ServiceRadar.Catalog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [ServiceRadar.Catalog.CatalogNotifier],
    primary_read_warning?: false

  alias Ash.Changeset.OriginalDataNotAvailable
  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Resource.Change
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Catalog.RepoUrl
  alias ServiceRadar.Credentials.NetworkCredentialSecret
  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @view_check {ActorHasPermission, permission: "catalog.view"}
  @install_check {ActorHasPermission, permission: "catalog.packs.install"}
  @export_check {ActorHasPermission, permission: "catalog.packs.export"}
  @manage_check {ActorHasPermission, permission: "catalog.repositories.manage"}
  @sync_check {ActorHasPermission, permission: "catalog.gitops.sync"}

  @default_index_asset "serviceradar-pack-index.json"
  @ed25519_key_bytes 32

  @writable_fields [
    :name,
    :mode,
    :provider_type,
    :repo_url,
    :branch,
    :base_path,
    :push_strategy,
    :index_asset_name,
    :signing_key_id,
    :signing_public_key,
    :credential_secret_id,
    :enabled,
    :auto_reconcile
  ]

  defmodule NormalizeAndValidateSource do
    @moduledoc false
    use Change

    @ed25519_bytes 32

    @impl true
    def change(changeset, _opts, _context) do
      case normalize_and_validate(changeset) do
        {:ok, updates} ->
          Ash.Changeset.force_change_attributes(changeset, updates)

        {:error, errors} ->
          Enum.reduce(errors, changeset, &Ash.Changeset.add_error(&2, &1))
      end
    end

    @impl true
    def atomic(changeset, _opts, _context) do
      if changeset.action_type != :create and match?(%OriginalDataNotAvailable{}, changeset.data) do
        {:not_atomic, "validating catalog repository requires full repository record"}
      else
        case normalize_and_validate(changeset) do
          {:ok, updates} when map_size(updates) > 0 -> {:atomic, updates}
          {:ok, _} -> :ok
          {:error, errors} -> {:error, errors}
        end
      end
    end

    defp normalize_and_validate(changeset) do
      mode = proposed(changeset, :mode) || :release_catalog
      provider = proposed(changeset, :provider_type) || :github
      raw_url = proposed(changeset, :repo_url)
      raw_branch = proposed(changeset, :branch) || "main"
      raw_base_path = proposed(changeset, :base_path) || "packs"
      key_id = trim_or_nil(proposed(changeset, :signing_key_id))
      pub_key = trim_or_nil(proposed(changeset, :signing_public_key))
      secret_id = proposed(changeset, :credential_secret_id)

      branch = String.trim(to_string(raw_branch))
      base_path = normalize_base_path(raw_base_path)

      errors =
        []
        |> check_url(raw_url, provider, mode)
        |> check_branch(branch)
        |> check_base_path(base_path)
        |> check_mode_requirements(mode, key_id, pub_key, secret_id)
        |> check_credential_kind(changeset, secret_id)

      case {errors, RepoUrl.parse(raw_url, provider, mode)} do
        {[], {:ok, parsed}} ->
          {:ok,
           %{
             repo_url: parsed.repo_url,
             provider_type: parsed.provider,
             branch: branch,
             base_path: base_path,
             signing_key_id: key_id,
             signing_public_key: pub_key
           }}

        {errs, _} ->
          {:error, Enum.reverse(errs)}
      end
    end

    defp check_url(errors, raw_url, provider, mode) do
      case RepoUrl.parse(raw_url, provider, mode) do
        {:ok, _} ->
          errors

        {:error, reason} ->
          [
            InvalidAttribute.exception(
              field: :repo_url,
              message: RepoUrl.describe_error(reason)
            )
            | errors
          ]
      end
    end

    defp check_branch(errors, branch) do
      if branch == "" or String.contains?(branch, ["..", " ", "\t", "\n", "\\", "~", "^", ":"]) do
        [
          InvalidAttribute.exception(
            field: :branch,
            message: "must be a valid Git branch name"
          )
          | errors
        ]
      else
        errors
      end
    end

    defp check_base_path(errors, base_path) do
      segments = String.split(base_path, "/", trim: true)

      if segments == [] or Enum.any?(segments, &(&1 in [".", ".."] or String.contains?(&1, "\\"))) do
        [
          InvalidAttribute.exception(
            field: :base_path,
            message: "must be a safe relative directory path without '..' segments"
          )
          | errors
        ]
      else
        errors
      end
    end

    defp check_mode_requirements(errors, :release_catalog, key_id, pub_key, _secret_id) do
      errors =
        if is_nil(key_id) do
          [
            InvalidAttribute.exception(
              field: :signing_key_id,
              message: "is required for release_catalog repositories"
            )
            | errors
          ]
        else
          errors
        end

      case validate_ed25519_key(pub_key) do
        :ok ->
          errors

        {:error, msg} ->
          [
            InvalidAttribute.exception(
              field: :signing_public_key,
              message: msg
            )
            | errors
          ]
      end
    end

    defp check_mode_requirements(errors, :gitops_tree, _key_id, pub_key, secret_id) do
      errors =
        if is_nil(secret_id) do
          [
            InvalidAttribute.exception(
              field: :credential_secret_id,
              message: "is required for gitops_tree repositories"
            )
            | errors
          ]
        else
          errors
        end

      if is_nil(pub_key) do
        errors
      else
        case validate_ed25519_key(pub_key) do
          :ok ->
            errors

          {:error, msg} ->
            [InvalidAttribute.exception(field: :signing_public_key, message: msg) | errors]
        end
      end
    end

    defp check_mode_requirements(errors, _mode, _key_id, _pub_key, _secret_id), do: errors

    defp check_credential_kind(errors, changeset, secret_id) do
      changing? =
        changeset.action_type == :create or
          Ash.Changeset.changing_attribute?(changeset, :credential_secret_id)

      cond do
        not changing? or is_nil(secret_id) ->
          errors

        not is_pid(Process.whereis(ServiceRadar.Repo)) ->
          errors

        true ->
          actor = SystemActor.system(:catalog_repository_credentials)

          case NetworkCredentialSecret.get_by_id(secret_id, actor: actor) do
            {:ok, %{credential_kind: :api_token}} ->
              errors

            {:ok, %{credential_kind: kind}} ->
              [
                InvalidAttribute.exception(
                  field: :credential_secret_id,
                  message: "must reference an api_token credential, got #{inspect(kind)}"
                )
                | errors
              ]

            {:error, _} ->
              [
                InvalidAttribute.exception(
                  field: :credential_secret_id,
                  message: "references a credential that does not exist"
                )
                | errors
              ]
          end
      end
    end

    defp validate_ed25519_key(nil), do: {:error, "is required for release_catalog repositories"}

    defp validate_ed25519_key(value) when is_binary(value) do
      case Base.decode64(String.trim(value)) do
        {:ok, decoded} when byte_size(decoded) == @ed25519_bytes ->
          :ok

        {:ok, decoded} ->
          {:error, "must be a 32-byte ed25519 public key; decoded to #{byte_size(decoded)} bytes"}

        :error ->
          {:error, "must be base64-encoded"}
      end
    end

    defp normalize_base_path(value) do
      value
      |> to_string()
      |> String.trim()
      |> String.trim("/")
      |> case do
        "" -> "packs"
        trimmed -> trimmed
      end
    end

    defp trim_or_nil(nil), do: nil

    defp trim_or_nil(val) do
      case String.trim(to_string(val)) do
        "" -> nil
        s -> s
      end
    end

    defp proposed(changeset, field) do
      case Keyword.fetch(changeset.atomics, field) do
        {:ok, v} ->
          v

        :error ->
          case Ash.Changeset.fetch_change(changeset, field) do
            {:ok, v} ->
              v

            :error ->
              cond do
                Map.has_key?(changeset.attributes, field) -> Map.get(changeset.attributes, field)
                is_map(changeset.data) -> Map.get(changeset.data, field)
                true -> nil
              end
          end
      end
    end
  end

  defmodule RejectBuiltinRepository do
    @moduledoc false
    use Change

    @impl true
    def change(changeset, _opts, _context) do
      if match?(%Ash.Changeset{data: %{builtin: true}}, changeset) do
        Ash.Changeset.add_error(changeset,
          field: :builtin,
          message:
            "the built-in catalog repository cannot be edited or removed; disable it instead"
        )
      else
        changeset
      end
    end

    @impl true
    def atomic(_changeset, _opts, _context), do: :ok
  end

  postgres do
    table "catalog_repositories"
    repo ServiceRadar.Repo
    schema "platform"

    identity_index_names unique_source: "catalog_repositories_source_uidx"

    custom_indexes do
      index [:is_default],
        unique: true,
        where: "is_default",
        name: "catalog_repositories_single_default_uidx"

      index [:enabled], name: "catalog_repositories_enabled_idx"

      index [:credential_secret_id],
        where: "credential_secret_id IS NOT NULL",
        name: "catalog_repositories_credential_secret_id_idx"
    end

    references do
      reference :credential_secret,
        on_delete: :restrict,
        name: "catalog_repositories_credential_secret_id_fkey"

      reference :created_by,
        on_delete: :nilify,
        name: "catalog_repositories_created_by_id_fkey"
    end

    check_constraints do
      check_constraint :mode, "catalog_repositories_valid_contract",
        check: """
        mode IN ('release_catalog', 'gitops_tree') AND
        provider_type IN ('github', 'gitlab', 'gitea', 'portal') AND
        push_strategy IN ('pull_request', 'direct_commit') AND
        btrim(name) <> '' AND
        btrim(repo_url) <> '' AND
        repo_url ~ '^https://' AND
        btrim(branch) <> '' AND
        btrim(base_path) <> '' AND
        btrim(index_asset_name) <> '' AND
        (mode <> 'release_catalog' OR (
          signing_key_id IS NOT NULL AND btrim(signing_key_id) <> '' AND
          signing_public_key IS NOT NULL AND btrim(signing_public_key) <> ''
        )) AND
        (mode <> 'gitops_tree' OR (
          provider_type IN ('github', 'gitlab', 'gitea') AND
          credential_secret_id IS NOT NULL
        ))
        """
    end

    custom_statements do
      statement :seed_official_serviceradar_catalog do
        after_tables ["catalog_repositories"]

        up """
        DO $$
        DECLARE
          defaults integer;
        BEGIN
          INSERT INTO platform.catalog_repositories
            (id, name, mode, provider_type, repo_url, branch, base_path, push_strategy,
             index_asset_name, signing_key_id, signing_public_key, enabled, auto_reconcile,
             builtin, is_default, last_sync_summary, inserted_at, updated_at)
          VALUES
            (uuid_generate_v7(), 'ServiceRadar Official Solution Packs', 'release_catalog',
             'github', 'https://github.com/carverauto/serviceradar', 'main', 'packs',
             'pull_request', 'serviceradar-pack-index.json', 'serviceradar-first-party-v2',
             '2KMsaqvof357MV3RQl4/0DNXfF6+eIMQ+qjDJfL/N8I=', true, false, true, true,
             '{}'::jsonb, (now() AT TIME ZONE 'utc'), (now() AT TIME ZONE 'utc'))
          ON CONFLICT (mode, repo_url, branch, base_path) DO NOTHING;

          SELECT count(*) INTO defaults
          FROM platform.catalog_repositories
          WHERE is_default;

          IF defaults <> 1 THEN
            RAISE EXCEPTION
              'catalog_repositories seed left % default row(s), expected exactly 1', defaults;
          END IF;
        END
        $$;
        """

        down """
        -- serviceradar:allow-startup-maintenance: rollback-only bounded delete of the single seeded builtin catalog_repositories row before table drop; never runs on startup.
        DELETE FROM platform.catalog_repositories
        WHERE builtin = true
          AND repo_url = 'https://github.com/carverauto/serviceradar';
        """
      end

      statement :stateful_alert_rules_pack_provenance_columns do
        after_tables ["catalog_repositories"]

        up """
        ALTER TABLE platform.stateful_alert_rules
          ADD COLUMN IF NOT EXISTS pack_id text,
          ADD COLUMN IF NOT EXISTS pack_version text,
          ADD COLUMN IF NOT EXISTS parameter_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;
        """

        down """
        ALTER TABLE platform.stateful_alert_rules
          DROP COLUMN IF EXISTS parameter_overrides,
          DROP COLUMN IF EXISTS pack_version,
          DROP COLUMN IF EXISTS pack_id;
        """
      end

      statement :stateful_alert_rules_pack_id_idx do
        after_tables ["catalog_repositories"]

        up """
        CREATE INDEX IF NOT EXISTS stateful_alert_rules_pack_id_idx
          ON platform.stateful_alert_rules (pack_id)
          WHERE pack_id IS NOT NULL;
        """

        down """
        DROP INDEX IF EXISTS platform.stateful_alert_rules_pack_id_idx;
        """
      end

      statement :event_rules_pack_provenance_columns do
        after_tables ["catalog_repositories"]

        up """
        ALTER TABLE platform.event_rules
          ADD COLUMN IF NOT EXISTS pack_id text,
          ADD COLUMN IF NOT EXISTS pack_version text,
          ADD COLUMN IF NOT EXISTS managed boolean NOT NULL DEFAULT false,
          ADD COLUMN IF NOT EXISTS template_fingerprint text,
          ADD COLUMN IF NOT EXISTS parameter_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;
        """

        down """
        ALTER TABLE platform.event_rules
          DROP COLUMN IF EXISTS parameter_overrides,
          DROP COLUMN IF EXISTS template_fingerprint,
          DROP COLUMN IF EXISTS managed,
          DROP COLUMN IF EXISTS pack_version,
          DROP COLUMN IF EXISTS pack_id;
        """
      end

      statement :event_rules_pack_id_idx do
        after_tables ["catalog_repositories"]

        up """
        CREATE INDEX IF NOT EXISTS event_rules_pack_id_idx
          ON platform.event_rules (pack_id)
          WHERE pack_id IS NOT NULL;
        """

        down """
        DROP INDEX IF EXISTS platform.event_rules_pack_id_idx;
        """
      end

      statement :zen_rules_pack_provenance_columns do
        after_tables ["catalog_repositories"]

        up """
        ALTER TABLE platform.zen_rules
          ADD COLUMN IF NOT EXISTS pack_id text,
          ADD COLUMN IF NOT EXISTS pack_version text,
          ADD COLUMN IF NOT EXISTS managed boolean NOT NULL DEFAULT false,
          ADD COLUMN IF NOT EXISTS template_fingerprint text,
          ADD COLUMN IF NOT EXISTS parameter_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;
        """

        down """
        ALTER TABLE platform.zen_rules
          DROP COLUMN IF EXISTS parameter_overrides,
          DROP COLUMN IF EXISTS template_fingerprint,
          DROP COLUMN IF EXISTS managed,
          DROP COLUMN IF EXISTS pack_version,
          DROP COLUMN IF EXISTS pack_id;
        """
      end

      statement :zen_rules_pack_id_idx do
        after_tables ["catalog_repositories"]

        up """
        CREATE INDEX IF NOT EXISTS zen_rules_pack_id_idx
          ON platform.zen_rules (pack_id)
          WHERE pack_id IS NOT NULL;
        """

        down """
        DROP INDEX IF EXISTS platform.zen_rules_pack_id_idx;
        """
      end

      statement :authored_dashboards_pack_provenance_columns do
        after_tables ["catalog_repositories"]

        up """
        ALTER TABLE platform.authored_dashboards
          ADD COLUMN IF NOT EXISTS pack_id text,
          ADD COLUMN IF NOT EXISTS pack_version text,
          ADD COLUMN IF NOT EXISTS managed boolean NOT NULL DEFAULT false,
          ADD COLUMN IF NOT EXISTS template_fingerprint text,
          ADD COLUMN IF NOT EXISTS parameter_overrides jsonb NOT NULL DEFAULT '{}'::jsonb;
        """

        down """
        ALTER TABLE platform.authored_dashboards
          DROP COLUMN IF EXISTS parameter_overrides,
          DROP COLUMN IF EXISTS template_fingerprint,
          DROP COLUMN IF EXISTS managed,
          DROP COLUMN IF EXISTS pack_version,
          DROP COLUMN IF EXISTS pack_id;
        """
      end

      statement :authored_dashboards_pack_id_idx do
        after_tables ["catalog_repositories"]

        up """
        CREATE INDEX IF NOT EXISTS authored_dashboards_pack_id_idx
          ON platform.authored_dashboards (pack_id)
          WHERE pack_id IS NOT NULL;
        """

        down """
        DROP INDEX IF EXISTS platform.authored_dashboards_pack_id_idx;
        """
      end
    end
  end

  code_interface do
    define :list, action: :read
    define :get_by_id, action: :by_id, args: [:id]
    define :list_enabled, action: :enabled
    define :get_default, action: :default
  end

  actions do
    read :read do
      primary? true
      prepare build(sort: [builtin: :desc, name: :asc])
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :enabled do
      filter expr(enabled == true)
      prepare build(sort: [builtin: :desc, name: :asc])
    end

    read :default do
      get? true
      filter expr(is_default == true)
    end

    create :create do
      primary? true
      accept @writable_fields
      change NormalizeAndValidateSource
    end

    update :update do
      primary? true
      accept @writable_fields
      change RejectBuiltinRepository
      change NormalizeAndValidateSource
    end

    update :enable do
      accept []
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []
      change set_attribute(:enabled, false)
    end

    update :record_sync_success do
      accept [:last_sync_summary]
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
      change set_attribute(:last_sync_error, nil)
    end

    update :record_sync_error do
      accept [:last_sync_error, :last_sync_summary]
      change set_attribute(:last_sync_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      change RejectBuiltinRepository
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()

    policy action_type(:read) do
      authorize_if @view_check
      authorize_if @install_check
      authorize_if @export_check
      authorize_if @manage_check
      authorize_if @sync_check
    end

    policy action([:create, :update, :enable, :disable, :destroy]) do
      authorize_if @manage_check
    end

    policy action([:record_sync_success, :record_sync_error]) do
      authorize_if @manage_check
      authorize_if @sync_check
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :mode, :atom do
      allow_nil? false
      default :release_catalog
      public? true
      constraints one_of: [:release_catalog, :gitops_tree]
    end

    attribute :provider_type, :atom do
      allow_nil? false
      default :github
      public? true
      constraints one_of: [:github, :gitlab, :gitea, :portal]
    end

    attribute :repo_url, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 512
    end

    attribute :branch, :string do
      allow_nil? false
      default "main"
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :base_path, :string do
      allow_nil? false
      default "packs"
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :push_strategy, :atom do
      allow_nil? false
      default :pull_request
      public? true
      constraints one_of: [:pull_request, :direct_commit]
    end

    attribute :index_asset_name, :string do
      allow_nil? false
      default @default_index_asset
      public? true
      constraints min_length: 1, max_length: 255
    end

    attribute :signing_key_id, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :signing_public_key, :string do
      allow_nil? true
      public? true
      constraints max_length: 255
    end

    attribute :credential_secret_id, :uuid do
      allow_nil? true
      public? true
    end

    attribute :builtin, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :is_default, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
    end

    attribute :auto_reconcile, :boolean do
      allow_nil? false
      default false
      public? true
    end

    attribute :last_sync_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :last_sync_error, :string do
      allow_nil? true
      public? true
    end

    attribute :last_sync_summary, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :credential_secret, NetworkCredentialSecret do
      allow_nil? true
      public? true
      define_attribute? false
      source_attribute :credential_secret_id
    end

    belongs_to :created_by, ServiceRadar.Identity.User do
      allow_nil? true
      attribute_type :uuid
      public? true
    end
  end

  calculations do
    calculate :credential_attached?, :boolean, expr(not is_nil(credential_secret_id)) do
      public? true
    end
  end

  identities do
    identity :unique_source, [:mode, :repo_url, :branch, :base_path] do
      message "a catalog repository for this mode, URL, branch, and base path already exists"
    end
  end

  @doc """
  Returns the single trusted ed25519 key map `UploadSignature.verify/4` expects
  for this repository.
  """
  @spec trusted_signing_keys(t() | map()) :: %{String.t() => String.t()}
  def trusted_signing_keys(%{signing_key_id: key_id, signing_public_key: pub_key})
      when is_binary(key_id) and key_id != "" and is_binary(pub_key) and pub_key != "" do
    %{key_id => pub_key}
  end

  def trusted_signing_keys(_repo), do: %{}

  @doc "Expected byte length for raw ed25519 verification keys."
  @spec ed25519_key_bytes() :: pos_integer()
  def ed25519_key_bytes, do: @ed25519_key_bytes
end
