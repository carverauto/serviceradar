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
end
