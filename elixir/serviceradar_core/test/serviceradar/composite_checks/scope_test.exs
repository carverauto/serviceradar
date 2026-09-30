defmodule ServiceRadar.CompositeChecks.ScopeTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.CompositeChecks.Scope

  defmodule StubRunner do
    @moduledoc false

    def query_page(_query, opts) do
      case Keyword.get(opts, :cursor) do
        nil ->
          {:ok, %{rows: [%{"uid" => "device-1"}, %{"uid" => "device-2"}], next_cursor: "c1"}}

        "c1" ->
          {:ok, %{rows: [%{"uid" => "device-3"}], next_cursor: nil}}
      end
    end
  end

  defmodule FailingRunner do
    @moduledoc false
    def query_page(_query, _opts), do: {:error, :boom}
  end

  defmodule EmptyRunner do
    @moduledoc false
    def query_page(_query, _opts), do: {:ok, %{rows: [], next_cursor: nil}}
  end

  defmodule MessyRunner do
    @moduledoc false

    def query_page(_query, _opts) do
      {:ok,
       %{
         rows: [
           %{"uid" => "device-1"},
           %{"id" => "device-2"},
           %{"uid" => ""},
           %{"hostname" => "no-uid-here"},
           "not-a-map"
         ],
         next_cursor: nil
       }}
    end
  end

  describe "normalize/1" do
    test "accepts a device query" do
      assert {:ok, normalized} = Scope.normalize("in:devices source:armis")
      assert normalized =~ "devices"
    end

    test "rejects a non-device query" do
      assert {:error, :scope_must_target_devices} = Scope.normalize("in:flows src_ip:10.0.0.1")
    end
  end

  describe "stream_uids/2" do
    test "pages until the cursor runs out" do
      pages =
        "in:devices"
        |> Scope.stream_uids(runner: StubRunner, page_limit: 2)
        |> Enum.to_list()

      assert pages == [["device-1", "device-2"], ["device-3"]]
    end

    test "yields one empty page for an empty scope" do
      pages =
        "in:devices"
        |> Scope.stream_uids(runner: EmptyRunner)
        |> Enum.to_list()

      assert pages == [[]]
    end

    test "skips rows with no usable uid" do
      pages =
        "in:devices"
        |> Scope.stream_uids(runner: MessyRunner)
        |> Enum.to_list()

      assert pages == [["device-1", "device-2"]]
    end

    test "raises on a runner error rather than yielding a short stream" do
      # A caller that saw a failed page as "no devices here" would conclude
      # those devices left the scope and delete their verdicts.
      assert_raise RuntimeError, ~r/scope query failed/, fn ->
        "in:devices" |> Scope.stream_uids(runner: FailingRunner) |> Enum.to_list()
      end
    end
  end

  describe "count/2" do
    test "sums every page" do
      assert {:ok, 3} = Scope.count("in:devices", runner: StubRunner, page_limit: 2)
    end

    test "returns an error tuple instead of raising" do
      assert {:error, message} = Scope.count("in:devices", runner: FailingRunner)
      assert message =~ "scope query failed"
    end
  end

  describe "contains?/3" do
    defmodule RecordingRunner do
      @moduledoc false

      # Answers with the uids the SRQL list filter names, minus one the scope
      # does not select, and reports the request to the test process.
      def query_page(query, opts) do
        send(self(), {:srql_request, query, opts})

        [_, list] = Regex.run(~r/uid:\((.*)\)$/, query)

        uids =
          list
          |> String.split(",")
          |> Enum.map(&(&1 |> String.trim_leading("\"") |> String.trim_trailing("\"")))
          |> Enum.reject(&(&1 == "out-of-scope"))

        {:ok, %{rows: Enum.map(uids, &%{"uid" => &1}), next_cursor: nil}}
      end
    end

    test "restricts the scope to the page with one quoted SRQL uid list" do
      assert {:ok, in_scope} =
               Scope.contains?("in:devices", ["sr:a", "out-of-scope", "sr:b"],
                 runner: RecordingRunner
               )

      assert in_scope == MapSet.new(["sr:a", "sr:b"])
      assert_received {:srql_request, query, _opts}
      assert query == ~s|in:devices uid:("sr:a","out-of-scope","sr:b")|
    end

    # SRQL applies a default limit of 100 when a request omits one, which would
    # silently drop the rest of a full page.
    test "always requests at least a full page" do
      uids = for n <- 1..Scope.dirty_page_limit(), do: "device-#{n}"

      assert {:ok, in_scope} = Scope.contains?("in:devices", uids, runner: RecordingRunner)
      assert MapSet.size(in_scope) == Scope.dirty_page_limit()
      assert_received {:srql_request, _query, opts}
      assert opts[:limit] >= Scope.dirty_page_limit()

      assert {:ok, _} = Scope.contains?("in:devices", ["device-1"], runner: RecordingRunner)
      assert_received {:srql_request, _query, small_opts}
      assert small_opts[:limit] >= Scope.dirty_page_limit()
    end

    test "escapes quotes and backslashes in uids" do
      assert {:ok, _} = Scope.contains?("in:devices", [~S(a"b\c)], runner: RecordingRunner)
      assert_received {:srql_request, query, _opts}
      assert query == ~S|in:devices uid:("a\"b\\c")|
    end

    test "refuses a page larger than SRQL's list limit instead of truncating" do
      uids = for n <- 0..Scope.dirty_page_limit(), do: "device-#{n}"

      assert {:error, {:too_many_uids, _count, _limit}} =
               Scope.contains?("in:devices", uids, runner: RecordingRunner)

      refute_received {:srql_request, _query, _opts}
    end

    test "an empty page issues no query" do
      assert {:ok, in_scope} = Scope.contains?("in:devices", [], runner: RecordingRunner)
      assert MapSet.size(in_scope) == 0
      refute_received {:srql_request, _query, _opts}
    end

    test "returns the runner error rather than an empty scope" do
      assert {:error, :boom} = Scope.contains?("in:devices", ["device-1"], runner: FailingRunner)
    end
  end
end
