{:ok, _} = Application.ensure_all_started(:serviceradar_nvr_client)
{:error, :bad_name} = :code.lib_dir(:serviceradar_core)
{:error, :bad_name} = :code.lib_dir(:serviceradar_nvr)
{:error, :bad_name} = :code.lib_dir(:membrane_core)

request = "NVR_CLIENT_REQUEST" |> System.fetch_env!() |> File.read!() |> Jason.decode!()

units =
  Stream.resource(
    fn -> File.open!(request["units_path"], [:read, :binary]) end,
    fn file ->
      case IO.binread(file, 28) do
        :eof ->
          {:halt, file}

        <<size::32, sequence::64, pts::64, dts::64>> ->
          payload = IO.binread(file, size)
          {[%{payload: payload, sequence: sequence, pts: pts, dts: dts}], file}
      end
    end,
    &File.close/1
  )

mode = request["mode"] || "normal"
parent = self()
# Shared with the sender process, which pulls the enumerable.
pulled = :counters.new(1, [:atomics])

units =
  Stream.map(units, fn unit ->
    case mode do
      "raise" ->
        raise "synthetic producer failed"

      "paced" ->
        :counters.add(pulled, 1, 1)
        Process.sleep(request["pace_ms"])
        unit

      "block" ->
        Process.sleep(:infinity)

      "caller_loss" ->
        send(parent, {:sender_started, self()})
        Process.sleep(:infinity)

      _ ->
        unit
    end
  end)

result =
  with {:ok, config} <- ServiceRadarNVRClient.Config.load(request["config_path"], request["token_path"]) do
    case mode do
      "archive" ->
        ServiceRadarNVRClient.archive_block(
          config,
          request["block_id"],
          request["archive_request"],
          request["timeout_ms"]
        )

      "reclaim" ->
        ServiceRadarNVRClient.reclaim_block(
          config,
          request["block_id"],
          request["reclaim_request"],
          request["timeout_ms"]
        )

      "status" ->
        ServiceRadarNVRClient.status(config, request["timeout_ms"])

      "lookup" ->
        ServiceRadarNVRClient.lookup_blocks(config, request["block_ids"], request["timeout_ms"])

      "page" ->
        ServiceRadarNVRClient.block_page(config, request["after"], request["limit"], request["timeout_ms"])

      "descriptor" ->
        ServiceRadarNVRClient.block_descriptor(config, request["block_id"], request["timeout_ms"])

      "read" ->
        selector = if request["selector"] == "init", do: :init, else: {:fragment, request["selector"]}
        expected = %{length: request["length"], sha256: request["sha256"]}

        with {:ok, bytes} <-
               ServiceRadarNVRClient.read_block(
                 config,
                 request["block_id"],
                 request["descriptor_sha256"],
                 selector,
                 expected,
                 request["timeout_ms"]
               ) do
          {:ok, %{length: byte_size(bytes), sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}}
        end

      "caller_loss" ->
        {caller, caller_monitor} =
          spawn_monitor(fn ->
            ServiceRadarNVRClient.send_recording(config, request["header"], units, request["timeout_ms"])
          end)

        sender =
          receive do
            {:sender_started, pid} -> pid
          after
            5000 -> raise "sender never started"
          end

        sender_monitor = Process.monitor(sender)
        Process.exit(caller, :kill)

        receive do
          {:DOWN, ^caller_monitor, :process, ^caller, :killed} -> :ok
        after
          1000 -> raise "caller survived"
        end

        receive do
          {:DOWN, ^sender_monitor, :process, ^sender, _} -> {:ok, %{caller_loss_bounded: true}}
        after
          request["timeout_ms"] + 1000 -> raise "sender survived its caller and deadline"
        end

      _ ->
        ServiceRadarNVRClient.send_recording(config, request["header"], units, request["timeout_ms"])
    end
  end

result =
  case result do
    {:ok, receipt} -> %{ok: receipt}
    {:error, {:archive_status, status, error}} -> %{error: "archive_status", status: status, body: error}
    {:error, {:descriptor_status, status, error}} -> %{error: "descriptor_status", status: status, body: error}
    {:error, {tag, status, error}} when is_integer(status) -> %{error: Atom.to_string(tag), status: status, body: error}
    {:error, reason} -> %{error: inspect(reason)}
  end

result = if mode == "paced", do: Map.put(result, :pulled, :counters.get(pulled, 1)), else: result

File.write!(System.fetch_env!("NVR_CLIENT_RESULT"), Jason.encode!(result))
IO.puts("NVR_CLIENT_PROBE_OK")
