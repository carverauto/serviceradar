defmodule Palisade.Plug.RequestGuardTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Palisade.Plug.RequestGuard

  defp run(conn, opts \\ []), do: RequestGuard.call(conn, RequestGuard.init(opts))

  describe "bodies on GET and HEAD" do
    test "a GET with a body is rejected" do
      conn = :get |> conn("/", "smuggled") |> put_req_header("content-length", "8") |> run()

      assert conn.halted
      assert conn.status == 400
      assert conn.resp_body == "Request body not allowed"
    end

    test "a GET or HEAD with transfer-encoding is rejected" do
      for method <- [:get, :head] do
        conn = method |> conn("/") |> put_req_header("transfer-encoding", "chunked") |> run()
        assert conn.status == 400, "expected #{method} with transfer-encoding to be rejected"
      end
    end

    test "content-length: 0 and bodies on other methods pass" do
      refute (:get |> conn("/") |> put_req_header("content-length", "0") |> run()).halted
      refute (:post |> conn("/", "a=1") |> put_req_header("content-length", "3") |> run()).halted
    end
  end

  test "an over-long query string is rejected with 414" do
    conn = run(conn(:get, "/?q=" <> String.duplicate("a", 100)), max_query_length: 50)

    assert conn.halted
    assert conn.status == 414
    refute run(conn(:get, "/?q=short"), max_query_length: 50).halted
  end

  test "too many headers are rejected with 431" do
    conn = Enum.reduce(1..5, conn(:get, "/"), &put_req_header(&2, "x-h#{&1}", "v"))

    assert run(conn, max_headers: 4).status == 431
    refute run(conn, max_headers: 5).halted
  end

  describe "query parameter allow-list" do
    test "a list applies to every request" do
      opts = [allowed_query_params: ["q", "filter"]]

      refute run(conn(:get, "/?q=a&filter[name]=b"), opts).halted
      assert run(conn(:get, "/?q=a&debug=1"), opts).status == 400
      refute run(conn(:get, "/"), opts).halted
    end

    test "a map restricts only the listed paths" do
      opts = [allowed_query_params: %{"/search" => ["q"]}]

      refute run(conn(:get, "/search?q=a"), opts).halted
      assert run(conn(:get, "/search?q=a&x=1"), opts).status == 400
      refute run(conn(:get, "/other?x=1"), opts).halted
    end

    test "a function decides per request, nil meaning unrestricted" do
      allowed = fn conn -> if conn.request_path == "/search", do: ["q"] end
      opts = [allowed_query_params: allowed]

      assert run(conn(:get, "/search?x=1"), opts).status == 400
      refute run(conn(:get, "/other?x=1"), opts).halted
    end

    test "names are compared after percent-decoding" do
      opts = [allowed_query_params: ["q"]]

      refute run(conn(:get, "/?%71=a"), opts).halted
      assert run(conn(:get, "/?%zz=a"), opts).status == 400
    end
  end

  test "on_reject builds a custom response" do
    on_reject = fn conn, status, reason -> send_resp(conn, status, "custom #{reason}") end

    conn =
      run(conn(:get, "/?q=" <> String.duplicate("a", 10)),
        max_query_length: 5,
        on_reject: on_reject
      )

    assert conn.halted
    assert conn.resp_body == "custom query_too_long"
  end

  test "options are validated" do
    assert_raise ArgumentError, fn -> RequestGuard.init(max_query_length: 0) end
    assert_raise ArgumentError, fn -> RequestGuard.init(allowed_query_params: [:q]) end
    assert_raise ArgumentError, fn -> RequestGuard.init(allowed_query_params: "q") end
    assert_raise ArgumentError, fn -> RequestGuard.init(on_reject: fn _ -> :ok end) end
  end
end
