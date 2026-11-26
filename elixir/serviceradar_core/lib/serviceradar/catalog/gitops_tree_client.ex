defmodule ServiceRadar.Catalog.GitOpsTreeClient do
  @moduledoc """
  Pure-HTTPS two-way Git directory tree synchronization (`mode: :gitops_tree`)
  for Solution Packs across GitHub, GitLab, and Gitea/Forgejo (`3.3`, Decision 4).

  ## Security & Transport Invariants
  - Uses strictly `ServiceRadar.HTTP.EgressClient.request_json/4` (`redirect: false`,
    `SERVICERADAR_EGRESS_PROXY`, workspace TLS trust anchors). Never invokes a
    host `git` subprocess and never writes SSH deploy keys or PATs to disk.
  - Runs `SecretFreeValidator` and `PackManifest` validation BEFORE emitting any
    Git blob/commit request on push, and AFTER fetching remote blobs on pull.
  - Supports `:pull_request` (creating a fresh branch + PR/MR) and `:direct_commit`
    (with optimistic parent commit SHA checks and `force: false`, returning
    `{:error, {:branch_conflict, details}}` on concurrent upstream branch edits).
  """

  alias ServiceRadar.Catalog.CatalogNotifier
  alias ServiceRadar.Catalog.PackExporter
  alias ServiceRadar.Catalog.PackManifest
  alias ServiceRadar.Catalog.Reconciler
  alias ServiceRadar.Catalog.RepositoryCredentials
  alias ServiceRadar.Catalog.RepoUrl
  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.HTTP.EgressClient

  @max_blob_bytes 8 * 1024 * 1024
  @max_pack_files 256

  @doc """
  Pushes a Solution Pack file map (or export spec) under `<base_path>/<slug>/` in
  `repo` using either `:pull_request` or `:direct_commit` strategy.

  Returns `{:ok, %{commit_sha, branch, pr_url, pack_id, pack_version}}` or
  `{:error, reason}`.
  """
  @spec push_pack(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def push_pack(repo, pack_tree_or_spec, opts \\ [])
      when is_map(repo) and is_map(pack_tree_or_spec) and is_list(opts) do
    with {:ok, file_map} <- normalize_push_tree(pack_tree_or_spec, opts),
         :ok <- SecretFreeValidator.validate_pack_tree(file_map),
         {:ok, validated} <- PackManifest.validate_pack_tree(file_map, opts),
         {:ok, parsed} <- RepoUrl.parse(repo.repo_url, repo.provider_type, :gitops_tree),
         {:ok, token} <- require_token(repo, opts) do
      manifest = validated.manifest
      slug = manifest["slug"]
      version = manifest["version"]
      base_path = normalize_base_path(Map.get(repo, :base_path, "packs"))
      target_branch = Map.get(repo, :branch, "main")
      strategy = Map.get(repo, :push_strategy, :pull_request)
      prefix = "#{base_path}/#{slug}"

      commit_message =
        Keyword.get(
          opts,
          :commit_message,
          "chore(packs): sync #{slug} v#{version}"
        )

      result =
        case parsed.provider do
          :github ->
            push_github(
              parsed,
              target_branch,
              prefix,
              slug,
              version,
              validated.files,
              strategy,
              commit_message,
              token,
              opts
            )

          :gitlab ->
            push_gitlab(
              parsed,
              target_branch,
              prefix,
              slug,
              version,
              validated.files,
              strategy,
              commit_message,
              token,
              opts
            )

          :gitea ->
            push_gitea(
              parsed,
              target_branch,
              prefix,
              slug,
              version,
              validated.files,
              strategy,
              commit_message,
              token,
              opts
            )
        end

      case result do
        {:ok, push_info} ->
          final =
            Map.merge(push_info, %{
              pack_id: manifest["id"],
              slug: slug,
              pack_version: version
            })

          CatalogNotifier.write_operation_audit(:gitops_push,
            resource_type: "solution_pack",
            resource_id: manifest["id"],
            resource_name: manifest["name"],
            actor: Keyword.get(opts, :actor),
            details: %{
              "repo_url" => parsed.repo_url,
              "branch" => final.branch,
              "target_branch" => target_branch,
              "push_strategy" => to_string(strategy),
              "pack_id" => manifest["id"],
              "pack_version" => version,
              "commit_sha" => final.commit_sha,
              "pr_url" => final.pr_url
            }
          )

          {:ok, final}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Lists all valid Solution Packs discovered under `<base_path>/*/manifest.json`
  on `repo.branch` (or `opts[:ref]`).
  """
  @spec list_remote_packs(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_remote_packs(repo, opts \\ []) when is_map(repo) and is_list(opts) do
    ref = Keyword.get(opts, :ref) || Map.get(repo, :branch, "main")
    base_path = normalize_base_path(Map.get(repo, :base_path, "packs"))

    with {:ok, parsed} <- RepoUrl.parse(repo.repo_url, repo.provider_type, :gitops_tree),
         {:ok, token} <- require_token(repo, opts),
         {:ok, commit_sha, tree_entries} <- fetch_provider_tree(parsed, ref, token, opts) do
      manifest_entries =
        Enum.filter(tree_entries, fn entry ->
          case String.split(entry.path, "/") do
            segs when length(segs) >= 2 ->
              dir_prefix = segs |> Enum.drop(-2) |> Enum.join("/")
              manifest_name = List.last(segs)
              dir_prefix == base_path and manifest_name == "manifest.json"

            _ ->
              false
          end
        end)

      packs_res =
        Enum.reduce_while(manifest_entries, {:ok, []}, fn entry, {:ok, acc} ->
          with {:ok, bytes} <- fetch_provider_blob(parsed, commit_sha, entry, token, opts),
               {:ok, decoded} when is_map(decoded) <- Jason.decode(bytes),
               {:ok, normalized} <- PackManifest.validate_manifest(decoded) do
            {:cont, {:ok, [normalized | acc]}}
          else
            _ -> {:cont, {:ok, acc}}
          end
        end)

      {:ok, list} = packs_res

      {:ok,
       %{
         commit_sha: commit_sha,
         branch: ref,
         packs: list |> Enum.reverse() |> Enum.sort_by(& &1["slug"])
       }}
    end
  end

  @doc """
  Fetches and validates a single Solution Pack directory `<base_path>/<slug>/`
  from `repo` at `opts[:ref]` (defaulting to `repo.branch`).
  """
  @spec pull_pack(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def pull_pack(repo, slug, opts \\ []) when is_map(repo) and is_binary(slug) and is_list(opts) do
    if not PackManifest.safe_relative_path?(slug) or String.contains?(slug, "/") do
      {:error, :invalid_pack_slug}
    else
      ref = Keyword.get(opts, :ref) || Map.get(repo, :branch, "main")
      base_path = normalize_base_path(Map.get(repo, :base_path, "packs"))
      prefix = "#{base_path}/#{slug}/"

      with {:ok, parsed} <- RepoUrl.parse(repo.repo_url, repo.provider_type, :gitops_tree),
           {:ok, token} <- require_token(repo, opts),
           {:ok, commit_sha, tree_entries} <- fetch_provider_tree(parsed, ref, token, opts),
           {:ok, pack_entries} <- filter_pack_entries(tree_entries, prefix),
           {:ok, file_map} <-
             download_pack_blobs(parsed, commit_sha, pack_entries, prefix, token, opts),
           :ok <- SecretFreeValidator.validate_pack_tree(file_map),
           {:ok, validated} <- PackManifest.validate_pack_tree(file_map, opts) do
        {:ok,
         %{
           commit_sha: commit_sha,
           branch: ref,
           repo_url: parsed.repo_url,
           pack: validated
         }}
      end
    end
  end

  @doc """
  Computes a dry-run environment promotion preview (`dev -> staging -> prod`)
  from `repo` for `slug` without writing to CNPG.
  """
  @spec preview_pull(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def preview_pull(repo, slug, opts \\ []) do
    params = Keyword.get(opts, :params, %{})

    with {:ok, pulled} <- pull_pack(repo, slug, opts),
         {:ok, plan} <- Reconciler.preview(pulled.pack, params, opts) do
      {:ok,
       Map.merge(plan, %{
         source_commit_sha: pulled.commit_sha,
         source_branch: pulled.branch,
         repo_url: pulled.repo_url
       })}
    end
  end

  @doc """
  Pulls and reconciles `slug` from `repo` inside a CNPG transaction, recording
  `source_commit_sha` on `InstalledSolutionPack` and emitting a redacted OCSF
  audit record.
  """
  @spec apply_pull(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def apply_pull(repo, slug, opts \\ []) do
    raw_params = Keyword.get(opts, :params, %{})

    with {:ok, pulled} <- pull_pack(repo, slug, opts) do
      source_meta = %{
        "source_type" => "gitops_tree",
        "catalog_repository_id" => Map.get(repo, :id),
        "source_commit_sha" => pulled.commit_sha,
        "source_branch" => pulled.branch
      }

      merged_params = Map.put(raw_params, "source", source_meta)

      with {:ok, applied} <- Reconciler.reconcile(pulled.pack, merged_params, opts) do
        manifest = pulled.pack.manifest

        CatalogNotifier.write_operation_audit(:gitops_pull,
          resource_type: "solution_pack",
          resource_id: manifest["id"],
          resource_name: manifest["name"],
          actor: Keyword.get(opts, :actor),
          details: %{
            "repo_url" => pulled.repo_url,
            "branch" => pulled.branch,
            "pack_id" => manifest["id"],
            "pack_version" => manifest["version"],
            "commit_sha" => pulled.commit_sha
          }
        )

        {:ok,
         Map.merge(applied, %{
           source_commit_sha: pulled.commit_sha,
           source_branch: pulled.branch
         })}
      end
    end
  end

  ## GitHub Git Data REST Push

  defp push_github(
         parsed,
         target_branch,
         prefix,
         slug,
         version,
         files,
         strategy,
         commit_message,
         token,
         opts
       ) do
    base = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}"
    headers = github_headers(token)

    with {:ok, ref_doc} <-
           req_json(
             :get,
             "#{base}/git/ref/heads/#{URI.encode(target_branch)}",
             nil,
             headers,
             opts
           ),
         parent_sha when is_binary(parent_sha) <- get_in(ref_doc, ["object", "sha"]),
         {:ok, commit_doc} <-
           req_json(:get, "#{base}/git/commits/#{parent_sha}", nil, headers, opts),
         base_tree_sha when is_binary(base_tree_sha) <- get_in(commit_doc, ["tree", "sha"]),
         {:ok, existing_tree} <-
           req_json(:get, "#{base}/git/trees/#{base_tree_sha}?recursive=1", nil, headers, opts),
         {:ok, blob_entries} <- create_github_blobs(base, prefix, files, headers, opts),
         stale_deletions = compute_stale_tree_deletions(existing_tree, prefix, files),
         {:ok, new_tree} <-
           req_json(
             :post,
             "#{base}/git/trees",
             %{"base_tree" => base_tree_sha, "tree" => blob_entries ++ stale_deletions},
             headers,
             opts
           ),
         new_tree_sha when is_binary(new_tree_sha) <- Map.get(new_tree, "sha"),
         {:ok, created_commit} <-
           req_json(
             :post,
             "#{base}/git/commits",
             %{
               "message" => commit_message,
               "tree" => new_tree_sha,
               "parents" => [parent_sha]
             },
             headers,
             opts
           ),
         commit_sha when is_binary(commit_sha) <- Map.get(created_commit, "sha") do
      finalize_github_push(
        base,
        target_branch,
        slug,
        version,
        commit_sha,
        strategy,
        commit_message,
        headers,
        opts
      )
    else
      nil -> {:error, :invalid_github_git_response}
      {:error, _} = err -> err
    end
  end

  defp create_github_blobs(base, prefix, files, headers, opts) do
    files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {rel_path, content}, {:ok, acc} ->
      payload = %{"content" => Base.encode64(content), "encoding" => "base64"}

      case req_json(:post, "#{base}/git/blobs", payload, headers, opts) do
        {:ok, %{"sha" => blob_sha}} when is_binary(blob_sha) ->
          entry = %{
            "path" => "#{prefix}/#{rel_path}",
            "mode" => "100644",
            "type" => "blob",
            "sha" => blob_sha
          }

          {:cont, {:ok, [entry | acc]}}

        {:ok, _} ->
          {:halt, {:error, :invalid_github_blob_response}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp compute_stale_tree_deletions(existing_tree, prefix, new_files) do
    desired_paths = MapSet.new(new_files, fn {rel, _} -> "#{prefix}/#{rel}" end)
    slash_prefix = prefix <> "/"

    existing_tree
    |> Map.get("tree", [])
    |> Enum.filter(fn item ->
      item["type"] == "blob" and is_binary(item["path"]) and
        String.starts_with?(item["path"], slash_prefix) and
        not MapSet.member?(desired_paths, item["path"])
    end)
    |> Enum.map(fn item ->
      %{
        "path" => item["path"],
        "mode" => "100644",
        "type" => "blob",
        "sha" => nil
      }
    end)
  end

  defp finalize_github_push(
         base,
         target_branch,
         _slug,
         _version,
         commit_sha,
         :direct_commit,
         _commit_message,
         headers,
         opts
       ) do
    url = "#{base}/git/refs/heads/#{URI.encode(target_branch)}"

    case req_json_raw(:patch, url, %{"sha" => commit_sha, "force" => false}, headers, opts) do
      {:ok, %{status: s}} when s in 200..299 ->
        {:ok, %{commit_sha: commit_sha, branch: target_branch, pr_url: nil}}

      {:ok, %{status: s, body: body}} when s in [409, 422] ->
        {:error, {:branch_conflict, body}}

      {:ok, %{status: s, body: body}} ->
        {:error, {:http_status, s, body}}

      {:error, _} = err ->
        err
    end
  end

  defp finalize_github_push(
         base,
         target_branch,
         slug,
         version,
         commit_sha,
         :pull_request,
         commit_message,
         headers,
         opts
       ) do
    pr_branch = pr_branch_name(slug, version, commit_sha)

    with {:ok, _ref} <-
           req_json(
             :post,
             "#{base}/git/refs",
             %{"ref" => "refs/heads/#{pr_branch}", "sha" => commit_sha},
             headers,
             opts
           ),
         {:ok, pr} <-
           req_json(
             :post,
             "#{base}/pulls",
             %{
               "title" => commit_message,
               "head" => pr_branch,
               "base" => target_branch,
               "body" => "Automated secret-free Solution Pack export (`#{slug}` v`#{version}`)."
             },
             headers,
             opts
           ) do
      {:ok,
       %{
         commit_sha: commit_sha,
         branch: pr_branch,
         pr_url: Map.get(pr, "html_url") || Map.get(pr, "url")
       }}
    end
  end

  ## GitLab Commits & Merge Requests REST Push

  defp push_gitlab(
         parsed,
         target_branch,
         prefix,
         slug,
         version,
         files,
         strategy,
         commit_message,
         token,
         opts
       ) do
    proj_id = URI.encode_www_form(parsed.full_path)
    base = "#{parsed.api_base_url}/projects/#{proj_id}"
    headers = gitlab_headers(token)

    with {:ok, branch_doc} <-
           req_json(
             :get,
             "#{base}/repository/branches/#{URI.encode_www_form(target_branch)}",
             nil,
             headers,
             opts
           ),
         parent_sha when is_binary(parent_sha) <- get_in(branch_doc, ["commit", "id"]),
         {:ok, existing_paths} <-
           fetch_gitlab_subtree_paths(base, prefix, parent_sha, headers, opts) do
      actions = build_gitlab_actions(prefix, files, existing_paths)

      commit_branch =
        if strategy == :pull_request,
          do: pr_branch_name(slug, version, parent_sha),
          else: target_branch

      commit_payload =
        maybe_put_start_branch(
          %{
            "branch" => commit_branch,
            "commit_message" => commit_message,
            "actions" => actions,
            "last_commit_id" => parent_sha
          },
          strategy,
          target_branch
        )

      case req_json_raw(:post, "#{base}/repository/commits", commit_payload, headers, opts) do
        {:ok, %{status: s, body: body}} when s in 200..299 and is_map(body) ->
          commit_sha = Map.get(body, "id")

          finalize_gitlab_mr(
            base,
            strategy,
            commit_branch,
            target_branch,
            commit_sha,
            commit_message,
            slug,
            version,
            headers,
            opts
          )

        {:ok, %{status: s, body: body}} when s in [400, 409, 422] ->
          if conflict_message?(body) do
            {:error, {:branch_conflict, body}}
          else
            {:error, {:http_status, s, body}}
          end

        {:ok, %{status: s, body: body}} ->
          {:error, {:http_status, s, body}}

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, :invalid_gitlab_branch_response}
      {:error, _} = err -> err
    end
  end

  defp fetch_gitlab_subtree_paths(base, prefix, ref, headers, opts) do
    url =
      "#{base}/repository/tree?path=#{URI.encode_www_form(prefix)}&recursive=true&per_page=100&ref=#{URI.encode_www_form(ref)}"

    case req_json_raw(:get, url, nil, headers, opts) do
      {:ok, %{status: 200, body: list}} when is_list(list) ->
        paths =
          list
          |> Enum.filter(&(&1["type"] == "blob"))
          |> MapSet.new(& &1["path"])

        {:ok, paths}

      {:ok, %{status: 404}} ->
        {:ok, MapSet.new()}

      {:ok, %{status: s, body: b}} ->
        {:error, {:http_status, s, b}}

      {:error, _} = err ->
        err
    end
  end

  defp build_gitlab_actions(prefix, files, existing_paths) do
    desired =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {rel, content} ->
        full_path = "#{prefix}/#{rel}"
        op = if MapSet.member?(existing_paths, full_path), do: "update", else: "create"

        %{
          "action" => op,
          "file_path" => full_path,
          "encoding" => "base64",
          "content" => Base.encode64(content)
        }
      end)

    desired_set = MapSet.new(desired, & &1["file_path"])

    deletes =
      existing_paths
      |> Enum.reject(&MapSet.member?(desired_set, &1))
      |> Enum.sort()
      |> Enum.map(&%{"action" => "delete", "file_path" => &1})

    desired ++ deletes
  end

  defp maybe_put_start_branch(payload, :pull_request, target_branch),
    do: Map.put(payload, "start_branch", target_branch)

  defp maybe_put_start_branch(payload, _direct, _target_branch), do: payload

  defp finalize_gitlab_mr(
         _base,
         :direct_commit,
         commit_branch,
         _target_branch,
         commit_sha,
         _msg,
         _slug,
         _version,
         _headers,
         _opts
       ) do
    {:ok, %{commit_sha: commit_sha, branch: commit_branch, pr_url: nil}}
  end

  defp finalize_gitlab_mr(
         base,
         :pull_request,
         commit_branch,
         target_branch,
         commit_sha,
         commit_message,
         slug,
         version,
         headers,
         opts
       ) do
    mr_payload = %{
      "source_branch" => commit_branch,
      "target_branch" => target_branch,
      "title" => commit_message,
      "description" => "Automated secret-free Solution Pack export (`#{slug}` v`#{version}`)."
    }

    with {:ok, mr} <- req_json(:post, "#{base}/merge_requests", mr_payload, headers, opts) do
      {:ok,
       %{
         commit_sha: commit_sha,
         branch: commit_branch,
         pr_url: Map.get(mr, "web_url")
       }}
    end
  end

  ## Gitea / Forgejo Atomic Contents Batch & Pulls REST Push

  defp push_gitea(
         parsed,
         target_branch,
         prefix,
         slug,
         version,
         files,
         strategy,
         commit_message,
         token,
         opts
       ) do
    base = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}"
    headers = gitea_headers(token)

    with {:ok, branch_doc} <-
           req_json(:get, "#{base}/branches/#{URI.encode(target_branch)}", nil, headers, opts),
         parent_sha when is_binary(parent_sha) <- get_in(branch_doc, ["commit", "id"]),
         {:ok, tree_doc} <-
           req_json(:get, "#{base}/git/trees/#{parent_sha}?recursive=1", nil, headers, opts) do
      existing_shas = extract_gitea_subtree_shas(tree_doc, prefix)
      file_ops = build_gitea_file_ops(prefix, files, existing_shas)
      pr_branch = if strategy == :pull_request, do: pr_branch_name(slug, version, parent_sha)

      batch_payload =
        maybe_put_gitea_new_branch(
          %{"branch" => target_branch, "message" => commit_message, "files" => file_ops},
          pr_branch
        )

      case req_json_raw(:post, "#{base}/contents", batch_payload, headers, opts) do
        {:ok, %{status: s, body: body}} when s in 200..299 and is_map(body) ->
          commit_sha = get_in(body, ["commit", "sha"]) || parent_sha

          finalize_gitea_pr(
            base,
            strategy,
            pr_branch || target_branch,
            target_branch,
            commit_sha,
            commit_message,
            slug,
            version,
            headers,
            opts
          )

        {:ok, %{status: s, body: body}} when s in [409, 422] ->
          {:error, {:branch_conflict, body}}

        {:ok, %{status: s, body: body}} ->
          {:error, {:http_status, s, body}}

        {:error, _} = err ->
          err
      end
    else
      nil -> {:error, :invalid_gitea_branch_response}
      {:error, _} = err -> err
    end
  end

  defp extract_gitea_subtree_shas(tree_doc, prefix) do
    slash_prefix = prefix <> "/"

    tree_doc
    |> Map.get("tree", [])
    |> Enum.filter(fn item ->
      item["type"] == "blob" and is_binary(item["path"]) and
        String.starts_with?(item["path"], slash_prefix)
    end)
    |> Map.new(&{&1["path"], &1["sha"]})
  end

  defp build_gitea_file_ops(prefix, files, existing_shas) do
    desired =
      files
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {rel, content} ->
        full_path = "#{prefix}/#{rel}"

        case Map.fetch(existing_shas, full_path) do
          {:ok, sha} ->
            %{
              "operation" => "update",
              "path" => full_path,
              "content" => Base.encode64(content),
              "sha" => sha
            }

          :error ->
            %{
              "operation" => "create",
              "path" => full_path,
              "content" => Base.encode64(content)
            }
        end
      end)

    desired_paths = MapSet.new(desired, & &1["path"])

    deletes =
      existing_shas
      |> Enum.reject(fn {p, _} -> MapSet.member?(desired_paths, p) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {p, sha} ->
        %{"operation" => "delete", "path" => p, "sha" => sha}
      end)

    desired ++ deletes
  end

  defp maybe_put_gitea_new_branch(payload, nil), do: payload
  defp maybe_put_gitea_new_branch(payload, branch), do: Map.put(payload, "new_branch", branch)

  defp finalize_gitea_pr(
         _base,
         :direct_commit,
         branch,
         _target,
         commit_sha,
         _msg,
         _slug,
         _version,
         _headers,
         _opts
       ) do
    {:ok, %{commit_sha: commit_sha, branch: branch, pr_url: nil}}
  end

  defp finalize_gitea_pr(
         base,
         :pull_request,
         pr_branch,
         target_branch,
         commit_sha,
         commit_message,
         slug,
         version,
         headers,
         opts
       ) do
    pr_payload = %{
      "title" => commit_message,
      "head" => pr_branch,
      "base" => target_branch,
      "body" => "Automated secret-free Solution Pack export (`#{slug}` v`#{version}`)."
    }

    with {:ok, pr} <- req_json(:post, "#{base}/pulls", pr_payload, headers, opts) do
      {:ok,
       %{
         commit_sha: commit_sha,
         branch: pr_branch,
         pr_url: Map.get(pr, "html_url") || Map.get(pr, "url")
       }}
    end
  end

  ## Tree & Blob Pull Across GitHub, GitLab, Gitea

  defp fetch_provider_tree(%{provider: :github} = parsed, ref, token, opts) do
    base = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}"
    headers = github_headers(token)

    with {:ok, commit_sha} <- resolve_github_commit_sha(base, ref, headers, opts),
         {:ok, tree_doc} <-
           req_json(:get, "#{base}/git/trees/#{commit_sha}?recursive=1", nil, headers, opts) do
      entries =
        tree_doc
        |> Map.get("tree", [])
        |> Enum.filter(&(&1["type"] == "blob"))
        |> Enum.map(fn item ->
          %{path: item["path"], sha: item["sha"], size: item["size"]}
        end)

      {:ok, commit_sha, entries}
    end
  end

  defp fetch_provider_tree(%{provider: :gitlab} = parsed, ref, token, opts) do
    proj_id = URI.encode_www_form(parsed.full_path)
    base = "#{parsed.api_base_url}/projects/#{proj_id}"
    headers = gitlab_headers(token)

    with {:ok, commit_doc} <-
           req_json(
             :get,
             "#{base}/repository/commits/#{URI.encode_www_form(ref)}",
             nil,
             headers,
             opts
           ),
         commit_sha when is_binary(commit_sha) <- Map.get(commit_doc, "id"),
         {:ok, tree_list} <-
           req_json(
             :get,
             "#{base}/repository/tree?recursive=true&per_page=100&ref=#{URI.encode_www_form(commit_sha)}",
             nil,
             headers,
             opts
           ) do
      entries =
        tree_list
        |> List.wrap()
        |> Enum.filter(&(&1["type"] == "blob"))
        |> Enum.map(fn item ->
          %{path: item["path"], sha: item["id"]}
        end)

      {:ok, commit_sha, entries}
    else
      nil -> {:error, :invalid_gitlab_commit_response}
      {:error, _} = err -> err
    end
  end

  defp fetch_provider_tree(%{provider: :gitea} = parsed, ref, token, opts) do
    base = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}"
    headers = gitea_headers(token)

    with {:ok, commit_sha} <- resolve_gitea_commit_sha(base, ref, headers, opts),
         {:ok, tree_doc} <-
           req_json(:get, "#{base}/git/trees/#{commit_sha}?recursive=1", nil, headers, opts) do
      entries =
        tree_doc
        |> Map.get("tree", [])
        |> Enum.filter(&(&1["type"] == "blob"))
        |> Enum.map(fn item ->
          %{path: item["path"], sha: item["sha"], size: item["size"]}
        end)

      {:ok, commit_sha, entries}
    end
  end

  defp resolve_github_commit_sha(base, ref, headers, opts) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/i, ref) do
      {:ok, String.downcase(ref)}
    else
      case req_json(:get, "#{base}/git/ref/heads/#{URI.encode(ref)}", nil, headers, opts) do
        {:ok, %{"object" => %{"sha" => sha}}} when is_binary(sha) -> {:ok, sha}
        {:ok, _} -> {:error, :invalid_github_ref_response}
        {:error, _} = err -> err
      end
    end
  end

  defp resolve_gitea_commit_sha(base, ref, headers, opts) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/i, ref) do
      {:ok, String.downcase(ref)}
    else
      case req_json(:get, "#{base}/branches/#{URI.encode(ref)}", nil, headers, opts) do
        {:ok, %{"commit" => %{"id" => sha}}} when is_binary(sha) -> {:ok, sha}
        {:ok, _} -> {:error, :invalid_gitea_branch_response}
        {:error, _} = err -> err
      end
    end
  end

  defp fetch_provider_blob(%{provider: :github} = parsed, _commit_sha, entry, token, opts) do
    url = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}/git/blobs/#{entry.sha}"

    with {:ok, doc} <- req_json(:get, url, nil, github_headers(token), opts) do
      decode_base64_blob(doc)
    end
  end

  defp fetch_provider_blob(%{provider: :gitlab} = parsed, commit_sha, entry, token, opts) do
    proj_id = URI.encode_www_form(parsed.full_path)
    file_enc = URI.encode_www_form(entry.path)

    url =
      "#{parsed.api_base_url}/projects/#{proj_id}/repository/files/#{file_enc}?ref=#{URI.encode_www_form(commit_sha)}"

    with {:ok, doc} <- req_json(:get, url, nil, gitlab_headers(token), opts) do
      decode_base64_blob(doc)
    end
  end

  defp fetch_provider_blob(%{provider: :gitea} = parsed, _commit_sha, entry, token, opts) do
    url = "#{parsed.api_base_url}/repos/#{parsed.owner}/#{parsed.repo}/git/blobs/#{entry.sha}"

    with {:ok, doc} <- req_json(:get, url, nil, gitea_headers(token), opts) do
      decode_base64_blob(doc)
    end
  end

  defp decode_base64_blob(%{"content" => b64, "encoding" => "base64"}) when is_binary(b64) do
    cleaned = String.replace(b64, ~r/\s+/, "")

    case Base.decode64(cleaned) do
      {:ok, bytes} when byte_size(bytes) <= @max_blob_bytes -> {:ok, bytes}
      {:ok, _} -> {:error, :blob_too_large}
      :error -> {:error, :invalid_blob_encoding}
    end
  end

  defp decode_base64_blob(_other), do: {:error, :invalid_blob_payload}

  defp filter_pack_entries(entries, prefix) do
    matched =
      Enum.filter(entries, fn e ->
        is_binary(e.path) and String.starts_with?(e.path, prefix)
      end)

    cond do
      matched == [] -> {:error, :pack_not_found}
      length(matched) > @max_pack_files -> {:error, :too_many_pack_files}
      true -> {:ok, matched}
    end
  end

  defp download_pack_blobs(parsed, commit_sha, entries, prefix, token, opts) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, acc} ->
      rel = String.replace_prefix(entry.path, prefix, "")

      if PackManifest.safe_relative_path?(rel) do
        case fetch_provider_blob(parsed, commit_sha, entry, token, opts) do
          {:ok, bytes} -> {:cont, {:ok, Map.put(acc, rel, bytes)}}
          {:error, _} = err -> {:halt, err}
        end
      else
        {:halt, {:error, {:unsafe_remote_path, entry.path}}}
      end
    end)
  end

  ## Transport & Auth Helpers

  defp normalize_push_tree(%{"manifest.json" => _} = tree, _opts) do
    {:ok, Map.new(tree, fn {k, v} -> {to_string(k), v} end)}
  end

  defp normalize_push_tree(%{manifest: _} = validated, _opts) when is_map(validated.files) do
    {:ok, validated.files}
  end

  defp normalize_push_tree(export_spec, opts) do
    PackExporter.export_tree(export_spec, opts)
  end

  defp require_token(repo, opts) do
    case Keyword.get(opts, :token) do
      tok when is_binary(tok) and tok != "" ->
        {:ok, tok}

      _ ->
        case RepositoryCredentials.fetch_token(repo, opts) do
          {:ok, tok} when is_binary(tok) and tok != "" -> {:ok, tok}
          {:ok, nil} -> {:error, :credential_required}
          {:error, _} = err -> err
        end
    end
  end

  defp req_json(method, url, body, headers, opts) do
    case req_json_raw(method, url, body, headers, opts) do
      {:ok, %{status: s, body: decoded}} when s in 200..299 ->
        {:ok, decoded}

      {:ok, %{status: s, body: err_body}} ->
        {:error, {:http_status, s, err_body}}

      {:error, _} = err ->
        err
    end
  end

  defp req_json_raw(method, url, body, headers, opts) do
    egress_opts =
      opts
      |> Keyword.take([
        :proxy,
        :cacerts,
        :cacertfile,
        :receive_timeout,
        :connect_timeout,
        :http_json_client,
        :max_bytes,
        :max_request_bytes,
        :validate_origin
      ])
      |> Keyword.put(:headers, headers)
      |> Keyword.put(:redirect, false)

    EgressClient.request_json(method, url, body, egress_opts)
  end

  defp github_headers(token) do
    [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "ServiceRadar-GitOps/1.0"}
    ]
  end

  defp gitlab_headers(token) do
    [
      {"private-token", token},
      {"accept", "application/json"},
      {"user-agent", "ServiceRadar-GitOps/1.0"}
    ]
  end

  defp gitea_headers(token) do
    [
      {"authorization", "token #{token}"},
      {"accept", "application/json"},
      {"user-agent", "ServiceRadar-GitOps/1.0"}
    ]
  end

  defp normalize_base_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.trim("/")
    |> case do
      "" -> "packs"
      s -> s
    end
  end

  defp pr_branch_name(slug, version, sha) do
    short_sha = sha |> to_string() |> String.slice(0, 7)
    clean_ver = String.replace(version, ~r/[^A-Za-z0-9._-]/, "-")
    "serviceradar/pack-#{slug}-v#{clean_ver}-#{short_sha}"
  end

  defp conflict_message?(body) when is_map(body) do
    msg = (Map.get(body, "message") || "") |> to_string() |> String.downcase()

    String.contains?(msg, [
      "stale",
      "commit",
      "refresh",
      "diverged",
      "already exists",
      "fast-forward"
    ])
  end

  defp conflict_message?(body) when is_binary(body) do
    down = String.downcase(body)
    String.contains?(down, ["stale", "fast-forward", "conflict", "diverged"])
  end

  defp conflict_message?(_), do: false
end
