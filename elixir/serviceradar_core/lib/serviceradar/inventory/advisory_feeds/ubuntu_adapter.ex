defmodule ServiceRadar.Inventory.AdvisoryFeeds.UbuntuAdapter do
  @moduledoc "Bounded command/Port adapter for Canonical's atomic OSV/OpenVEX pair."

  alias ServiceRadar.Inventory.AdvisoryFeeds.Parsers.Ubuntu

  @protocol_version 2
  @cve ~r/^CVE-\d{4}-\d{4,}$/
  @sha256 ~r/^[0-9a-f]{64}$/
  @default_helper "/usr/local/bin/serviceradar-ubuntu-feed-merge"
  @port_timeout 600_000
  @manifest_cap 32 * 1_024 * 1_024
  # Mirrors the Go protocol's explicit per-advisory projection bound.
  @frame_cap 64 * 1_024 * 1_024
  @member_cap 250_000
  @archive_cap 256 * 1_024 * 1_024
  @logical_cap 40 * 1_024 * 1_024 * 1_024
  @work_cap 1_024 * 1_024 * 1_024

  @manifest_required ~w(
    version projection_version osv vex input_bytes work_bytes peak_work_bytes work_limit_bytes
  )
  @inventory_required ~w(
    kind spool refs count members total archive_bytes archive_sha256 spool_bytes initial_runs
    merge_passes
  )
  @terminal_required ~w(
    protocol_version cve_count record_count osv_document_count vex_document_count osv_count
    vex_count withdrawn_document_count vex_tombstone_count osv_affected_entry_count
    vex_statement_count logical_product_occurrence_count unique_product_count
    unique_product_set_count assertion_count unscoped_product_count repaired_source_purl_count
    emitted_bytes emitted_frame_count max_frame_bytes osv_members vex_members osv_spool_bytes
    vex_spool_bytes peak_work_bytes
  )
  @counter_keys ~w(
    osv_documents vex_documents withdrawn_documents vex_tombstones osv_affected_entries
    vex_statements logical_product_occurrences assertions unscoped_products repaired_source_purls
  )a

  def prepare_pair(acquired, opts \\ []) do
    helper = Keyword.get(opts, :helper, @default_helper)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    with :ok <- absolute_regular_executable(helper),
         {output, 0} <- runner.(helper, prepare_args(acquired), stderr_to_stdout: true),
         {:ok, manifest} <- read_prepared_manifest(acquired) do
      {:ok,
       %{
         records: prepared_records(acquired, helper, manifest, opts),
         completeness: completeness(manifest),
         helper_output: output,
         manifest: manifest
       }}
    else
      {:error, _} = error -> error
      {_output, status} -> {:error, {:ubuntu_prepare_failed, status}}
      other -> {:error, {:ubuntu_prepare_failed, other}}
    end
  rescue
    error -> {:error, {:ubuntu_prepare_failed, error}}
  end

  defp prepare_args(acquired) do
    [
      "prepare",
      "--osv",
      acquired.osv_path,
      "--vex",
      acquired.vex_path,
      "--output-dir",
      acquired.prepared_dir
    ]
  end

  defp absolute_regular_executable(helper) when is_binary(helper) do
    with true <- Path.type(helper) == :absolute || {:error, :helper_must_be_absolute},
         {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(helper),
         true <- Bitwise.band(mode, 0o111) != 0 || {:error, :helper_not_executable} do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_helper}
    end
  end

  defp absolute_regular_executable(_), do: {:error, :invalid_helper}

  defp read_prepared_manifest(acquired) do
    path = Path.join(acquired.prepared_dir, "manifest.json")

    with {:ok, %File.Stat{type: :regular, size: size}}
         when size > 0 and size <= @manifest_cap <- File.lstat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(bytes),
         :ok <- validate_manifest(manifest, byte_size(bytes), acquired) do
      {:ok, manifest}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_prepared_manifest}
    end
  end

  defp validate_manifest(manifest, manifest_bytes, acquired) do
    with :ok <- exact_shape(manifest, @manifest_required),
         :ok <- equal(manifest["version"], @protocol_version, :manifest_version),
         :ok <- equal(manifest["projection_version"], @protocol_version, :projection_version),
         :ok <- validate_inventory(manifest["osv"], "osv", "osv.spool", acquired),
         :ok <- validate_inventory(manifest["vex"], "vex", "vex.spool", acquired),
         :ok <- positive_at_most(manifest["work_limit_bytes"], @work_cap, :work_limit_bytes),
         :ok <- positive_at_most(manifest["input_bytes"], 2 * @archive_cap, :input_bytes),
         :ok <-
           positive_at_most(manifest["work_bytes"], manifest["work_limit_bytes"], :work_bytes),
         :ok <-
           positive_at_most(
             manifest["peak_work_bytes"],
             manifest["work_limit_bytes"],
             :peak_work_bytes
           ),
         :ok <- condition(manifest["peak_work_bytes"] >= manifest["work_bytes"], :peak_work_bytes),
         :ok <-
           equal(
             manifest["input_bytes"],
             manifest["osv"]["archive_bytes"] + manifest["vex"]["archive_bytes"],
             :input_bytes
           ) do
      equal(
        manifest["work_bytes"],
        manifest["input_bytes"] + manifest["osv"]["spool_bytes"] +
          manifest["vex"]["spool_bytes"] + manifest_bytes,
        :work_bytes
      )
    end
  end

  defp validate_inventory(inventory, kind, spool, acquired) when is_map(inventory) do
    refs = inventory["refs"]
    cves = if is_list(refs), do: Enum.map(refs, & &1["cve"]), else: []
    artifact = Map.fetch!(acquired.artifacts, String.to_existing_atom(kind))
    archive_path = Map.fetch!(acquired, String.to_existing_atom("#{kind}_path"))

    with :ok <- exact_shape(inventory, @inventory_required),
         :ok <- equal(inventory["kind"], kind, :inventory_kind),
         :ok <- equal(inventory["spool"], spool, :inventory_spool),
         :ok <- positive_at_most(inventory["count"], @member_cap, :inventory_count),
         :ok <- integer_between(inventory["members"], inventory["count"], @member_cap, :members),
         :ok <- integer_between(inventory["total"], 0, @logical_cap, :total),
         :ok <- positive_at_most(inventory["archive_bytes"], @archive_cap, :archive_bytes),
         :ok <- valid_digest(inventory["archive_sha256"], :archive_sha256),
         :ok <- positive_at_most(inventory["spool_bytes"], @work_cap, :spool_bytes),
         :ok <- positive_at_most(inventory["initial_runs"], inventory["count"], :initial_runs),
         :ok <- nonnegative_integer(inventory["merge_passes"], :merge_passes),
         :ok <- validate_merge_passes(inventory["initial_runs"], inventory["merge_passes"]),
         :ok <- validate_refs(refs, cves, inventory["count"]),
         :ok <-
           regular_file_size(Path.join(acquired.prepared_dir, spool), inventory["spool_bytes"]),
         :ok <- regular_file_size(archive_path, inventory["archive_bytes"]),
         :ok <- equal(artifact.bytes, inventory["archive_bytes"], :acquired_archive_bytes) do
      equal(artifact.sha256, inventory["archive_sha256"], :acquired_archive_sha256)
    end
  rescue
    _ -> {:error, :invalid_inventory}
  end

  defp validate_inventory(_, _, _, _), do: {:error, :invalid_inventory}

  defp validate_refs(refs, cves, count) when is_list(refs) do
    with :ok <- equal(length(refs), count, :reference_count),
         :ok <- each(refs, &exact_shape(&1, ["cve"])),
         :ok <- condition(Enum.all?(cves, &valid_cve?/1), :references),
         :ok <- equal(cves, Enum.sort(cves), :reference_order) do
      condition(length(cves) == MapSet.size(MapSet.new(cves)), :duplicate_reference)
    end
  end

  defp validate_refs(_, _, _), do: {:error, :references}

  defp validate_merge_passes(1, 0), do: :ok

  defp validate_merge_passes(initial_runs, merge_passes)
       when is_integer(initial_runs) and initial_runs > 1 and is_integer(merge_passes) and
              merge_passes > 0, do: :ok

  defp validate_merge_passes(_, _), do: {:error, :merge_passes}

  defp regular_file_size(path, expected) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: ^expected}} -> :ok
      _ -> {:error, :invalid_file_size}
    end
  end

  defp completeness(manifest) do
    osv = manifest["osv"]
    vex = manifest["vex"]
    count = union_count(osv["refs"], vex["refs"])

    %{
      complete_snapshot?: true,
      source_objects_seen: count,
      expected_minimum: 1,
      parse_errors: 0,
      read_errors: 0,
      required_trees: ["osv", "vex"],
      validation: %{
        "osv" => tree_validation(osv),
        "vex" => tree_validation(vex),
        "projection" => %{"complete" => true, "version" => @protocol_version}
      }
    }
  end

  defp tree_validation(inventory) do
    %{
      "complete" => true,
      "count" => inventory["count"],
      "members" => inventory["members"],
      "archive_sha256" => inventory["archive_sha256"]
    }
  end

  defp union_count(osv, vex) do
    (Enum.map(osv, & &1["cve"]) ++ Enum.map(vex, & &1["cve"]))
    |> MapSet.new()
    |> MapSet.size()
  end

  defp prepared_records(acquired, helper, manifest, opts) do
    timeout = Keyword.get(opts, :port_timeout_ms, @port_timeout)

    parser_opts =
      opts
      |> Keyword.take([:provider, :feed_key])
      |> Keyword.put(:source_digests, %{
        osv: manifest["osv"]["archive_sha256"],
        vex: manifest["vex"]["archive_sha256"]
      })

    args_prefix = Keyword.get(opts, :helper_args_prefix, [])

    Stream.resource(
      fn ->
        initial_stream_state(acquired, helper, manifest, parser_opts, args_prefix, timeout)
      end,
      &next_port_record/1,
      &close_port/1
    )
  end

  defp initial_stream_state(acquired, helper, manifest, parser_opts, args_prefix, timeout) do
    expected_cves =
      (Enum.map(manifest["osv"]["refs"], & &1["cve"]) ++
         Enum.map(manifest["vex"]["refs"], & &1["cve"]))
      |> Enum.uniq()
      |> Enum.sort()
      |> List.to_tuple()

    port =
      Port.open({:spawn_executable, helper}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:packet, 4},
        {:args, args_prefix ++ ["stream", "--prepared-dir", acquired.prepared_dir]}
      ])

    %{
      port: port,
      terminal: false,
      manifest: manifest,
      timeout: timeout,
      opts: parser_opts,
      expected_cves: expected_cves,
      record_count: 0,
      known_products: %{},
      known_product_sets: %{},
      counters: Map.new(@counter_keys, &{&1, 0}),
      wire_bytes: 0,
      wire_frames: 0,
      max_frame_bytes: 0
    }
  end

  defp next_port_record(%{port: port, timeout: timeout} = state) do
    receive do
      {^port, {:data, <<1, payload::binary>> = frame}}
      when state.terminal == false and byte_size(frame) <= @frame_cap ->
        expected_cve = expected_cve!(state)

        case decode_record_frame(
               payload,
               state.opts ++
                 [
                   known_products: state.known_products,
                   known_product_sets: state.known_product_sets
                 ]
             ) do
          {:ok, ^expected_cve, record, context, counters} ->
            next =
              state
              |> account_wire(frame)
              |> Map.put(:record_count, state.record_count + 1)
              |> Map.put(:known_products, context.products)
              |> Map.put(:known_product_sets, context.product_sets)
              |> Map.put(:counters, add_counters(state.counters, counters))

            {[{:ok, record}], next}

          {:ok, cve, _record, _context, _counters} ->
            raise "Ubuntu helper record order mismatch: expected #{expected_cve}, got #{cve}"

          {:error, reason} ->
            raise "invalid Ubuntu projection frame: #{inspect(reason)}"
        end

      {^port, {:data, <<2, payload::binary>> = frame}}
      when state.terminal == false and byte_size(frame) <= @frame_cap ->
        state = account_wire(state, frame)
        validate_control_frame!(payload, state)
        {[], %{state | terminal: true}}

      {^port, {:data, data}} ->
        type = if byte_size(data) > 0, do: binary_part(data, 0, 1), else: <<>>

        raise "Ubuntu helper protocol violation: record_count=#{state.record_count} type=#{inspect(type)} bytes=#{byte_size(data)}"

      {^port, {:exit_status, 0}} when state.terminal == true ->
        {:halt, state}

      {^port, {:exit_status, status}} ->
        raise "Ubuntu helper exited before complete terminal frame: #{status}"
    after
      timeout ->
        close_port(state)
        raise "Ubuntu helper timed out"
    end
  end

  defp close_port(%{port: port}) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  @doc false
  def decode_record_frame(payload, opts)
      when is_binary(payload) and byte_size(payload) <= @frame_cap do
    with {:ok, projected} when is_map(projected) <- Jason.decode(payload),
         {:ok, record, context, counters} <- Ubuntu.validate_record(projected, opts),
         cve when is_binary(cve) <- projected["cve_id"] do
      {:ok, cve, record, context, counters}
    else
      reason -> {:error, {:invalid_ubuntu_projection_frame, reason}}
    end
  end

  def decode_record_frame(_, _), do: {:error, :invalid_ubuntu_projection_frame}

  defp add_counters(total, counters) do
    Map.new(@counter_keys, fn key -> {key, total[key] + Map.fetch!(counters, key)} end)
  end

  defp account_wire(state, frame) do
    size = byte_size(frame)

    %{
      state
      | wire_bytes: state.wire_bytes + 4 + size,
        wire_frames: state.wire_frames + 1,
        max_frame_bytes: max(state.max_frame_bytes, size)
    }
  end

  defp expected_cve!(state) when state.record_count < tuple_size(state.expected_cves),
    do: elem(state.expected_cves, state.record_count)

  defp expected_cve!(_state), do: raise("Ubuntu helper emitted more records than its manifest")

  defp validate_control_frame!(payload, state) do
    expected = expected_terminal(state)

    case Jason.decode(payload) do
      {:ok, terminal} when is_map(terminal) ->
        with :ok <- exact_shape(terminal, @terminal_required),
             :ok <- equal(terminal, expected, :terminal) do
          :ok
        else
          reason -> raise "Ubuntu helper terminal mismatch: #{inspect(reason)}"
        end

      other ->
        raise "Ubuntu helper terminal mismatch: #{inspect(other)}"
    end
  end

  defp expected_terminal(state) do
    counters = state.counters
    manifest = state.manifest

    %{
      "protocol_version" => @protocol_version,
      "cve_count" => tuple_size(state.expected_cves),
      "record_count" => tuple_size(state.expected_cves),
      "osv_document_count" => counters.osv_documents,
      "vex_document_count" => counters.vex_documents,
      "osv_count" => manifest["osv"]["count"],
      "vex_count" => manifest["vex"]["count"],
      "withdrawn_document_count" => counters.withdrawn_documents,
      "vex_tombstone_count" => counters.vex_tombstones,
      "osv_affected_entry_count" => counters.osv_affected_entries,
      "vex_statement_count" => counters.vex_statements,
      "logical_product_occurrence_count" => counters.logical_product_occurrences,
      "unique_product_count" => map_size(state.known_products),
      "unique_product_set_count" => map_size(state.known_product_sets),
      "assertion_count" => counters.assertions,
      "unscoped_product_count" => counters.unscoped_products,
      "repaired_source_purl_count" => counters.repaired_source_purls,
      "emitted_bytes" => state.wire_bytes,
      "emitted_frame_count" => state.wire_frames,
      "max_frame_bytes" => state.max_frame_bytes,
      "osv_members" => manifest["osv"]["members"],
      "vex_members" => manifest["vex"]["members"],
      "osv_spool_bytes" => manifest["osv"]["spool_bytes"],
      "vex_spool_bytes" => manifest["vex"]["spool_bytes"],
      "peak_work_bytes" => manifest["peak_work_bytes"]
    }
  end

  defp exact_shape(map, required) when is_map(map) do
    keys = Map.keys(map)

    with :ok <- condition(Enum.all?(required, &Map.has_key?(map, &1)), :missing_keys) do
      condition(
        length(keys) == length(required) and Enum.all?(keys, &(&1 in required)),
        :unknown_keys
      )
    end
  end

  defp exact_shape(_, _), do: {:error, :expected_object}

  defp each(values, function) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case function.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp valid_cve?(value), do: is_binary(value) and Regex.match?(@cve, value)

  defp valid_digest(value, label) do
    condition(is_binary(value) and Regex.match?(@sha256, value), label)
  end

  defp positive_at_most(value, maximum, _label)
       when is_integer(value) and is_integer(maximum) and value > 0 and value <= maximum, do: :ok

  defp positive_at_most(_, _, label), do: {:error, label}

  defp integer_between(value, minimum, maximum, _label)
       when is_integer(value) and is_integer(minimum) and is_integer(maximum) and value >= minimum and
              value <= maximum,
       do: :ok

  defp integer_between(_, _, _, label), do: {:error, label}

  defp nonnegative_integer(value, _label) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative_integer(_, label), do: {:error, label}

  defp equal(value, value, _label), do: :ok
  defp equal(_, _, label), do: {:error, label}

  defp condition(true, _label), do: :ok
  defp condition(false, label), do: {:error, label}
end
