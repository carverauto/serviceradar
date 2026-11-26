defmodule ServiceRadarWebNGWeb.CatalogLive.RepositoryModalComponents do
  @moduledoc """
  Catalog Repository Management Modal, Push / Back Up to Private Git Modal,
  Pull Dry-Run Promotion Drawer (`dev -> staging -> prod`), and `.srpack`/`.json`
  Upload Modal (`4.5`) for `CatalogLive.Index`.
  """

  use ServiceRadarWebNGWeb, :html

  attr :open, :boolean, default: false
  attr :repositories, :list, default: []
  attr :credential_options, :map, default: %{secrets: [], rules: []}
  attr :repo_form, :map, required: true
  attr :editing_repo_id, :string, default: nil
  attr :repo_error, :string, default: nil
  attr :test_result, :map, default: nil
  attr :can_manage_repos, :boolean, default: false
  attr :can_gitops_sync, :boolean, default: false

  def repositories_modal(assigns) do
    api_token_secrets =
      assigns.credential_options
      |> Map.get(:secrets, [])
      |> Enum.filter(fn s ->
        to_string(s["credential_kind"] || "") in ["api_token", ""]
      end)

    assigns = assign(assigns, :api_token_secrets, api_token_secrets)

    ~H"""
    <div
      :if={@open}
      id="catalog-repositories-modal"
      data-role="catalog-repositories-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label="Catalog Repositories"
    >
      <div class="flex max-h-[92vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-center justify-between border-b border-sr-line px-6 py-4">
          <div>
            <h2 class="text-lg font-semibold text-sr-ink">Catalog & GitOps Repositories</h2>
            <p class="text-xs text-sr-muted">
              Manage signed <code class="font-mono">:release_catalog</code>
              sources and two-way HTTPS <code class="font-mono">:gitops_tree</code>
              repositories.
            </p>
          </div>
          <.ui_button type="button" size="sm" variant="ghost" phx-click="close_repositories_modal">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_button>
        </div>

        <div class="flex-1 overflow-y-auto p-6 space-y-6">
          <div
            :if={@repo_error}
            class="rounded-lg border border-red-500/40 bg-red-500/10 px-4 py-3 text-sm text-red-700 dark:text-red-300"
          >
            {@repo_error}
          </div>

          <div
            :if={@test_result}
            id="repo-test-result"
            class="rounded-lg border border-emerald-500/30 bg-emerald-500/10 px-4 py-3 text-xs text-sr-ink"
          >
            <strong>Connection verified:</strong>
            mode={@test_result["mode"]} · packs={@test_result["pack_count"]}
            <span :if={@test_result["commit_sha"]}> · commit={@test_result["commit_sha"]}</span>
          </div>

          <section class="space-y-2.5">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-sr-muted">
              Configured Repositories ({length(@repositories)})
            </h3>

            <div
              :if={@repositories == []}
              class="rounded-lg border border-sr-line bg-sr-subtle p-4 text-sm text-sr-muted"
            >
              No catalog repositories configured.
            </div>

            <div
              :for={repo <- @repositories}
              id={"catalog-repo-row-#{repo["id"]}"}
              class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-sr-line bg-sr-subtle/40 p-4"
            >
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-semibold text-sm text-sr-ink">{repo["name"]}</span>
                  <.ui_badge
                    variant={if(repo["mode"] == "gitops_tree", do: "info", else: "outline")}
                    size="xs"
                  >
                    {repo["mode"]}
                  </.ui_badge>
                  <.ui_badge variant="ghost" size="xs">{repo["provider_type"]}</.ui_badge>
                  <.ui_badge :if={repo["builtin"]} variant="success" size="xs">Built-in</.ui_badge>
                  <.ui_badge variant={if(repo["enabled"], do: "success", else: "warning")} size="xs">
                    {if(repo["enabled"], do: "Enabled", else: "Disabled")}
                  </.ui_badge>
                </div>
                <p class="mt-1 truncate font-mono text-xs text-sr-muted">
                  {repo["repo_url"]} · branch: {repo["branch"]} · path: {repo["base_path"]}
                </p>
                <p :if={repo["last_sync_error"]} class="mt-1 text-xs text-red-600 dark:text-red-400">
                  Last sync error: {repo["last_sync_error"]}
                </p>
              </div>

              <div class="flex flex-wrap items-center gap-1.5">
                <.ui_button
                  :if={@can_manage_repos or @can_gitops_sync}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="test_repository"
                  phx-value-id={repo["id"]}
                >
                  Test
                </.ui_button>
                <.ui_button
                  :if={@can_manage_repos or @can_gitops_sync}
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="sync_repository"
                  phx-value-id={repo["id"]}
                >
                  Sync
                </.ui_button>
                <.ui_button
                  :if={@can_gitops_sync and repo["mode"] == "gitops_tree"}
                  type="button"
                  size="xs"
                  variant="outline"
                  phx-click="open_gitops_pull"
                  phx-value-id={repo["id"]}
                >
                  Pull Promotion
                </.ui_button>
                <.ui_button
                  :if={@can_manage_repos}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="toggle_repository"
                  phx-value-id={repo["id"]}
                  phx-value-enabled={if(repo["enabled"], do: "false", else: "true")}
                >
                  {if(repo["enabled"], do: "Disable", else: "Enable")}
                </.ui_button>
                <.ui_button
                  :if={@can_manage_repos and not repo["builtin"]}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="edit_repository"
                  phx-value-id={repo["id"]}
                >
                  Edit
                </.ui_button>
                <.ui_button
                  :if={@can_manage_repos and not repo["builtin"]}
                  type="button"
                  size="xs"
                  variant="ghost"
                  phx-click="delete_repository"
                  phx-value-id={repo["id"]}
                >
                  Remove
                </.ui_button>
              </div>
            </div>
          </section>

          <section :if={@can_manage_repos} class="border-t border-sr-line pt-5 space-y-4">
            <h3 class="text-sm font-semibold text-sr-ink">
              {if(@editing_repo_id, do: "Edit Catalog Repository", else: "Add Catalog Repository")}
            </h3>

            <.form
              for={to_form(@repo_form, as: :repo)}
              id="catalog-repository-form"
              phx-change="change_repository_form"
              phx-submit="save_repository"
              class="grid grid-cols-1 gap-4 md:grid-cols-2"
            >
              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Display Name</span>
                <input
                  type="text"
                  name="repo[name]"
                  value={@repo_form["name"]}
                  placeholder="Acme Private Packs"
                  class={ui_field_class(size: "sm", class: "w-full")}
                  required
                />
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Mode</span>
                <select name="repo[mode]" class={ui_field_class(size: "sm", class: "w-full")}>
                  <option value="release_catalog" selected={@repo_form["mode"] == "release_catalog"}>
                    Signed Release Catalog (:release_catalog)
                  </option>
                  <option value="gitops_tree" selected={@repo_form["mode"] == "gitops_tree"}>
                    Two-Way Private GitOps Tree (:gitops_tree)
                  </option>
                </select>
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Provider</span>
                <select name="repo[provider_type]" class={ui_field_class(size: "sm", class: "w-full")}>
                  <option value="github" selected={@repo_form["provider_type"] == "github"}>
                    GitHub
                  </option>
                  <option value="gitlab" selected={@repo_form["provider_type"] == "gitlab"}>
                    GitLab
                  </option>
                  <option value="gitea" selected={@repo_form["provider_type"] == "gitea"}>
                    Gitea / Forgejo
                  </option>
                  <option value="portal" selected={@repo_form["provider_type"] == "portal"}>
                    Developer Portal HTTPS
                  </option>
                </select>
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Repository / Portal HTTPS URL</span>
                <input
                  type="url"
                  name="repo[repo_url]"
                  value={@repo_form["repo_url"]}
                  placeholder="https://github.com/example-org/serviceradar-packs"
                  class={ui_field_class(size: "sm", class: "w-full")}
                  required
                />
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Branch</span>
                <input
                  type="text"
                  name="repo[branch]"
                  value={@repo_form["branch"]}
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Base Path</span>
                <input
                  type="text"
                  name="repo[base_path]"
                  value={@repo_form["base_path"]}
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </label>

              <label :if={@repo_form["mode"] == "gitops_tree"} class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Push Strategy</span>
                <select name="repo[push_strategy]" class={ui_field_class(size: "sm", class: "w-full")}>
                  <option
                    value="pull_request"
                    selected={@repo_form["push_strategy"] == "pull_request"}
                  >
                    Pull / Merge Request (:pull_request)
                  </option>
                  <option
                    value="direct_commit"
                    selected={@repo_form["push_strategy"] == "direct_commit"}
                  >
                    Direct Commit (:direct_commit)
                  </option>
                </select>
              </label>

              <label class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">PAT Credential Secret (:api_token)</span>
                <select
                  name="repo[credential_secret_id]"
                  class={ui_field_class(size: "sm", class: "w-full")}
                >
                  <option value="">-- None (public release catalog) --</option>
                  <option
                    :for={s <- @api_token_secrets}
                    value={s["id"]}
                    selected={@repo_form["credential_secret_id"] == s["id"]}
                  >
                    {s["name"]} ({s["provider"]})
                  </option>
                </select>
              </label>

              <label :if={@repo_form["mode"] == "release_catalog"} class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Signing Key ID</span>
                <input
                  type="text"
                  name="repo[signing_key_id]"
                  value={@repo_form["signing_key_id"]}
                  placeholder="acme-packs-ed25519-v1"
                  class={ui_field_class(size: "sm", class: "w-full")}
                />
              </label>

              <label :if={@repo_form["mode"] == "release_catalog"} class="flex flex-col gap-1 text-xs">
                <span class="font-medium text-sr-ink">Ed25519 Public Key (base64)</span>
                <input
                  type="text"
                  name="repo[signing_public_key]"
                  value={@repo_form["signing_public_key"]}
                  placeholder="base64-encoded 32-byte key"
                  class={ui_field_class(size: "sm", class: "w-full font-mono")}
                />
              </label>

              <div class="md:col-span-2 flex items-center justify-end gap-2 pt-2">
                <.ui_button
                  :if={@editing_repo_id}
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="cancel_edit_repository"
                >
                  Cancel Edit
                </.ui_button>
                <.ui_button id="save-catalog-repo-btn" type="submit" size="sm" variant="primary">
                  {if(@editing_repo_id, do: "Save Changes", else: "Add Repository")}
                </.ui_button>
              </div>
            </.form>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :gitops_repos, :list, default: []
  attr :push_form, :map, required: true
  attr :push_result, :map, default: nil
  attr :push_error, :string, default: nil

  def gitops_push_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      id="gitops-push-modal"
      data-role="gitops-push-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label="Push Solution Pack to Private Git"
    >
      <div class="w-full max-w-xl rounded-xl border border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-center justify-between border-b border-sr-line px-6 py-4">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">Push / Back Up to Private Git</h2>
            <p class="text-xs text-sr-muted">
              Secret-free HTTPS Git Data API push via <code class="font-mono">EgressClient</code>.
            </p>
          </div>
          <.ui_button type="button" size="sm" variant="ghost" phx-click="close_gitops_push">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_button>
        </div>

        <div class="p-6 space-y-4">
          <div
            :if={@push_error}
            class="rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-xs text-red-700 dark:text-red-300"
          >
            {@push_error}
          </div>

          <div
            :if={@push_result}
            id="gitops-push-result"
            class="rounded-lg border border-emerald-500/30 bg-emerald-500/10 p-4 text-xs space-y-1"
          >
            <div class="font-semibold text-sr-ink">Push completed successfully</div>
            <div class="font-mono text-sr-muted">
              Branch: {@push_result[:branch] || @push_result["branch"]}
            </div>
            <div class="font-mono text-sr-muted">
              Commit: {@push_result[:commit_sha] || @push_result["commit_sha"]}
            </div>
            <a
              :if={@push_result[:pr_url] || @push_result["pr_url"]}
              href={@push_result[:pr_url] || @push_result["pr_url"]}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-block font-medium text-sr-brand hover:underline"
            >
              Open Pull / Merge Request &rarr;
            </a>
          </div>

          <.form
            for={to_form(@push_form, as: :push)}
            id="gitops-push-form"
            phx-change="change_gitops_push"
            phx-submit="submit_gitops_push"
            class="space-y-4"
          >
            <label class="flex flex-col gap-1 text-xs">
              <span class="font-medium text-sr-ink">Target GitOps Repository</span>
              <select
                name="push[repository_id]"
                class={ui_field_class(size: "sm", class: "w-full")}
                required
              >
                <option value="">-- Select :gitops_tree repository --</option>
                <option
                  :for={repo <- @gitops_repos}
                  value={repo["id"]}
                  selected={@push_form["repository_id"] == repo["id"]}
                >
                  {repo["name"]} ({repo["provider_type"]} · {repo["branch"]} · {repo["push_strategy"]})
                </option>
              </select>
            </label>

            <label class="flex flex-col gap-1 text-xs">
              <span class="font-medium text-sr-ink">Pack Slug</span>
              <input
                type="text"
                name="push[pack_slug]"
                value={@push_form["pack_slug"]}
                class={ui_field_class(size: "sm", class: "w-full font-mono")}
                required
              />
            </label>

            <label class="flex flex-col gap-1 text-xs">
              <span class="font-medium text-sr-ink">Commit Message</span>
              <input
                type="text"
                name="push[commit_message]"
                value={@push_form["commit_message"]}
                placeholder="chore(packs): sync storage-and-nvr-health"
                class={ui_field_class(size: "sm", class: "w-full")}
                required
              />
            </label>

            <div class="flex items-center justify-end gap-2 pt-2">
              <.ui_button type="button" size="sm" variant="ghost" phx-click="close_gitops_push">
                Close
              </.ui_button>
              <.ui_button id="submit-gitops-push-btn" type="submit" size="sm" variant="primary">
                Push Secret-Free Pack
              </.ui_button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :pull_state, :map, required: true

  def gitops_pull_drawer(assigns) do
    ~H"""
    <div
      :if={@open}
      id="gitops-pull-drawer"
      data-role="gitops-pull-drawer"
      class="fixed inset-0 z-50 flex justify-end bg-black/50 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label="GitOps Pull Dry-Run Promotion"
    >
      <div class="flex h-full w-full max-w-2xl flex-col border-l border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-center justify-between border-b border-sr-line px-6 py-4">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">
              Pull Dry-Run Promotion (dev &rarr; staging &rarr; prod)
            </h2>
            <p class="text-xs text-sr-muted">
              Preview reconciliation changes from a GitOps branch before applying to CNPG.
            </p>
          </div>
          <.ui_button type="button" size="sm" variant="ghost" phx-click="close_gitops_pull">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_button>
        </div>

        <div class="flex-1 overflow-y-auto p-6 space-y-5">
          <div
            :if={@pull_state.error}
            class="rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-xs text-red-700 dark:text-red-300"
          >
            {@pull_state.error}
          </div>

          <.form
            for={to_form(@pull_state.form, as: :pull)}
            id="gitops-pull-form"
            phx-change="change_gitops_pull"
            phx-submit="preview_gitops_pull"
            class="grid grid-cols-1 gap-3 sm:grid-cols-2"
          >
            <label class="flex flex-col gap-1 text-xs">
              <span class="font-medium text-sr-ink">Pack Slug</span>
              <input
                type="text"
                name="pull[slug]"
                value={@pull_state.form["slug"]}
                placeholder="storage-and-nvr-health"
                class={ui_field_class(size: "sm", class: "w-full font-mono")}
                required
              />
            </label>

            <label class="flex flex-col gap-1 text-xs">
              <span class="font-medium text-sr-ink">Branch / Commit SHA (optional)</span>
              <input
                type="text"
                name="pull[ref]"
                value={@pull_state.form["ref"]}
                placeholder="main"
                class={ui_field_class(size: "sm", class: "w-full font-mono")}
              />
            </label>

            <div class="sm:col-span-2 flex justify-end">
              <.ui_button id="run-gitops-pull-preview-btn" type="submit" size="sm" variant="outline">
                Run Dry-Run Preview
              </.ui_button>
            </div>
          </.form>

          <div
            :if={@pull_state.preview}
            id="gitops-pull-preview-result"
            class="rounded-lg border border-sr-line bg-sr-subtle/40 p-4 space-y-3 text-xs"
          >
            <div class="flex items-center justify-between">
              <span class="font-semibold text-sr-ink">
                Preview: {@pull_state.preview[:pack_id] || @pull_state.preview["pack_id"]} v{@pull_state.preview[
                  :pack_version
                ] || @pull_state.preview["pack_version"]}
              </span>
              <.ui_badge variant="info" size="xs">
                commit {String.slice(
                  to_string(@pull_state.preview[:source_commit_sha] || "HEAD"),
                  0,
                  8
                )}
              </.ui_badge>
            </div>
            <p class="text-sr-muted">
              Checks: {length(
                List.wrap(@pull_state.preview[:checks] || @pull_state.preview["checks"])
              )} ·
              Rules: {length(List.wrap(@pull_state.preview[:rules] || @pull_state.preview["rules"]))} ·
              Dashboards: {length(
                List.wrap(@pull_state.preview[:dashboards] || @pull_state.preview["dashboards"])
              )}
            </p>
            <div class="flex justify-end">
              <.ui_button
                id="apply-gitops-pull-btn"
                type="button"
                size="sm"
                variant="primary"
                phx-click="apply_gitops_pull"
              >
                Apply Pull Promotion
              </.ui_button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :open, :boolean, default: false
  attr :upload_error, :string, default: nil
  attr :uploads, :map, required: true

  def import_pack_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      id="import-pack-modal"
      data-role="import-pack-modal"
      class="fixed inset-0 z-50 flex items-center justify-center bg-black/60 p-4 backdrop-blur-xs"
      role="dialog"
      aria-modal="true"
      aria-label="Import Solution Pack"
    >
      <div class="w-full max-w-lg rounded-xl border border-sr-line bg-sr-surface shadow-2xl">
        <div class="flex items-center justify-between border-b border-sr-line px-6 py-4">
          <div>
            <h2 class="text-base font-semibold text-sr-ink">Import .srpack or .json Pack</h2>
            <p class="text-xs text-sr-muted">
              Validates SHA-256 manifest digests, SVG sanitization, and secret-free rules before opening the Guided Install Wizard.
            </p>
          </div>
          <.ui_button type="button" size="sm" variant="ghost" phx-click="close_import_modal">
            <.icon name="hero-x-mark" class="size-5" />
          </.ui_button>
        </div>

        <form
          id="import-pack-form"
          phx-change="validate_upload"
          phx-submit="submit_upload"
          class="p-6 space-y-4"
        >
          <div
            :if={@upload_error}
            class="rounded-lg border border-red-500/40 bg-red-500/10 p-3 text-xs text-red-700 dark:text-red-300"
          >
            {@upload_error}
          </div>

          <div class="rounded-lg border-2 border-dashed border-sr-line bg-sr-subtle/50 p-6 text-center">
            <.live_file_input upload={@uploads.pack_bundle} class="text-xs text-sr-ink" />
            <p class="mt-2 text-xs text-sr-muted">
              Accepts deterministic <code class="font-mono">.srpack</code>
              (tar.zst), <code class="font-mono">.zip</code>, or <code class="font-mono">.json</code>
              pack bundles (max 25 MB, or 32 MB with bundled dashboard modules).
            </p>
          </div>

          <div class="flex items-center justify-end gap-2">
            <.ui_button type="button" size="sm" variant="ghost" phx-click="close_import_modal">
              Cancel
            </.ui_button>
            <.ui_button id="submit-import-pack-btn" type="submit" size="sm" variant="primary">
              Validate & Open Wizard
            </.ui_button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
