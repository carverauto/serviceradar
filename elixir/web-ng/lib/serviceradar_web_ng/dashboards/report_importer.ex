defmodule ServiceRadarWebNG.Dashboards.ReportImporter do
  @moduledoc """
  Imports report definitions from the three sources an add-on package can come
  from: `:first_party`, `:github` and `:upload`.

  ## One path, whatever the source

  Every source ends in `import_definition/4`: size cap, JSON decode,
  `Definition.validate/2`, then `SystemReports.ensure_definition/3`. The sources
  differ only in how they obtain the bytes and what provenance they record, so an
  uploaded report cannot reach the database under looser rules than one fetched
  from a repository.

  ## Import creates, and never rewrites

  Importing a slug that already exists leaves that dashboard exactly as found and
  reports `:kept`, the same rule as the reports this build creates at startup. A
  newer release of a report therefore does not reach an installation where the
  report already exists, customised or not: telling an untouched copy from a
  customised one is not something this module attempts, and guessing wrong would
  discard operator work.

  ## Trust per source

    * `:first_party` reads the index and definitions from the OSS repository at a
      release tag (default: the running release). The repository URL is fixed in
      code rather than supplied by an operator, so the operator's repository
      allowlist and commit-signature policy -- which govern repositories an
      operator nominates -- are not applied. The commit's signature state is still
      recorded.
    * `:github` reads one definition from a repository the operator nominates, and
      is refused unless it passes the same repository-boundary and
      commit-signature policy as a plugin import.
    * `:upload` accepts the bytes directly and records no signature.

  A report is SRQL text plus layout, so there is no renderer artifact to fetch.
  That is why this does not use `Plugins.GithubImporter.fetch_dashboard/1`, which
  requires one. All HTTP goes through `ServiceRadarWebNG.Packages.RepoClient`,
  and so through the egress proxy.
  """

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Dashboards.AuthoredDashboard
  alias ServiceRadarWebNG.Dashboards.Definition
  alias ServiceRadarWebNG.Dashboards.DefinitionLoader
  alias ServiceRadarWebNG.Dashboards.ReportIndex
  alias ServiceRadarWebNG.Dashboards.SystemReports
  alias ServiceRadarWebNG.Packages.RepoClient
  alias ServiceRadarWebNG.Plugins.FirstPartyReleaseClient

  require Ash.Query

  @max_definition_bytes 256 * 1024

  @type outcome :: :created | :completed | :kept
  @type result ::
          {:ok, %{dashboard: AuthoredDashboard.t(), outcome: outcome()}} | {:error, String.t()}

  @doc "Largest definition body accepted from any source."
  @spec max_definition_bytes() :: pos_integer()
  def max_definition_bytes, do: @max_definition_bytes

  @doc """
  Lists the reports a first-party release publishes, marking which are installed.

  Options: `:release_tag` (defaults to the running release, then the default
  branch), `:http_client`.
  """
  @spec list_first_party(keyword()) :: {:ok, map()} | {:error, String.t()}
  def list_first_party(opts \\ []) do
    with {:ok, source} <- resolve_first_party(opts),
         {:ok, entries} <- fetch_first_party_index(source, opts),
         {:ok, installed} <- installed_slugs(Enum.map(entries, & &1.slug)) do
      reports =
        entries
        |> Task.async_stream(
          fn entry ->
            entry
            |> Map.put(:installed?, MapSet.member?(installed, entry.slug))
            |> Map.merge(describe_first_party(source, entry, opts))
          end,
          max_concurrency: 4,
          ordered: true,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(entries)
        |> Enum.map(fn
          {{:ok, report}, _entry} ->
            report

          {{:exit, reason}, entry} ->
            Map.merge(entry, %{
              installed?: MapSet.member?(installed, entry.slug),
              title: entry.slug,
              description: nil,
              panel_count: 0,
              error: "Could not load #{entry.path}: #{inspect(reason)}"
            })
        end)

      {:ok,
       %{
         repo_url: source.repo_url,
         release_tag: source.release_tag,
         commit: source.resolved.sha,
         reports: reports
       }}
    end
  end

  @doc "Imports one report, by slug, from a first-party release. Options as `list_first_party/1`, plus `:scope`."
  @spec import_first_party(String.t(), keyword()) :: result()
  def import_first_party(slug, opts) when is_binary(slug) do
    with {:ok, source} <- resolve_first_party(opts),
         {:ok, entries} <- fetch_first_party_index(source, opts),
         {:ok, entry} <- find_entry(entries, slug, source),
         {:ok, body} <- fetch_first_party_file(source, entry.path, opts) do
      {signature, _verified_at, _key_id, _commit} =
        RepoClient.verification_metadata(source.resolved, source.ref)

      provenance = %{
        source_type: :first_party,
        source_repo_url: source.repo_url,
        source_ref: source.ref,
        source_release_tag: source.release_tag,
        source_commit: source.resolved.sha,
        source_path: ReportIndex.repo_path(entry.path),
        signature: signature
      }

      import_definition(
        body,
        entry.path,
        provenance,
        Keyword.put(opts, :expected_slug, entry.slug)
      )
    end
  end

  @doc """
  Imports one report definition from an operator-nominated GitHub repository.

  `attrs` needs `repo_url` and `path`; `ref` is optional and defaults to the
  repository's default branch.
  """
  @spec import_github(map(), keyword()) :: result()
  def import_github(attrs, opts) when is_map(attrs) do
    repo_url = attr(attrs, :repo_url)
    ref = attr(attrs, :ref)
    http_opts = http_opts(opts)

    with {:ok, repo} <- wrap(RepoClient.parse_repo_url(repo_url)),
         :ok <- wrap(RepoClient.enforce_repo_boundary(repo, http_opts)),
         {:ok, path} <- require_path(attr(attrs, :path)),
         {:ok, resolved} <- wrap(RepoClient.resolve_ref(repo, ref, http_opts)),
         :ok <- wrap(RepoClient.enforce_verification_policy(resolved, http_opts)),
         {:ok, body} <- fetch_file(repo, resolved.sha, path, http_opts) do
      {signature, _verified_at, _key_id, _commit} =
        RepoClient.verification_metadata(resolved, ref)

      provenance = %{
        source_type: :github,
        source_repo_url: repo_url,
        source_ref: ref,
        source_commit: resolved.sha,
        source_path: path,
        signature: signature
      }

      import_definition(body, "#{repo.owner}/#{repo.repo}:#{path}", provenance, opts)
    end
  end

  @doc "Imports an uploaded definition body. `source` names it in errors."
  @spec import_upload(binary(), String.t(), keyword()) :: result()
  def import_upload(body, source, opts) when is_binary(body) and is_binary(source) do
    import_definition(body, source, %{source_type: :upload}, opts)
  end

  @doc """
  The single validation and persistence path every source uses.

  Options: `:scope` (required; the importing operator), `:expected_slug` (refuse
  a definition whose slug differs from what its index advertised).
  """
  @spec import_definition(binary(), String.t(), map(), keyword()) :: result()
  def import_definition(body, source, provenance, opts) when is_binary(body) do
    scope = Keyword.fetch!(opts, :scope)

    with :ok <- check_size(body, source),
         {:ok, decoded} <- decode(body, source),
         {:ok, spec} <- Definition.validate(decoded, source),
         :ok <- check_expected_slug(spec, opts[:expected_slug], source) do
      provenance = Map.put(provenance, :content_hash, DefinitionLoader.sha256(body))

      case SystemReports.ensure_definition(spec, provenance, scope: scope) do
        {:ok, dashboard, outcome} -> {:ok, %{dashboard: dashboard, outcome: outcome}}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  @doc "Human-readable text for an import error."
  @spec format_error(term()) :: String.t()
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(:missing_repo_url), do: "GitHub repository URL is required"

  def format_error(:invalid_repo_url),
    do: "GitHub repository URL is not a valid github.com repository"

  def format_error(:untrusted_repo),
    do:
      "This repository is not in the trusted GitHub repositories or owners configured for imports"

  def format_error(:invalid_ref), do: "Git ref is not a valid branch, tag or commit"
  def format_error(:not_found), do: "Not found in the repository at that ref"

  def format_error(:verification_required),
    do: "The commit is not signed, and imports require a verified signature"

  def format_error(:trusted_signers_not_configured),
    do: "Signed imports are required but no trusted signers are configured"

  def format_error(:untrusted_signer),
    do: "The commit is signed by a signer that is not trusted for imports"

  def format_error({:http_error, status}), do: "GitHub request failed with HTTP #{status}"
  def format_error(:forbidden), do: "Not authorized to create dashboards"
  def format_error(%Ash.Error.Forbidden{}), do: "Not authorized to create dashboards"

  def format_error(%{__exception__: true} = error), do: Exception.message(error)
  def format_error(reason), do: inspect(reason)

  # --- first party -------------------------------------------------------------

  defp resolve_first_party(opts) do
    repo_url = FirstPartyReleaseClient.default_repo_url()

    release_tag =
      normalize_tag(Keyword.get(opts, :release_tag)) || ReportIndex.running_release_tag()

    with {:ok, repo} <- wrap(RepoClient.parse_repo_url(repo_url)),
         {:ok, resolved} <- resolve_first_party_ref(repo, release_tag, opts) do
      {:ok,
       %{
         repo: repo,
         repo_url: repo_url,
         release_tag: release_tag,
         ref: release_tag,
         resolved: resolved
       }}
    end
  end

  defp resolve_first_party_ref(repo, release_tag, opts) do
    case RepoClient.resolve_ref(repo, release_tag, http_opts(opts)) do
      {:ok, resolved} ->
        {:ok, resolved}

      {:error, :not_found} when is_binary(release_tag) ->
        {:error,
         "Release #{release_tag} was not found in #{FirstPartyReleaseClient.default_repo_url()}"}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp fetch_first_party_index(source, opts) do
    index_path = ReportIndex.repo_path(ReportIndex.file_name())

    case RepoClient.fetch_raw(source.repo, source.resolved.sha, index_path, http_opts(opts)) do
      {:ok, body} ->
        ReportIndex.decode(body, "#{release_label(source)} #{ReportIndex.file_name()}")

      {:error, :not_found} ->
        {:error, "#{release_label(source)} does not publish a report index (#{index_path})"}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  defp fetch_first_party_file(source, path, opts) do
    fetch_file(source.repo, source.resolved.sha, ReportIndex.repo_path(path), http_opts(opts))
  end

  defp describe_first_party(source, entry, opts) do
    with {:ok, body} <- fetch_first_party_file(source, entry.path, opts),
         :ok <- check_size(body, entry.path),
         {:ok, decoded} <- decode(body, entry.path),
         {:ok, spec} <- Definition.validate(decoded, entry.path),
         :ok <- check_expected_slug(spec, entry.slug, entry.path) do
      %{
        title: spec.title,
        description: spec.description,
        panel_count: length(spec.panels),
        error: nil
      }
    else
      {:error, reason} -> %{title: entry.slug, description: nil, panel_count: 0, error: reason}
    end
  end

  defp find_entry(entries, slug, source) do
    case Enum.find(entries, &(&1.slug == slug)) do
      nil -> {:error, "#{release_label(source)} does not list a report #{inspect(slug)}"}
      entry -> {:ok, entry}
    end
  end

  defp release_label(%{release_tag: nil}), do: "The default branch"
  defp release_label(%{release_tag: tag}), do: "Release #{tag}"

  # Read as the system actor for the same reason `SystemReports.ensure_definition/3`
  # looks up slugs that way: a dashboard the operator cannot see still owns its
  # slug, and importing it would be kept, not created.
  defp installed_slugs([]), do: {:ok, MapSet.new()}

  defp installed_slugs(slugs) do
    AuthoredDashboard
    |> Ash.Query.filter(slug in ^slugs)
    |> Ash.Query.select([:slug])
    |> Ash.read(actor: SystemActor.system(:report_importer))
    |> case do
      {:ok, dashboards} -> {:ok, MapSet.new(dashboards, & &1.slug)}
      {:error, reason} -> {:error, "Could not check installed reports: #{format_error(reason)}"}
    end
  end

  # --- shared ------------------------------------------------------------------

  defp fetch_file(repo, sha, path, http_opts) do
    case RepoClient.fetch_raw(repo, sha, path, http_opts) do
      {:ok, body} -> {:ok, body}
      {:error, :not_found} -> {:error, "Not found: #{path} at #{String.slice(sha, 0, 12)}"}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  defp check_size(body, source) do
    if byte_size(body) <= @max_definition_bytes do
      :ok
    else
      {:error, "#{source}: definition is larger than #{div(@max_definition_bytes, 1024)} KiB"}
    end
  end

  defp decode(body, source) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, %Jason.DecodeError{} = err} ->
        {:error, "#{source}: invalid JSON (#{Exception.message(err)})"}
    end
  end

  defp check_expected_slug(_spec, nil, _source), do: :ok
  defp check_expected_slug(%{slug: slug}, slug, _source), do: :ok

  defp check_expected_slug(%{slug: slug}, expected, source),
    do:
      {:error,
       "#{source}: slug #{inspect(slug)} does not match its index entry #{inspect(expected)}"}

  defp require_path(path) when is_binary(path) do
    case RepoClient.normalize_repo_path(path, :invalid_definition_path) do
      {:ok, normalized} ->
        if String.ends_with?(normalized, ".json"),
          do: {:ok, normalized},
          else: {:error, "Definition path must name a .json file"}

      {:error, _} ->
        {:error, "Definition path must be a relative path inside the repository"}
    end
  end

  defp require_path(_path), do: {:error, "Definition path is required"}

  defp http_opts(opts) do
    client =
      Keyword.get_lazy(opts, :http_client, fn ->
        Application.get_env(
          :serviceradar_web_ng,
          :github_http_client,
          ServiceRadar.HTTP.EgressClient
        )
      end)

    [http_client: client]
  end

  defp wrap(:ok), do: :ok
  defp wrap({:ok, value}), do: {:ok, value}
  defp wrap({:error, reason}), do: {:error, format_error(reason)}

  defp attr(attrs, key) do
    case Map.get(attrs, key, Map.get(attrs, Atom.to_string(key))) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp normalize_tag(tag) when is_binary(tag) do
    case String.trim(tag) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_tag(_tag), do: nil
end
