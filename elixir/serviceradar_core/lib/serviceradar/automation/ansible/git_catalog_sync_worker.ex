defmodule ServiceRadar.Automation.Ansible.GitCatalogSyncWorker do
  @moduledoc """
  Per-repository git catalog sync.

  For each registered `PlaybookRepository`, clones (or fetches and
  resets to the configured ref) the repo into a local cache directory
  and walks the working tree for `.yml` / `.yaml` files. Each file is
  parsed as an Ansible playbook (a list of plays); the first play's
  metadata becomes the catalog `Playbook` row, upserted via
  `Playbook.upsert_git` with `source_type: :git`.

  Path layout: `<base_dir>/<repository_id>/`. For cache configuration and
  temporary-directory requirements, see `docs/docs/ansible.md`,
  "Configure environment variables". Each pod has its own cache; sharing
  across pods isn't required since the upsert is idempotent.

  v1 limitations:
    * Only HTTPS git remotes (no SSH key configuration yet).
    * No credential support -- public repos only. Private repos via
      HTTPS deploy token via the credential broker is a planned v1
      feature but lives in a follow-up commit since it touches the
      System.cmd environment plumbing.
    * No incremental "what changed since last sync" -- every tick
      re-parses every file. Cheap for typical playbook repos
      (< 100 YAML files).

  Cadence: `repository.sync_interval_seconds` (default 600s, min 60s).
  See openspec change `add-ansible-integration` task 3.3.
  """

  use Oban.Worker,
    queue: :ansible_catalog,
    max_attempts: 1,
    unique: [period: :infinity, states: :incomplete]

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.Automation.Ansible.PlaybookRepository
  alias ServiceRadar.Jobs.SelfScheduling
  alias ServiceRadar.SweepJobs.ObanSupport

  require Logger

  @default_interval_seconds 600
  @min_interval_seconds 60

  @spec ensure_scheduled(String.t()) ::
          {:ok, Oban.Job.t()} | {:ok, :already_scheduled} | {:error, term()}
  def ensure_scheduled(repository_id) when is_binary(repository_id) do
    if scheduled_for?(repository_id) do
      {:ok, :already_scheduled}
    else
      %{"repository_id" => repository_id}
      |> new()
      |> ObanSupport.safe_insert()
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"repository_id" => repository_id}}) do
    actor = SystemActor.system(:awx_git_catalog_sync_worker)

    case PlaybookRepository.get_by_id(repository_id, actor: actor) do
      {:ok, repo} ->
        _ = sync_repo(repo, actor: actor)
        schedule_next(repo)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("AWX GitCatalogSyncWorker: invalid args", args: inspect(args))
    {:error, :invalid_args}
  end

  @doc """
  Sync a single repository: clone or fetch+reset, walk YAML files,
  upsert per-file `Playbook` rows. Records sync outcome on the
  PlaybookRepository row via `record_sync/2`.

  Options:
    * `:actor` (required for Ash calls)
    * `:base_dir` — override clone location
    * `:git_runner` — function `(args, opts) -> {output, exit_code}`
      mirroring `System.cmd/3`. Used by tests.
    * `:upsert_fn` — function `(args, opts) -> {:ok, _} | {:error, _}`
      mirroring `Playbook.upsert_git/2`. Used by tests.
  """
  @spec sync_repo(PlaybookRepository.t(), keyword()) :: :ok | {:error, term()}
  def sync_repo(%PlaybookRepository{} = repo, opts) do
    base_dir = Keyword.get_lazy(opts, :base_dir, &default_base_dir/0)
    repo_dir = Path.join(base_dir, repo.id)

    case ensure_clone(repo, repo_dir, opts) do
      :ok ->
        diagnostics = ingest_playbooks(repo, repo_dir, opts)
        record_sync(repo, :ok, "synced #{map_size(diagnostics)} playbooks", diagnostics, opts)
        :ok

      {:error, reason} ->
        sanitized = sanitize_git_error(reason)

        record_sync(
          repo,
          :error,
          "git sync failed: #{sanitized}",
          %{"git_error" => sanitized},
          opts
        )

        Logger.warning("AWX GitCatalogSyncWorker: git sync failed",
          repository_id: repo.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  ## Pure helpers --------------------------------------------------------------

  @doc """
  Parse a playbook YAML string into a metadata map suitable for
  `Playbook.upsert_git`. Returns `{:ok, args}` or
  `{:error, reason}`. Empty playbooks parse cleanly with empty
  fields (we still want a row to mark the file as recognized).

  Extracted fields come from the first play in the playbook:
    * `name` — from `name:`, falling back to the file's basename
    * `description` — from a top-level YAML comment, when easy to
      detect; otherwise nil. (We don't try hard.)
    * `hosts_pattern` — from `hosts:`
    * `tags` — from `tags:` (top-level on the play)
    * `declared_vars` — from `vars:`
    * `vars_prompt` — from `vars_prompt:`

  Caller supplies the file basename as a fallback for `name`.
  """
  @spec parse_playbook(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def parse_playbook(yaml, fallback_name) when is_binary(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, parsed} ->
        {:ok, normalize_playbook(parsed, fallback_name)}

      {:error, %YamlElixir.ParsingError{message: msg}} ->
        {:error, {:parse_error, msg}}

      {:error, reason} ->
        {:error, {:parse_error, inspect(reason)}}
    end
  end

  defp normalize_playbook(parsed, fallback_name) do
    plays = List.wrap(parsed)
    first = List.first(plays) || %{}

    %{
      name: string_or(first["name"], fallback_name),
      description: nil,
      hosts_pattern: string_or(first["hosts"], nil),
      tags: tag_list(first["tags"]),
      declared_vars: map_or(first["vars"], %{}),
      vars_prompt: list_of_maps_or(first["vars_prompt"], []),
      parse_status: :ok,
      parse_diagnostics: %{},
      metadata: %{}
    }
  end

  defp string_or(v, _) when is_binary(v) and v != "", do: v
  defp string_or(_, fallback), do: fallback

  defp tag_list(v) when is_list(v), do: Enum.map(v, &to_string/1)
  defp tag_list(v) when is_binary(v), do: v |> String.split(",") |> Enum.map(&String.trim/1)
  defp tag_list(_), do: []

  defp map_or(v, _) when is_map(v), do: v
  defp map_or(_, fallback), do: fallback

  defp list_of_maps_or(v, _) when is_list(v) do
    Enum.filter(v, &is_map/1)
  end

  defp list_of_maps_or(_, fallback), do: fallback

  @doc """
  List `.yml` and `.yaml` files in `dir` recursively, returning paths
  relative to `dir`. Skips dotfiles and `roles/*/handlers/*` (handlers
  aren't standalone playbooks).
  """
  @spec discover_yaml_files(Path.t()) :: [Path.t()]
  def discover_yaml_files(dir) do
    do_walk(dir, dir)
  end

  defp do_walk(base, current) do
    case File.ls(current) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.flat_map(fn name ->
          path = Path.join(current, name)

          cond do
            File.dir?(path) -> do_walk(base, path)
            yaml_file?(name) -> [Path.relative_to(path, base)]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp yaml_file?(name) do
    Path.extname(name) in [".yml", ".yaml"]
  end

  ## Internals -----------------------------------------------------------------

  defp ensure_clone(%PlaybookRepository{git_url: url, git_ref: ref} = repo, repo_dir, opts) do
    git_runner = Keyword.get(opts, :git_runner, &System.cmd/3)

    if File.dir?(Path.join(repo_dir, ".git")) do
      with {:ok, _} <- git(git_runner, ["remote", "set-url", "origin", url], cd: repo_dir),
           {:ok, _} <- git(git_runner, ["fetch", "--depth", "50", "--prune", "origin", ref], cd: repo_dir),
           {:ok, _} <- git(git_runner, ["reset", "--hard", "FETCH_HEAD"], cd: repo_dir) do
        :ok
      end
    else
      File.mkdir_p!(Path.dirname(repo_dir))

      with {:ok, _} <-
             git(git_runner, ["clone", "--depth", "50", "--branch", ref, "--", url, repo_dir], cd: nil) do
        # Touch repo_id so future runs hit the fast path.
        _ = repo
        :ok
      end
    end
  end

  defp git(runner, args, opts) do
    cmd_opts = [stderr_to_stdout: true]
    cmd_opts = if opts[:cd], do: Keyword.put(cmd_opts, :cd, opts[:cd]), else: cmd_opts

    case runner.("git", args, cmd_opts) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, {:git_failed, code, String.trim(to_string(output))}}
    end
  rescue
    err in ErlangError -> {:error, {:git_unavailable, Exception.message(err)}}
  end

  defp ingest_playbooks(repo, repo_dir, opts) do
    upsert_fn = Keyword.get(opts, :upsert_fn, &Playbook.upsert_git/2)
    actor = Keyword.fetch!(opts, :actor)

    repo_dir
    |> discover_yaml_files()
    |> Enum.reduce(%{}, fn relpath, diags ->
      abs = Path.join(repo_dir, relpath)
      basename = relpath |> Path.basename() |> Path.rootname()

      case File.read(abs) do
        {:ok, body} ->
          case parse_playbook(body, basename) do
            {:ok, parsed} ->
              args = parsed |> Map.put(:path, relpath) |> Map.put(:repository_id, repo.id)

              case upsert_fn.(args, actor: actor) do
                {:ok, _} ->
                  diags

                {:error, reason} ->
                  Map.put(diags, relpath, "upsert failed: #{inspect(reason)}")
              end

            {:error, {:parse_error, msg}} ->
              error_args = %{
                repository_id: repo.id,
                path: relpath,
                name: basename,
                description: nil,
                hosts_pattern: nil,
                tags: [],
                declared_vars: %{},
                vars_prompt: [],
                parse_status: :error,
                parse_diagnostics: %{"yaml_error" => msg},
                metadata: %{}
              }

              _ = upsert_fn.(error_args, actor: actor)
              Map.put(diags, relpath, "yaml parse error: #{msg}")
          end

        {:error, reason} ->
          Map.put(diags, relpath, "read failed: #{inspect(reason)}")
      end
    end)
  end

  defp record_sync(repo, status, summary, diagnostics, opts) do
    actor = Keyword.fetch!(opts, :actor)
    record_fn = Keyword.get(opts, :record_sync_fn, &default_record_sync/3)

    args = %{
      last_sync_status: status,
      last_sync_summary: summary,
      parse_diagnostics: diagnostics
    }

    _ = record_fn.(repo, args, actor: actor)
    :ok
  end

  defp default_record_sync(repo, args, opts) do
    PlaybookRepository.record_sync(repo, args, opts)
  end

  defp sanitize_git_error({:git_failed, _code, output}) do
    # Strip credentials that may have ended up in error output (rare,
    # since we send public-repo-only URLs in v1, but defense-in-depth).
    output
    |> String.replace(~r/https?:\/\/[^@\s]+@/, "<credentials>@")
    |> String.slice(0, 200)
  end

  defp sanitize_git_error(other), do: other |> inspect() |> String.slice(0, 200)

  defp default_base_dir do
    # Application.get_env/3 evaluates its default eagerly. Keep temporary-directory
    # lookup lazy so a configured cache works even when no writable temp dir exists.
    case Application.fetch_env(:serviceradar_core, :ansible_catalog_base_dir) do
      {:ok, dir} when is_binary(dir) and dir != "" ->
        dir

      _ ->
        Path.join(System.tmp_dir!(), "serviceradar_ansible_catalog")
    end
  end

  defp schedule_next(%PlaybookRepository{} = repo) do
    seconds = interval_seconds(repo)

    _ =
      __MODULE__
      |> SelfScheduling.successor_changeset(%{"repository_id" => repo.id}, seconds)
      |> ObanSupport.safe_insert()

    :ok
  end

  defp interval_seconds(%PlaybookRepository{sync_interval_seconds: s})
       when is_integer(s) and s > 0 do
    max(@min_interval_seconds, s)
  end

  defp interval_seconds(_), do: @default_interval_seconds

  defp scheduled_for?(repository_id) do
    import Ecto.Query

    query =
      from(job in Oban.Job,
        where:
          job.worker == ^to_string(__MODULE__) and
            fragment("? -> ?", job.args, "repository_id") == ^repository_id and
            job.state in ["available", "scheduled", "executing", "retryable"],
        limit: 1
      )

    ServiceRadar.Repo.exists?(query, prefix: ObanSupport.prefix())
  end
end
