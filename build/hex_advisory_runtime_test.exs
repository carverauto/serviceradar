ExUnit.start()

defmodule ServiceRadar.HexAdvisoryRuntimeTest do
  use ExUnit.Case, async: false

  @body_bytes 4_096

  test "locked phoenix_html rejects injected attribute names and still escapes values" do
    start!(:phoenix_html)
    assert vsn(:phoenix_html) == "4.4.0"

    assert_raise ArgumentError, ~r/expected attribute name/, fn ->
      Phoenix.HTML.attributes_escape(%{"x onmouseover" => "alert(1)"})
    end

    assert_raise ArgumentError, ~r/expected attribute name/, fn ->
      Phoenix.HTML.attributes_escape([{"data", [{"a=b", "1"}]}])
    end

    # 4.4.0's published examples: atom keys are still dasherized, and a binary
    # value cannot break out of the attribute.
    assert Phoenix.HTML.attributes_escape(title: "the title", id: "the id", selected: true)
           |> Phoenix.HTML.safe_to_string() ==
             " title=\"the title\" id=\"the id\" selected"

    rendered =
      %{"title" => "a<b\"c"}
      |> Phoenix.HTML.attributes_escape()
      |> Phoenix.HTML.safe_to_string()

    assert rendered =~ "title="
    assert rendered =~ "&lt;"
    assert rendered =~ "&quot;"
    refute rendered =~ "a<b"
    refute rendered =~ "onmouseover"
  end

  test "locked ssl_verify_fun keeps a wildcard inside the left-most label" do
    start!(:ssl_verify_fun)
    assert vsn(:ssl_verify_fun) == "1.1.9"

    partial = cert_with_san("f*.example.net")
    assert_hostname(partial, "foo.example.net", :valid)
    assert_hostname(partial, "f.evil.example.net", :fail)
    assert_hostname(partial, "f.a.b.example.net", :fail)

    whole = cert_with_san("*.example.net")
    assert_hostname(whole, "www.example.net", :valid)
    assert_hostname(whole, "a.b.example.net", :fail)

    exact = cert_with_san("www.example.net")
    assert_hostname(exact, "www.example.net", :valid)
    assert_hostname(exact, "evil.example.net", :fail)

    ip_wildcard = cert_with_san("*.168.1.1")
    assert_hostname(ip_wildcard, "192.168.1.1", :fail)
  end

  test "locked bandit serves HTTP/1 and reassembles one-byte HTTP/2 DATA frames" do
    start!(:bandit)
    start!(:mint)
    assert vsn(:bandit) == "1.14.1"

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.EchoPlug, self()},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      Process.exit(server, :normal)
    end)

    http1_body = "plain-body"
    assert {:ok, 200, ^http1_body} = request_http1(port, http1_body)

    payload = :binary.copy(<<1>>, @body_bytes)

    assert {:ok, 200, ^payload, stats} = request_http2_byte_frames(port, payload)
    assert stats.frames == @body_bytes
    assert stats.delta_bytes < @body_bytes * 30 + 100_000,
           "stream grew by #{stats.delta_bytes} bytes while holding #{@body_bytes} one-byte frames (peak #{stats.peak_bytes}, baseline #{stats.baseline_bytes})"
  end

  defmodule EchoPlug do
    @behaviour Plug

    @impl Plug
    def init(observer) when is_pid(observer), do: observer

    @impl Plug
    def call(conn, observer) do
      send(observer, {:reading, self()})
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000, read_timeout: 20_000)
      Plug.Conn.send_resp(conn, 200, body)
    end
  end

  defp request_http1(port, body) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1], timeout: 5_000)

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "POST", "/", [{"content-type", "text/plain"}], body)

    {conn, status, resp} = recv_response(conn, ref, "", nil, false)
    Mint.HTTP.close(conn)
    {:ok, status, resp}
  end

  defp request_http2_byte_frames(port, payload) do
    {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http2], timeout: 5_000)

    {:ok, conn, ref} =
      Mint.HTTP.request(conn, "POST", "/", [{"content-type", "application/octet-stream"}], :stream)

    {conn, stream_pid} = await_reader(conn)

    baseline = process_memory(stream_pid)
    sampler = spawn_link(fn -> sample_loop(stream_pid, baseline, baseline) end)
    conn = send_one_byte_frames(conn, ref, payload)
    {:ok, conn} = Mint.HTTP.stream_request_body(conn, ref, :eof)
    {conn, status, resp} = recv_response(conn, ref, "", nil, false)
    send(sampler, {:stop, self()})

    stats =
      receive do
        {:stats, sampled} -> sampled
      after
        2_000 -> %{baseline_bytes: baseline, peak_bytes: baseline, delta_bytes: 0, frames: byte_size(payload)}
      end

    Mint.HTTP.close(conn)
    {:ok, status, resp, Map.put(stats, :frames, byte_size(payload))}
  end

  defp send_one_byte_frames(conn, ref, <<byte, rest::binary>>) do
    case Mint.HTTP.stream_request_body(conn, ref, <<byte>>) do
      {:ok, conn} ->
        send_one_byte_frames(drain_available(conn), ref, rest)

      {:error, _conn, reason} ->
        flunk("HTTP/2 DATA frame send failed: #{inspect(reason)}")
    end
  end

  defp send_one_byte_frames(conn, _ref, <<>>), do: conn

  defp await_reader(conn) do
    receive do
      {:reading, pid} when is_pid(pid) ->
        {conn, pid}

      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, _responses} -> await_reader(conn)
          {:error, _conn, reason, _responses} -> flunk("HTTP/2 setup failed: #{inspect(reason)}")
          :unknown -> await_reader(conn)
        end
    after
      5_000 -> flunk("bandit plug did not start reading the HTTP/2 body")
    end
  end

  defp drain_available(conn) do
    receive do
      message ->
        case Mint.HTTP.stream(conn, message) do
          {:ok, conn, _responses} -> drain_available(conn)
          {:error, conn, _reason, _responses} -> conn
          :unknown -> drain_available(conn)
        end
    after
      0 -> conn
    end
  end

  defp recv_response(conn, ref, body, status, done) do
    if done do
      {conn, status, body}
    else
      receive do
        {:reading, _pid} ->
          recv_response(conn, ref, body, status, done)

        message ->
          case Mint.HTTP.stream(conn, message) do
            {:ok, conn, responses} ->
              {body, status, done} =
                Enum.reduce(responses, {body, status, done}, fn
                  {:status, ^ref, code}, {body, _status, done} -> {body, code, done}
                  {:data, ^ref, data}, {body, status, done} -> {body <> data, status, done}
                  {:done, ^ref}, {body, status, _done} -> {body, status, true}
                  _other, acc -> acc
                end)

              recv_response(conn, ref, body, status, done)

            {:error, _conn, reason, _responses} ->
              flunk("HTTP response failed: #{inspect(reason)}")

            :unknown ->
              recv_response(conn, ref, body, status, done)
          end
      after
        20_000 -> flunk("timed out waiting for the HTTP response")
      end
    end
  end

  defp sample_loop(pid, baseline, peak) do
    receive do
      {:stop, caller} ->
        send(caller, {:stats, %{baseline_bytes: baseline, peak_bytes: peak, delta_bytes: peak - baseline}})
    after
      1 ->
        sample_loop(pid, baseline, max(peak, process_memory(pid)))
    end
  end

  defp process_memory(pid) do
    case Process.alive?(pid) and :erlang.process_info(pid, :memory) do
      {:memory, bytes} -> bytes
      _ -> 0
    end
  end

  defp cert_with_san(dns_name) do
    san = {:Extension, {2, 5, 29, 17}, false, [dNSName: String.to_charlist(dns_name)]}
    algorithm = [digest: :sha256, key: {:namedCurve, :secp256r1}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: algorithm,
          intermediates: [],
          peer: algorithm ++ [extensions: [san]]
        },
        client_chain: %{root: algorithm, intermediates: [], peer: algorithm}
      })

    :public_key.pkix_decode_cert(server[:cert], :otp)
  end

  defp assert_hostname(cert, hostname, :valid) do
    assert {:valid, _} =
             :ssl_verify_hostname.verify_cert_hostname(cert, String.to_charlist(hostname))
  end

  defp assert_hostname(cert, hostname, :fail) do
    assert {:fail, _} =
             :ssl_verify_hostname.verify_cert_hostname(cert, String.to_charlist(hostname))
  end

  defp start!(app) do
    {:ok, _} = Application.ensure_all_started(app)
  end

  defp vsn(app) do
    {:ok, vsn} = :application.get_key(app, :vsn)
    to_string(vsn)
  end
end
