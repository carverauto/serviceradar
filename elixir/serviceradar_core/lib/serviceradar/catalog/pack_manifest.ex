defmodule ServiceRadar.Catalog.PackManifest do
  @moduledoc """
  `pack_format_version: 1` validator, parameter resolver, and resource schema
  verifier for Solution Packs (`2.1`, Decision 1).
  """

  alias ServiceRadar.Catalog.SecretFreeValidator
  alias ServiceRadar.Catalog.SvgSanitizer
  alias ServiceRadar.Dashboards.DashboardPanel
  alias ServiceRadar.DeclarativeChecks.CanonicalJSON
  alias ServiceRadar.DeclarativeChecks.SchemaValidator
  alias ServiceRadar.Observability.StatefulAlertEngine.RuleMatcher

  @supported_format_version 1
  @pack_id_regex ~r/\A[a-z][a-z0-9-]*(\.[a-z0-9][a-z0-9-]*)+\z/
  @slug_regex ~r/\A[a-z0-9][a-z0-9-]{0,126}\z/
  @dashboard_slug_regex ~r/\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/
  @hex64_regex ~r/\A[0-9a-f]{64}\z/
  @key_regex ~r/\A[a-zA-Z][a-zA-Z0-9_.-]{0,126}\z/

  @allowed_config_types ~w(string integer number boolean duration_seconds srql_filter)
  @allowed_rule_kinds ~w(stateful_alert_rule event_rule zen_rule)
  @allowed_install_states ~w(enabled paused)
  @allowed_stateful_signals ~w(log event metric alert health)
  @allowed_event_source_types ~w(log metric)
  @allowed_zen_formats ~w(json protobuf otel_metrics)
  @grid_columns 12

  @type diagnostic :: %{
          file: String.t(),
          path: String.t(),
          code: String.t(),
          message: String.t()
        }

  @doc "Supported `pack_format_version` integer."
  @spec supported_format_version() :: pos_integer()
  def supported_format_version, do: @supported_format_version

  @doc """
  Computes the lowercase 64-character SHA-256 hex digest of raw bytes.
  """
  @spec sha256_hex(binary()) :: String.t()
  def sha256_hex(bytes) when is_binary(bytes) do
    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end

  @doc """
  Validates a decoded `manifest.json` map (`pack_format_version: 1`) and returns
  `{:ok, normalized_manifest}` or `{:error, [diagnostic()]}`.
  """
  @spec validate_manifest(term()) :: {:ok, map()} | {:error, [diagnostic()]}
  def validate_manifest(raw) when is_map(raw) do
    doc = stringify_keys(raw)

    diags =
      []
      |> check_format_version(doc)
      |> check_pack_id(doc)
      |> check_slug(doc)
      |> check_required_string(doc, "name")
      |> check_semver(doc, "version", true)
      |> check_semver(doc, "min_serviceradar_version", false)
      |> check_categories(doc)
      |> check_icon(doc)
      |> check_config_descriptors(doc)
      |> check_credential_slots(doc)
      |> check_plugin_dependencies(doc)
      |> check_resources(doc)
      |> check_files_table(doc)

    case diags do
      [] ->
        {:ok, normalize_manifest_doc(doc)}

      errs ->
        {:error, Enum.reverse(errs)}
    end
  end

  def validate_manifest(_other) do
    {:error, [diag("manifest.json", "$", "invalid_type", "manifest.json must be a JSON object")]}
  end

  @doc """
  Validates an entire Solution Pack directory map (`%{relative_path => binary}`),
  checking path safety, unlisted files, SHA-256 digests against `manifest.files`,
  `SecretFreeValidator`, SVG/Markdown sanitization, and every check, rule, and
  dashboard schema.
  """
  @spec validate_pack_tree(map(), keyword()) :: {:ok, map()} | {:error, [diagnostic()]}
  def validate_pack_tree(raw_files, opts \\ []) when is_map(raw_files) and is_list(opts) do
    with {:ok, files} <- normalize_file_tree(raw_files),
         :ok <- wrap_secret_check(files),
         {:ok, manifest_bytes} <- fetch_manifest_bytes(files),
         {:ok, raw_manifest} <- decode_json_file("manifest.json", manifest_bytes),
         {:ok, manifest} <- validate_manifest(raw_manifest),
         :ok <- verify_file_digests(files, manifest["files"]),
         {:ok, default_params} <- extract_default_params(manifest["config"]),
         {:ok, parsed_resources} <- validate_all_resources(files, manifest, default_params, opts),
         :ok <- validate_auxiliary_files(files) do
      {:ok,
       %{
         manifest: manifest,
         files: files,
         checks: parsed_resources.checks,
         rules: parsed_resources.rules,
         dashboards: parsed_resources.dashboards
       }}
    end
  end

  @doc """
  Validates operator-supplied `config` values against `manifest["config"]`
  descriptors (`type`, `required`, `min`, `max`, `enum`), merging defaults for
  omitted optional parameters.
  """
  @spec validate_config_values([map()], map()) ::
          {:ok, %{String.t() => term()}} | {:error, [diagnostic()]}
  def validate_config_values(descriptors, supplied)
      when is_list(descriptors) and is_map(supplied) do
    supplied_str = Map.new(supplied, fn {k, v} -> {to_string(k), v} end)
    declared_keys = MapSet.new(descriptors, & &1["key"])

    unknown_diags =
      supplied_str
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(declared_keys, &1))
      |> Enum.map(fn k ->
        diag(
          "config",
          "$.config.#{k}",
          "unknown_config_key",
          "undeclared config parameter #{inspect(k)}"
        )
      end)

    {resolved, diags} =
      Enum.reduce(descriptors, {%{}, Enum.reverse(unknown_diags)}, fn desc, {acc, errs} ->
        key = desc["key"]
        has_supplied? = Map.has_key?(supplied_str, key) and not is_nil(Map.get(supplied_str, key))
        raw_val = if has_supplied?, do: Map.get(supplied_str, key), else: Map.get(desc, "default")

        cond do
          is_nil(raw_val) and Map.get(desc, "required", false) == true ->
            {acc,
             [
               diag(
                 "config",
                 "$.config.#{key}",
                 "required_config_missing",
                 "parameter #{inspect(key)} is required"
               )
               | errs
             ]}

          is_nil(raw_val) ->
            {acc, errs}

          true ->
            case coerce_and_check_config_value(raw_val, desc, "$.config.#{key}") do
              {:ok, coerced} -> {Map.put(acc, key, coerced), errs}
              {:error, d} -> {acc, [d | errs]}
            end
        end
      end)

    case diags do
      [] -> {:ok, resolved}
      errs -> {:error, Enum.reverse(errs)}
    end
  end

  @doc """
  Resolves `{"$pack_param": "<key>"}` typed parameter references throughout a
  resource template map using `resolved_params`. Fails closed if an undeclared
  parameter key is referenced.
  """
  @spec resolve_pack_params(term(), map(), String.t()) ::
          {:ok, term()} | {:error, [diagnostic()]}
  def resolve_pack_params(template, resolved_params, file \\ "resource.json")
      when is_map(resolved_params) do
    case do_resolve_params(template, resolved_params, file, "$") do
      {resolved, []} -> {:ok, resolved}
      {_resolved, errs} -> {:error, Enum.reverse(errs)}
    end
  end

  @doc """
  Refreshes `manifest["files"]` with sorted lowercase SHA-256 digests of every
  non-`manifest.json` binary in `file_map` and encodes `manifest.json` as
  deterministic 2-space pretty canonical JSON.
  """
  @spec refresh_manifest_digests(map(), map()) :: {:ok, map(), map()} | {:error, term()}
  def refresh_manifest_digests(manifest, file_map) when is_map(manifest) and is_map(file_map) do
    digests =
      file_map
      |> Enum.reject(fn {k, _} -> to_string(k) == "manifest.json" end)
      |> Map.new(fn {k, bytes} -> {to_string(k), sha256_hex(bytes)} end)

    updated_manifest =
      manifest
      |> stringify_keys()
      |> Map.put("files", digests)

    manifest_json = CanonicalJSON.encode_pretty(updated_manifest)

    updated_files =
      file_map
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("manifest.json", manifest_json)

    {:ok, updated_manifest, updated_files}
  end

  @doc "Validates a portable dashboard definition map (`version: 1`)."
  @spec validate_dashboard_doc(map(), String.t()) :: {:ok, map()} | {:error, [diagnostic()]}
  def validate_dashboard_doc(raw, file) when is_map(raw) do
    doc = stringify_keys(raw)
    slug = Map.get(doc, "slug")
    title = Map.get(doc, "title")
    version = Map.get(doc, "version")
    panels = Map.get(doc, "panels")

    diags =
      []
      |> check_if(
        version != 1,
        file,
        "$.version",
        "unsupported_dashboard_version",
        "dashboard version must be 1"
      )
      |> check_if(
        not (is_binary(slug) and Regex.match?(@dashboard_slug_regex, slug)),
        file,
        "$.slug",
        "invalid_slug",
        "dashboard slug #{inspect(slug)} must match ^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"
      )
      |> check_if(
        not (is_binary(title) and String.trim(title) != ""),
        file,
        "$.title",
        "missing_title",
        "dashboard title must be a non-empty string"
      )

    panel_diags = validate_dashboard_panels(panels, file)
    all_diags = Enum.reverse(diags, panel_diags)

    if all_diags == [] do
      {:ok, doc}
    else
      {:error, all_diags}
    end
  end

  @doc "Validates a rule template map for `stateful_alert_rule`, `event_rule`, or `zen_rule`."
  @spec validate_rule_doc(map(), String.t(), String.t()) ::
          {:ok, map()} | {:error, [diagnostic()]}
  def validate_rule_doc(raw, expected_kind, file) when is_map(raw) do
    doc = stringify_keys(raw)
    kind = Map.get(doc, "kind", expected_kind)
    name = Map.get(doc, "name")
    install_state = Map.get(doc, "install_state", "enabled")

    base_diags =
      []
      |> check_if(
        kind != expected_kind or kind not in @allowed_rule_kinds,
        file,
        "$.kind",
        "invalid_rule_kind",
        "rule kind #{inspect(kind)} must match #{inspect(expected_kind)}"
      )
      |> check_if(
        not (is_binary(name) and String.trim(name) != ""),
        file,
        "$.name",
        "missing_name",
        "rule name must be a non-empty string"
      )
      |> check_if(
        install_state not in @allowed_install_states,
        file,
        "$.install_state",
        "invalid_install_state",
        "install_state must be \"enabled\" or \"paused\", got #{inspect(install_state)}"
      )

    kind_diags = validate_rule_kind_fields(doc, expected_kind, file)
    all_diags = Enum.reverse(base_diags, kind_diags)

    if all_diags == [] do
      {:ok, Map.put_new(doc, "install_state", install_state)}
    else
      {:error, all_diags}
    end
  end

  ## Private helpers

  defp normalize_file_tree(raw_files) do
    {map, errs} =
      Enum.reduce(raw_files, {%{}, []}, fn {raw_path, content}, {acc, diags} ->
        path = to_string(raw_path)

        cond do
          not safe_relative_path?(path) ->
            {acc,
             [
               diag(path, "$", "unsafe_path", "unsafe or traversal file path #{inspect(path)}")
               | diags
             ]}

          Map.has_key?(acc, path) ->
            {acc,
             [
               diag(path, "$", "duplicate_path", "duplicate archive path #{inspect(path)}")
               | diags
             ]}

          not is_binary(content) ->
            {acc, [diag(path, "$", "invalid_content", "file content must be binary") | diags]}

          true ->
            {Map.put(acc, path, content), diags}
        end
      end)

    case errs do
      [] -> {:ok, map}
      list -> {:error, Enum.reverse(list)}
    end
  end

  @doc "Checks whether `path` is a safe normalized relative POSIX path."
  @spec safe_relative_path?(term()) :: boolean()
  def safe_relative_path?(path) when is_binary(path) do
    trimmed = path

    cond do
      trimmed == "" or byte_size(trimmed) > 240 ->
        false

      String.starts_with?(trimmed, "/") or String.ends_with?(trimmed, "/") ->
        false

      String.contains?(trimmed, ["\\", <<0>>]) ->
        false

      true ->
        segments = String.split(trimmed, "/")

        segments != [] and
          Enum.all?(segments, fn seg ->
            seg != "" and seg not in [".", ".."]
          end)
    end
  end

  def safe_relative_path?(_other), do: false

  defp wrap_secret_check(files) do
    case SecretFreeValidator.validate_pack_tree(files) do
      :ok -> :ok
      {:error, violations} -> {:error, violations}
    end
  end

  defp fetch_manifest_bytes(files) do
    case Map.fetch(files, "manifest.json") do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        {:error,
         [diag("manifest.json", "$", "missing_manifest", "pack is missing root manifest.json")]}
    end
  end

  defp decode_json_file(path, bytes) do
    case Jason.decode(bytes) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error,
         [diag(path, "$", "invalid_json_root", "#{path} root value must be a JSON object")]}

      {:error, err} ->
        {:error,
         [diag(path, "$", "invalid_json", "#{path}: invalid JSON (#{Exception.message(err)})")]}
    end
  end

  defp verify_file_digests(files, declared_files) when is_map(declared_files) do
    actual_paths = files |> Map.keys() |> List.delete("manifest.json") |> MapSet.new()
    declared_paths = declared_files |> Map.keys() |> MapSet.new()

    unlisted =
      actual_paths
      |> MapSet.difference(declared_paths)
      |> Enum.sort()
      |> Enum.map(fn p ->
        diag(p, "$.files", "unlisted_file", "file #{inspect(p)} is omitted from manifest.files")
      end)

    missing =
      declared_paths
      |> MapSet.difference(actual_paths)
      |> Enum.sort()
      |> Enum.map(fn p ->
        diag(
          p,
          "$.files",
          "missing_file",
          "file #{inspect(p)} listed in manifest.files is missing from pack"
        )
      end)

    mismatched =
      declared_paths
      |> MapSet.intersection(actual_paths)
      |> Enum.sort()
      |> Enum.flat_map(fn p ->
        expected = String.downcase(Map.fetch!(declared_files, p))
        actual = sha256_hex(Map.fetch!(files, p))

        if actual == expected do
          []
        else
          [
            diag(
              p,
              "$.files.#{p}",
              "digest_mismatch",
              "SHA-256 digest mismatch for #{p}: expected #{expected}, got #{actual}"
            )
          ]
        end
      end)

    case unlisted ++ missing ++ mismatched do
      [] -> :ok
      errs -> {:error, errs}
    end
  end

  defp extract_default_params(descriptors) do
    validate_config_values(descriptors, %{})
  end

  defp validate_all_resources(files, manifest, default_params, opts) do
    resources = manifest["resources"]

    with {:ok, checks} <-
           validate_check_entries(
             files,
             Map.get(resources, "checks", []),
             manifest,
             default_params,
             opts
           ),
         {:ok, rules} <-
           validate_rule_entries(files, Map.get(resources, "rules", []), default_params),
         {:ok, dashboards} <-
           validate_dashboard_entries(files, Map.get(resources, "dashboards", []), default_params) do
      {:ok, %{checks: checks, rules: rules, dashboards: dashboards}}
    end
  end

  defp validate_check_entries(files, entries, manifest, default_params, opts) do
    val_opts =
      if Keyword.get(opts, :skip_srql_nif?, true),
        do: [skip_srql_nif?: true],
        else: []

    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      file = entry["file"]
      expected_slug = entry["slug"]

      with {:ok, bytes} <- fetch_resource_file(files, file),
           {:ok, raw_doc} <- decode_json_file(file, bytes),
           {:ok, resolved_doc} <- resolve_pack_params(raw_doc, default_params, file),
           stamped_doc =
             resolved_doc
             |> Map.put_new("pack_id", manifest["id"])
             |> Map.put_new("pack_version", manifest["version"])
             |> Map.put_new("managed", true),
           {:ok, normalized} <- wrap_check_validation(stamped_doc, file, val_opts),
           :ok <- verify_slug_match(normalized["slug"], expected_slug, file) do
        {:cont, {:ok, [%{entry: entry, raw: raw_doc, normalized: normalized} | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp wrap_check_validation(doc, file, val_opts) do
    case SchemaValidator.validate_document(doc, val_opts) do
      {:ok, normalized} ->
        {:ok, normalized}

      {:error, %{errors: diags}} ->
        {:error,
         Enum.map(diags, fn d ->
           diag(file, d.path, d.code, d.message)
         end)}
    end
  end

  defp validate_rule_entries(files, entries, default_params) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      file = entry["file"]
      kind = entry["kind"]
      expected_name = entry["name"]
      entry_install_state = Map.get(entry, "install_state", "enabled")

      with {:ok, bytes} <- fetch_resource_file(files, file),
           {:ok, raw_doc} <- decode_json_file(file, bytes),
           {:ok, resolved_doc} <- resolve_pack_params(raw_doc, default_params, file),
           merged_doc =
             resolved_doc
             |> Map.put_new("kind", kind)
             |> Map.put(
               "install_state",
               Map.get(resolved_doc, "install_state", entry_install_state)
             ),
           {:ok, normalized} <- validate_rule_doc(merged_doc, kind, file),
           :ok <- verify_name_match(normalized["name"], expected_name, file) do
        {:cont, {:ok, [%{entry: entry, raw: raw_doc, normalized: normalized} | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_dashboard_entries(files, entries, default_params) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      file = entry["file"]
      expected_slug = entry["slug"]

      with {:ok, bytes} <- fetch_resource_file(files, file),
           {:ok, raw_doc} <- decode_json_file(file, bytes),
           {:ok, resolved_doc} <- resolve_pack_params(raw_doc, default_params, file),
           {:ok, normalized} <- validate_dashboard_doc(resolved_doc, file),
           :ok <- verify_slug_match(normalized["slug"], expected_slug, file) do
        {:cont, {:ok, [%{entry: entry, raw: raw_doc, normalized: normalized} | acc]}}
      else
        {:error, errs} -> {:halt, {:error, errs}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  defp validate_auxiliary_files(files) do
    errs =
      Enum.flat_map(files, fn {path, bytes} ->
        cond do
          path == "README.md" ->
            case SvgSanitizer.sanitize_markdown(bytes) do
              {:ok, _} -> []
              {:error, code} -> [diag(path, "$", to_string(code), "invalid README.md content")]
            end

          String.ends_with?(String.downcase(path), ".svg") ->
            case SvgSanitizer.validate_svg(bytes) do
              {:ok, _} -> []
              {:error, {code, msg}} -> [diag(path, "$", to_string(code), msg)]
            end

          true ->
            []
        end
      end)

    case errs do
      [] -> :ok
      list -> {:error, list}
    end
  end

  defp fetch_resource_file(files, file) do
    case Map.fetch(files, file) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        {:error,
         [
           diag(
             file,
             "$.resources",
             "missing_resource_file",
             "resource file #{inspect(file)} not found"
           )
         ]}
    end
  end

  defp verify_slug_match(actual, expected, _file) when actual == expected, do: :ok

  defp verify_slug_match(actual, expected, file) do
    {:error,
     [
       diag(
         file,
         "$.slug",
         "slug_mismatch",
         "slug #{inspect(actual)} does not match manifest entry #{inspect(expected)}"
       )
     ]}
  end

  defp verify_name_match(actual, expected, _file) when actual == expected, do: :ok

  defp verify_name_match(actual, expected, file) do
    {:error,
     [
       diag(
         file,
         "$.name",
         "name_mismatch",
         "rule name #{inspect(actual)} does not match manifest entry #{inspect(expected)}"
       )
     ]}
  end

  defp check_format_version(diags, doc) do
    case Map.get(doc, "pack_format_version") do
      @supported_format_version ->
        diags

      other ->
        [
          diag(
            "manifest.json",
            "$.pack_format_version",
            "unsupported_pack_format_version",
            "unsupported pack_format_version #{inspect(other)}; supported version is #{@supported_format_version}"
          )
          | diags
        ]
    end
  end

  defp check_pack_id(diags, doc) do
    id = Map.get(doc, "id")

    if is_binary(id) and Regex.match?(@pack_id_regex, id) do
      diags
    else
      [
        diag(
          "manifest.json",
          "$.id",
          "invalid_pack_id",
          "id #{inspect(id)} must be a reverse-DNS identifier (e.g. io.serviceradar.example)"
        )
        | diags
      ]
    end
  end

  defp check_slug(diags, doc) do
    slug = Map.get(doc, "slug")

    if is_binary(slug) and Regex.match?(@slug_regex, slug) do
      diags
    else
      [
        diag(
          "manifest.json",
          "$.slug",
          "invalid_slug",
          "slug #{inspect(slug)} must match ^[a-z0-9][a-z0-9-]{0,126}$"
        )
        | diags
      ]
    end
  end

  defp check_required_string(diags, doc, key) do
    val = Map.get(doc, key)

    if is_binary(val) and String.trim(val) != "" do
      diags
    else
      [
        diag(
          "manifest.json",
          "$.#{key}",
          "missing_required_field",
          "#{key} must be a non-empty string"
        )
        | diags
      ]
    end
  end

  defp check_semver(diags, doc, key, required?) do
    case Map.get(doc, key) do
      nil when not required? ->
        diags

      "" when not required? ->
        diags

      val when is_binary(val) ->
        case Version.parse(val) do
          {:ok, _} ->
            diags

          :error ->
            [
              diag(
                "manifest.json",
                "$.#{key}",
                "invalid_semver",
                "#{key} #{inspect(val)} must be valid SemVer"
              )
              | diags
            ]
        end

      other ->
        [
          diag(
            "manifest.json",
            "$.#{key}",
            "invalid_semver",
            "#{key} #{inspect(other)} must be valid SemVer"
          )
          | diags
        ]
    end
  end

  defp check_categories(diags, doc) do
    case Map.get(doc, "categories", []) do
      list when is_list(list) ->
        if Enum.all?(list, &(is_binary(&1) and String.trim(&1) != "")) do
          diags
        else
          [
            diag(
              "manifest.json",
              "$.categories",
              "invalid_categories",
              "categories must be non-empty strings"
            )
            | diags
          ]
        end

      _ ->
        [
          diag(
            "manifest.json",
            "$.categories",
            "invalid_categories",
            "categories must be an array"
          )
          | diags
        ]
    end
  end

  defp check_icon(diags, doc) do
    case Map.get(doc, "icon") do
      nil ->
        diags

      "" ->
        diags

      icon when is_binary(icon) ->
        case SvgSanitizer.validate_svg(icon) do
          {:ok, _} ->
            diags

          {:error, {code, msg}} ->
            [diag("manifest.json", "$.icon", to_string(code), msg) | diags]
        end

      _ ->
        [
          diag(
            "manifest.json",
            "$.icon",
            "invalid_icon",
            "icon must be an SVG string or data URI"
          )
          | diags
        ]
    end
  end

  defp check_config_descriptors(diags, doc) do
    case Map.get(doc, "config", []) do
      list when is_list(list) ->
        {_, errs} =
          list
          |> Enum.with_index()
          |> Enum.reduce({MapSet.new(), diags}, fn {item, idx}, {seen, acc} ->
            validate_one_config_descriptor(item, idx, seen, acc)
          end)

        errs

      _ ->
        [diag("manifest.json", "$.config", "invalid_config", "config must be an array") | diags]
    end
  end

  defp validate_one_config_descriptor(item, idx, seen, diags) when is_map(item) do
    key = Map.get(item, "key")
    type = Map.get(item, "type")
    path = "$.config[#{idx}]"

    diags =
      diags
      |> check_if(
        not (is_binary(key) and Regex.match?(@key_regex, key)),
        "manifest.json",
        "#{path}.key",
        "invalid_config_key",
        "config key #{inspect(key)} is invalid"
      )
      |> check_if(
        is_binary(key) and MapSet.member?(seen, key),
        "manifest.json",
        "#{path}.key",
        "duplicate_config_key",
        "duplicate config key #{inspect(key)}"
      )
      |> check_if(
        type not in @allowed_config_types,
        "manifest.json",
        "#{path}.type",
        "invalid_config_type",
        "config type #{inspect(type)} must be one of #{Enum.join(@allowed_config_types, ", ")}"
      )

    diags =
      if not is_nil(Map.get(item, "default")) and type in @allowed_config_types do
        case coerce_and_check_config_value(Map.get(item, "default"), item, "#{path}.default") do
          {:ok, _} -> diags
          {:error, d} -> [%{d | file: "manifest.json"} | diags]
        end
      else
        diags
      end

    next_seen = if is_binary(key), do: MapSet.put(seen, key), else: seen
    {next_seen, diags}
  end

  defp validate_one_config_descriptor(_other, idx, seen, diags) do
    {seen,
     [
       diag(
         "manifest.json",
         "$.config[#{idx}]",
         "invalid_type",
         "config descriptor must be an object"
       )
       | diags
     ]}
  end

  defp check_credential_slots(diags, doc) do
    case Map.get(doc, "credential_slots", []) do
      list when is_list(list) ->
        {_, errs} =
          list
          |> Enum.with_index()
          |> Enum.reduce({MapSet.new(), diags}, fn {slot_doc, idx}, {seen, acc} ->
            validate_one_slot(slot_doc, idx, seen, acc)
          end)

        errs

      _ ->
        [
          diag(
            "manifest.json",
            "$.credential_slots",
            "invalid_credential_slots",
            "credential_slots must be an array"
          )
          | diags
        ]
    end
  end

  defp validate_one_slot(item, idx, seen, diags) when is_map(item) do
    slot = Map.get(item, "slot")
    provider = Map.get(item, "provider")
    path = "$.credential_slots[#{idx}]"

    diags =
      diags
      |> check_if(
        not (is_binary(slot) and Regex.match?(@key_regex, slot)),
        "manifest.json",
        "#{path}.slot",
        "invalid_slot",
        "credential slot #{inspect(slot)} is invalid"
      )
      |> check_if(
        is_binary(slot) and MapSet.member?(seen, slot),
        "manifest.json",
        "#{path}.slot",
        "duplicate_slot",
        "duplicate credential slot #{inspect(slot)}"
      )
      |> check_if(
        not (is_binary(provider) and String.trim(provider) != ""),
        "manifest.json",
        "#{path}.provider",
        "missing_provider",
        "credential slot must declare provider"
      )

    next_seen = if is_binary(slot), do: MapSet.put(seen, slot), else: seen
    {next_seen, diags}
  end

  defp validate_one_slot(_other, idx, seen, diags) do
    {seen,
     [
       diag(
         "manifest.json",
         "$.credential_slots[#{idx}]",
         "invalid_type",
         "credential slot must be an object"
       )
       | diags
     ]}
  end

  defp check_plugin_dependencies(diags, doc) do
    case Map.get(doc, "plugin_dependencies", []) do
      list when is_list(list) ->
        list
        |> Enum.with_index()
        |> Enum.reduce(diags, fn {dep, idx}, acc ->
          validate_one_plugin_dep(dep, idx, acc)
        end)

      _ ->
        [
          diag(
            "manifest.json",
            "$.plugin_dependencies",
            "invalid_plugin_dependencies",
            "plugin_dependencies must be an array"
          )
          | diags
        ]
    end
  end

  defp validate_one_plugin_dep(dep, idx, diags) when is_map(dep) do
    pkg_id = Map.get(dep, "package_id") || Map.get(dep, "plugin_id")
    constraint = Map.get(dep, "version_constraint")
    path = "$.plugin_dependencies[#{idx}]"

    diags =
      check_if(
        diags,
        not (is_binary(pkg_id) and String.trim(pkg_id) != ""),
        "manifest.json",
        "#{path}.package_id",
        "missing_package_id",
        "plugin dependency must specify package_id"
      )

    if is_binary(constraint) and String.trim(constraint) != "" do
      case Version.parse_requirement(constraint) do
        {:ok, _} ->
          diags

        :error ->
          [
            diag(
              "manifest.json",
              "#{path}.version_constraint",
              "invalid_version_constraint",
              "invalid SemVer requirement #{inspect(constraint)}"
            )
            | diags
          ]
      end
    else
      [
        diag(
          "manifest.json",
          "#{path}.version_constraint",
          "missing_version_constraint",
          "plugin dependency must specify version_constraint"
        )
        | diags
      ]
    end
  end

  defp validate_one_plugin_dep(_other, idx, diags) do
    [
      diag(
        "manifest.json",
        "$.plugin_dependencies[#{idx}]",
        "invalid_type",
        "plugin dependency must be an object"
      )
      | diags
    ]
  end

  defp check_resources(diags, doc) do
    case Map.get(doc, "resources") do
      res when is_map(res) ->
        diags
        |> check_resource_list(Map.get(res, "checks", []), "checks", ["file", "slug"])
        |> check_resource_rules_list(Map.get(res, "rules", []))
        |> check_resource_list(Map.get(res, "dashboards", []), "dashboards", ["file", "slug"])

      _ ->
        [
          diag("manifest.json", "$.resources", "missing_resources", "resources must be an object")
          | diags
        ]
    end
  end

  defp check_resource_list(diags, list, section, req_keys) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(diags, fn {entry, idx}, acc ->
      path = "$.resources.#{section}[#{idx}]"

      if is_map(entry) do
        acc =
          Enum.reduce(req_keys, acc, fn k, inner ->
            val = Map.get(entry, k)

            check_if(
              inner,
              not (is_binary(val) and String.trim(val) != ""),
              "manifest.json",
              "#{path}.#{k}",
              "missing_field",
              "#{section} entry must specify #{k}"
            )
          end)

        file_val = Map.get(entry, "file")

        check_if(
          acc,
          is_binary(file_val) and not safe_relative_path?(file_val),
          "manifest.json",
          "#{path}.file",
          "unsafe_path",
          "unsafe resource file path #{inspect(file_val)}"
        )
      else
        [diag("manifest.json", path, "invalid_type", "resource entry must be an object") | acc]
      end
    end)
  end

  defp check_resource_list(diags, _other, section, _req_keys) do
    [
      diag(
        "manifest.json",
        "$.resources.#{section}",
        "invalid_type",
        "#{section} must be an array"
      )
      | diags
    ]
  end

  defp check_resource_rules_list(diags, list) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(diags, fn {entry, idx}, acc ->
      path = "$.resources.rules[#{idx}]"

      if is_map(entry) do
        file_val = Map.get(entry, "file")
        kind = Map.get(entry, "kind")
        name = Map.get(entry, "name")
        install_state = Map.get(entry, "install_state", "enabled")

        acc
        |> check_if(
          not (is_binary(file_val) and safe_relative_path?(file_val)),
          "manifest.json",
          "#{path}.file",
          "invalid_file",
          "rule entry must specify a safe relative file path"
        )
        |> check_if(
          kind not in @allowed_rule_kinds,
          "manifest.json",
          "#{path}.kind",
          "invalid_rule_kind",
          "rule kind must be one of #{Enum.join(@allowed_rule_kinds, ", ")}"
        )
        |> check_if(
          not (is_binary(name) and String.trim(name) != ""),
          "manifest.json",
          "#{path}.name",
          "missing_name",
          "rule entry must specify name"
        )
        |> check_if(
          install_state not in @allowed_install_states,
          "manifest.json",
          "#{path}.install_state",
          "invalid_install_state",
          ~s(install_state must be "enabled" or "paused")
        )
      else
        [
          diag("manifest.json", path, "invalid_type", "rule resource entry must be an object")
          | acc
        ]
      end
    end)
  end

  defp check_resource_rules_list(diags, _other) do
    [diag("manifest.json", "$.resources.rules", "invalid_type", "rules must be an array") | diags]
  end

  defp check_files_table(diags, doc) do
    case Map.get(doc, "files") do
      files when is_map(files) ->
        Enum.reduce(files, diags, fn {path, digest}, acc ->
          acc
          |> check_if(
            path == "manifest.json" or not safe_relative_path?(path),
            "manifest.json",
            "$.files.#{path}",
            "invalid_file_path",
            "manifest.files key #{inspect(path)} must be a safe non-manifest relative path"
          )
          |> check_if(
            not (is_binary(digest) and Regex.match?(@hex64_regex, String.downcase(digest))),
            "manifest.json",
            "$.files.#{path}",
            "invalid_digest",
            "manifest.files digest for #{inspect(path)} must be a 64-character lowercase SHA-256 hex string"
          )
        end)

      _ ->
        [
          diag(
            "manifest.json",
            "$.files",
            "missing_files",
            "manifest.files SHA-256 digest map is required"
          )
          | diags
        ]
    end
  end

  defp normalize_manifest_doc(doc) do
    sanitized_icon =
      case Map.get(doc, "icon") do
        icon when is_binary(icon) and icon != "" ->
          case SvgSanitizer.sanitize_icon(icon) do
            {:ok, clean} -> clean
            _ -> icon
          end

        _ ->
          nil
      end

    resources = Map.get(doc, "resources", %{})

    normalized_resources = %{
      "checks" => Map.get(resources, "checks", []),
      "rules" =>
        resources
        |> Map.get("rules", [])
        |> Enum.map(&Map.put_new(&1, "install_state", "enabled")),
      "dashboards" => Map.get(resources, "dashboards", [])
    }

    normalized_files =
      doc
      |> Map.get("files", %{})
      |> Map.new(fn {k, v} -> {to_string(k), String.downcase(to_string(v))} end)

    doc
    |> Map.put_new("categories", [])
    |> Map.put_new("config", [])
    |> Map.put_new("credential_slots", [])
    |> Map.put_new("plugin_dependencies", [])
    |> Map.put("resources", normalized_resources)
    |> Map.put("files", normalized_files)
    |> maybe_put_icon(sanitized_icon)
  end

  defp maybe_put_icon(doc, nil), do: doc
  defp maybe_put_icon(doc, icon), do: Map.put(doc, "icon", icon)

  defp coerce_and_check_config_value(val, desc, path) do
    type = desc["type"]

    with {:ok, coerced} <- coerce_by_type(val, type, path),
         :ok <- check_numeric_bounds(coerced, desc, path),
         :ok <- check_enum(coerced, desc, path) do
      {:ok, coerced}
    end
  end

  defp coerce_by_type(val, "string", _path) when is_binary(val), do: {:ok, val}

  defp coerce_by_type(val, "srql_filter", path) when is_binary(val) do
    if String.contains?(val, [";", <<0>>]) do
      {:error,
       diag("config", path, "invalid_srql_filter", "srql_filter contains forbidden characters")}
    else
      {:ok, String.trim(val)}
    end
  end

  defp coerce_by_type(val, "boolean", _path) when is_boolean(val), do: {:ok, val}
  defp coerce_by_type("true", "boolean", _path), do: {:ok, true}
  defp coerce_by_type("false", "boolean", _path), do: {:ok, false}

  defp coerce_by_type(val, int_type, path) when int_type in ["integer", "duration_seconds"] do
    parsed =
      cond do
        is_integer(val) -> {:ok, val}
        is_binary(val) -> parse_int(val)
        true -> :error
      end

    case {int_type, parsed} do
      {"duration_seconds", {:ok, n}} when n < 1 ->
        {:error, diag("config", path, "invalid_duration", "duration_seconds must be >= 1")}

      {_, {:ok, n}} ->
        {:ok, n}

      _ ->
        {:error,
         diag("config", path, "invalid_type", "expected #{int_type}, got #{inspect(val)}")}
    end
  end

  defp coerce_by_type(val, "number", path) do
    cond do
      is_number(val) ->
        {:ok, val}

      is_binary(val) ->
        case Float.parse(String.trim(val)) do
          {f, ""} ->
            {:ok, f}

          _ ->
            {:error, diag("config", path, "invalid_type", "expected number, got #{inspect(val)}")}
        end

      true ->
        {:error, diag("config", path, "invalid_type", "expected number, got #{inspect(val)}")}
    end
  end

  defp coerce_by_type(val, type, path) do
    {:error, diag("config", path, "invalid_type", "expected #{type}, got #{inspect(val)}")}
  end

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {i, ""} -> {:ok, i}
      _ -> :error
    end
  end

  defp check_numeric_bounds(val, desc, path) when is_number(val) do
    min = Map.get(desc, "min")
    max = Map.get(desc, "max")

    cond do
      is_number(min) and val < min ->
        {:error, diag("config", path, "below_minimum", "value #{val} is below minimum #{min}")}

      is_number(max) and val > max ->
        {:error, diag("config", path, "above_maximum", "value #{val} exceeds maximum #{max}")}

      true ->
        :ok
    end
  end

  defp check_numeric_bounds(_val, _desc, _path), do: :ok

  defp check_enum(val, desc, path) do
    case Map.get(desc, "enum") do
      enum_vals when is_list(enum_vals) and enum_vals != [] ->
        if val in enum_vals do
          :ok
        else
          {:error,
           diag(
             "config",
             path,
             "invalid_enum_value",
             "value #{inspect(val)} must be one of #{inspect(enum_vals)}"
           )}
        end

      _ ->
        :ok
    end
  end

  defp do_resolve_params(%{"$pack_param" => key} = ref_map, params, file, path)
       when map_size(ref_map) == 1 and is_binary(key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        {value, []}

      :error ->
        {nil,
         [
           diag(
             file,
             path,
             "undeclared_pack_param",
             "references undeclared $pack_param #{inspect(key)}"
           )
         ]}
    end
  end

  defp do_resolve_params(map, params, file, path) when is_map(map) and not is_struct(map) do
    Enum.reduce(map, {%{}, []}, fn {k, v}, {acc_map, acc_errs} ->
      key = to_string(k)
      {resolved_v, child_errs} = do_resolve_params(v, params, file, "#{path}.#{key}")
      {Map.put(acc_map, key, resolved_v), child_errs ++ acc_errs}
    end)
  end

  defp do_resolve_params(list, params, file, path) when is_list(list) do
    {rev_items, errs} =
      list
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {item, idx}, {acc_list, acc_errs} ->
        {resolved_item, child_errs} = do_resolve_params(item, params, file, "#{path}[#{idx}]")
        {[resolved_item | acc_list], child_errs ++ acc_errs}
      end)

    {Enum.reverse(rev_items), errs}
  end

  defp do_resolve_params(other, _params, _file, _path), do: {other, []}

  defp validate_rule_kind_fields(doc, "stateful_alert_rule", file) do
    signal = to_string(Map.get(doc, "signal", "log"))
    threshold = Map.get(doc, "threshold", 1)
    window = Map.get(doc, "window_seconds", 300)
    bucket = Map.get(doc, "bucket_seconds", 60)

    []
    |> check_if(
      signal not in @allowed_stateful_signals,
      file,
      "$.signal",
      "invalid_signal",
      "signal #{inspect(signal)} must be one of #{Enum.join(@allowed_stateful_signals, ", ")}"
    )
    |> check_if(
      not (is_integer(threshold) and threshold >= 1),
      file,
      "$.threshold",
      "invalid_threshold",
      "threshold must be a positive integer"
    )
    |> check_if(
      not (is_integer(window) and is_integer(bucket) and window >= bucket and bucket > 0 and
             rem(window, bucket) == 0),
      file,
      "$.window_seconds",
      "invalid_window_bucket",
      "window_seconds must be a positive multiple of bucket_seconds"
    )
    |> Enum.reverse(unknown_match_key_diags(Map.get(doc, "match"), file))
  end

  defp validate_rule_kind_fields(doc, "event_rule", file) do
    source_type = to_string(Map.get(doc, "source_type", "log"))

    []
    |> check_if(
      source_type not in @allowed_event_source_types,
      file,
      "$.source_type",
      "invalid_source_type",
      ~s(source_type must be "log" or "metric")
    )
    |> Enum.reverse()
  end

  defp validate_rule_kind_fields(doc, "zen_rule", file) do
    subject = Map.get(doc, "subject")
    template = Map.get(doc, "template")
    format = to_string(Map.get(doc, "format", "json"))

    []
    |> check_if(
      not (is_binary(subject) and String.trim(subject) != ""),
      file,
      "$.subject",
      "missing_subject",
      "zen_rule must specify subject"
    )
    |> check_if(
      not (is_binary(template) and String.trim(template) != ""),
      file,
      "$.template",
      "missing_template",
      "zen_rule must specify template"
    )
    |> check_if(
      format not in @allowed_zen_formats,
      file,
      "$.format",
      "invalid_format",
      "zen_rule format must be json, protobuf, or otel_metrics"
    )
    |> Enum.reverse()
  end

  defp validate_rule_kind_fields(_doc, _kind, _file), do: []

  # The alert engine ignores a match key it does not know, so a rule written
  # with one matches every record instead of none.
  defp unknown_match_key_diags(match, file) do
    for key <- RuleMatcher.unknown_match_keys(match) do
      diag(
        file,
        "$.match.#{key}",
        "unknown_match_key",
        "the alert engine does not read match key #{inspect(key)}; " <>
          "put record fields under attribute_equals"
      )
    end
  end

  defp validate_dashboard_panels(panels, file) when is_list(panels) and panels != [] do
    allowed_visuals =
      DashboardPanel
      |> Ash.Resource.Info.attribute(:visual_type)
      |> Map.fetch!(:constraints)
      |> Keyword.fetch!(:one_of)
      |> Enum.map(&Atom.to_string/1)

    panel_diags =
      panels
      |> Enum.with_index()
      |> Enum.flat_map(fn {panel, idx} ->
        validate_one_panel(panel, idx, allowed_visuals, file)
      end)

    if panel_diags == [] do
      check_panel_overlap(panels, file)
    else
      panel_diags
    end
  end

  defp validate_dashboard_panels(_panels, file) do
    [diag(file, "$.panels", "missing_panels", "dashboard panels must be a non-empty array")]
  end

  defp validate_one_panel(panel, idx, allowed_visuals, file) when is_map(panel) do
    path = "$.panels[#{idx}]"
    title = Map.get(panel, "title")
    query = Map.get(panel, "srql_query")
    visual = to_string(Map.get(panel, "visual_type") || "")
    layout = Map.get(panel, "layout")
    binding = Map.get(panel, "data_binding") || %{}

    diags =
      []
      |> check_if(
        not (is_binary(title) and String.trim(title) != ""),
        file,
        "#{path}.title",
        "missing_title",
        "panel title must be non-empty"
      )
      |> check_if(
        not (is_binary(query) and String.trim(query) != ""),
        file,
        "#{path}.srql_query",
        "missing_srql_query",
        "panel srql_query must be non-empty"
      )
      |> check_if(
        visual not in allowed_visuals,
        file,
        "#{path}.visual_type",
        "invalid_visual_type",
        "visual_type #{inspect(visual)} is not supported"
      )

    layout_diags = validate_panel_layout(layout, file, "#{path}.layout")
    binding_diags = validate_panel_binding(binding, query, file, "#{path}.data_binding")

    Enum.reverse(diags, layout_diags ++ binding_diags)
  end

  defp validate_one_panel(_other, idx, _allowed_visuals, file) do
    [diag(file, "$.panels[#{idx}]", "invalid_type", "panel must be an object")]
  end

  defp validate_panel_layout(layout, file, path) when is_map(layout) do
    x = Map.get(layout, "x")
    y = Map.get(layout, "y")
    w = Map.get(layout, "w")
    h = Map.get(layout, "h")

    cond do
      not (is_integer(x) and is_integer(y) and is_integer(w) and is_integer(h)) ->
        [diag(file, path, "invalid_layout", "panel layout requires integer x, y, w, and h")]

      x < 0 or x >= @grid_columns or w < 1 or x + w > @grid_columns or y < 0 or h < 1 ->
        [diag(file, path, "layout_out_of_bounds", "panel layout overflows the 12-column grid")]

      true ->
        []
    end
  end

  defp validate_panel_layout(_other, file, path) do
    [diag(file, path, "missing_layout", "panel must declare grid layout {x, y, w, h}")]
  end

  defp validate_panel_binding(binding, query, file, path)
       when is_map(binding) and is_binary(query) do
    Enum.flat_map(binding, fn {key, field} ->
      if is_binary(field) and selects_field?(query, field) do
        []
      else
        [
          diag(
            file,
            "#{path}.#{key}",
            "unbound_query_field",
            "binding #{inspect(key)} names #{inspect(field)}, which query does not select"
          )
        ]
      end
    end)
  end

  defp validate_panel_binding(_binding, _query, _file, _path), do: []

  defp selects_field?(query, field) do
    Regex.match?(~r/ as #{Regex.escape(field)}(?!\w)/, query) or
      field in group_dimensions(query) or
      (field == "bucket" and String.contains?(query, "by time:"))
  end

  defp group_dimensions(query) do
    case :binary.split(query, " by ") do
      [_, after_by] ->
        after_by
        |> String.split(~r/ sort:| limit:/, parts: 2)
        |> hd()
        |> String.split([" ", ","], trim: true)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.map(&String.trim(&1, "'"))
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  defp check_panel_overlap(panels, file) do
    cells =
      Enum.flat_map(panels, fn panel ->
        l = panel["layout"]

        for cx <- l["x"]..(l["x"] + l["w"] - 1),
            cy <- l["y"]..(l["y"] + l["h"] - 1),
            do: {cx, cy}
      end)

    if length(Enum.uniq(cells)) == length(cells) do
      []
    else
      [
        diag(
          file,
          "$.panels",
          "overlapping_panels",
          "dashboard panels overlap in the 12-column grid"
        )
      ]
    end
  end

  defp stringify_keys(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp check_if(diags, true, file, path, code, msg), do: [diag(file, path, code, msg) | diags]
  defp check_if(diags, false, _file, _path, _code, _msg), do: diags

  defp diag(file, path, code, message) do
    %{file: file, path: path, code: code, message: message}
  end
end
