defmodule ServiceRadar.NATS.ManagedCertificateConnzTest do
  @moduledoc """
  Hub CONNZ pages are a bounded offset/limit read. One server's tail must not
  spend the whole follow-up budget, and a later scan resumes unfinished servers.
  """
  use ExUnit.Case, async: false

  alias ServiceRadar.NATS.ManagedCertificateAuthorization, as: Authorizer

  @page_limit 256
  @quiet_server "hub-a"
  @busy_server "hub-b"
  @quiet_fingerprint String.duplicate("ab", 32)
  @busy_fingerprint String.duplicate("cd", 32)

  defmodule Catalog do
    @moduledoc false
    use GenServer

    def start_link(catalog) do
      GenServer.start_link(__MODULE__, catalog, name: :serviceradar_certificate_system)
    end

    def requests(pid), do: GenServer.call(pid, :requests)

    @impl true
    def init(catalog), do: {:ok, %{catalog: catalog, requests: [], sid: 1, subscriber: nil}}

    @impl true
    def handle_call({:sub, subscriber, _topic, _opts}, _from, state) do
      {:reply, {:ok, state.sid}, %{state | subscriber: subscriber}}
    end

    def handle_call({:unsub, _sid, _opts}, _from, state), do: {:reply, :ok, state}

    def handle_call({:pub, subject, payload, _opts}, _from, state) do
      request = Jason.decode!(payload)
      state = %{state | requests: state.requests ++ [Map.put(request, "subject", subject)]}

      if state.subscriber do
        for body <- replies(subject, request, state.catalog) do
          send(state.subscriber, {:msg, %{sid: state.sid, body: body}})
        end
      end

      {:reply, :ok, state}
    end

    def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

    defp replies("$SYS.REQ.SERVER.PING.CONNZ", request, catalog) do
      Enum.map(catalog, fn {server, spec} ->
        page(server, request["offset"], request["limit"], spec)
      end)
    end

    defp replies("$SYS.REQ.SERVER." <> rest, request, catalog) do
      server = String.replace_suffix(rest, ".CONNZ", "")

      case Map.get(catalog, server) do
        nil -> []
        spec -> [page(server, request["offset"], request["limit"], spec)]
      end
    end

    defp replies(_subject, _request, _catalog), do: []

    defp page(server, offset, limit, spec) do
      Jason.encode!(%{
        "server" => %{"id" => server},
        "data" => %{
          "offset" => offset,
          "total" => spec.total,
          "connections" => connections(spec, offset, limit)
        }
      })
    end

    defp connections(spec, offset, limit) do
      last = min(offset + limit, spec.total) - 1

      if last < offset do
        []
      else
        Enum.map(offset..last, fn index ->
          connection = %{"kind" => "Client", "cid" => index + 1}

          if index == spec.marker_at do
            Map.put(connection, "tls_peer_certs", [%{"cert_sha256" => spec.fingerprint}])
          else
            connection
          end
        end)
      end
    end
  end

  defmodule Silent do
    @moduledoc false
    use GenServer

    def start_link(:timeout), do: GenServer.start_link(__MODULE__, :timeout, name: name())
    def start_link(:closed), do: GenServer.start_link(__MODULE__, :closed, name: name())

    defp name, do: :serviceradar_certificate_system

    @impl true
    def init(mode), do: {:ok, mode}

    @impl true
    def handle_call({:sub, _subscriber, _topic, _opts}, _from, :closed) do
      {:reply, {:error, :unavailable}, :closed}
    end

    def handle_call({:sub, _subscriber, _topic, _opts}, _from, state) do
      {:reply, {:ok, 1}, state}
    end

    def handle_call({:unsub, _sid, _opts}, _from, state), do: {:reply, :ok, state}
    def handle_call({:pub, _subject, _payload, _opts}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    on_exit(fn ->
      case Process.whereis(:serviceradar_certificate_system) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end)

    :ok
  end

  test "one server page is returned without a follow-up request" do
    catalog = %{
      @quiet_server => %{total: 1, marker_at: 0, fingerprint: @quiet_fingerprint}
    }

    pid = start_catalog!(catalog)
    {connections, progress} = Authorizer.scan_presented_connections("SERVICERADAR")

    assert fingerprints(connections) == [@quiet_fingerprint]
    assert progress.offsets[@quiet_server] == 0
    assert Enum.map(Catalog.requests(pid), & &1["subject"]) == ["$SYS.REQ.SERVER.PING.CONNZ"]
    assert Enum.uniq(Enum.map(Catalog.requests(pid), & &1["limit"])) == [@page_limit]
  end

  test "a busy server cannot hide another server's later page across scans" do
    # Connection indexes are independent of the scanner. Index `page_limit`
    # is the first connection past the opening page. Index `page_limit * 9`
    # is the first connection past one opening page plus eight follow-ups,
    # which is the whole former per-scan budget when every follow-up is spent
    # on one server.
    quiet_at = @page_limit
    busy_at = @page_limit * 9

    catalog = %{
      @quiet_server => %{
        total: quiet_at + 1,
        marker_at: quiet_at,
        fingerprint: @quiet_fingerprint
      },
      @busy_server => %{
        total: busy_at + @page_limit,
        marker_at: busy_at,
        fingerprint: @busy_fingerprint
      }
    }

    pid = start_catalog!(catalog)
    {first, progress} = Authorizer.scan_presented_connections("SERVICERADAR")
    first_requests = Catalog.requests(pid)

    assert @quiet_fingerprint in fingerprints(first)
    refute @busy_fingerprint in fingerprints(first)
    assert requested_offset(first_requests, @quiet_server, quiet_at)
    refute requested_offset(first_requests, @busy_server, busy_at)
    assert progress.offsets[@busy_server] > 0
    assert progress.offsets[@quiet_server] == 0

    {second, again} = Authorizer.scan_presented_connections("SERVICERADAR", progress)
    second_requests = Catalog.requests(pid) -- first_requests

    assert @quiet_fingerprint in fingerprints(second)
    assert @busy_fingerprint in fingerprints(second)
    assert requested_offset(second_requests, @busy_server, busy_at)
    assert again.offsets[@quiet_server] == 0
  end

  test "a silent listing keeps the saved cursor and a closed subscription returns no pages" do
    saved = %{offsets: %{@busy_server => @page_limit}, turn: 2}
    start_silent!(:timeout)
    assert {[], saved} == Authorizer.scan_presented_connections("SERVICERADAR", saved)

    restart_silent!(:closed)
    assert {[], saved} == Authorizer.scan_presented_connections("SERVICERADAR", saved)
  end

  test "the observer keeps the scan cursor for the next pass" do
    ref = make_ref()
    cursor = %{offsets: %{@busy_server => @page_limit * 2}, turn: 4}

    assert {:noreply, state} =
             Authorizer.handle_info(
               {ref, {:ok, cursor}},
               %{probe: ref, connz: %{offsets: %{}, turn: 0}}
             )

    assert state.probe == nil
    assert state.connz == cursor
  end

  defp start_catalog!(catalog) do
    stop_system_connection()
    {:ok, pid} = Catalog.start_link(catalog)
    pid
  end

  defp start_silent!(mode) do
    stop_system_connection()
    {:ok, pid} = Silent.start_link(mode)
    pid
  end

  defp restart_silent!(mode) do
    stop_system_connection()
    start_silent!(mode)
  end

  defp stop_system_connection do
    case Process.whereis(:serviceradar_certificate_system) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp fingerprints(connections), do: Enum.map(connections, & &1.fingerprint)

  defp requested_offset(requests, server, offset) do
    subject = "$SYS.REQ.SERVER.#{server}.CONNZ"

    Enum.any?(requests, fn request ->
      request["subject"] == subject and request["offset"] == offset and
        request["limit"] == @page_limit
    end)
  end
end
