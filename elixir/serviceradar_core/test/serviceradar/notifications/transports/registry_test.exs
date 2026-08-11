defmodule ServiceRadar.Notifications.TransportFakes do
  @moduledoc """
  Stand-ins for the conformance checks.

  They are deliberately NOT the real transports: this file must stay meaningful
  before those modules exist, and a conformance test that can only fail when a
  real transport is broken cannot prove that the checker itself works.
  """

  defmodule Conforming do
    @moduledoc false
    @behaviour ServiceRadar.Notifications.Transport

    alias ServiceRadar.Notifications.Transport.Result

    @impl true
    def deliver(_request, _opts), do: Result.delivered()

    @impl true
    def test(_request, _opts), do: Result.delivered()

    @impl true
    def validate_config(_config), do: :ok

    @impl true
    def capabilities, do: [:send, :test]
  end

  defmodule LegacySend do
    @moduledoc false
    import Kernel, except: [send: 2]

    def deliver(_request, _opts), do: :ok
    def send(_request, _opts), do: :ok
    def test(_request, _opts), do: :ok
    def validate_config(_config), do: :ok
    def capabilities, do: [:send, :test]
  end

  defmodule MissingTestCallback do
    @moduledoc false
    def deliver(_request, _opts), do: :ok
    def validate_config(_config), do: :ok
    def capabilities, do: [:send, :test]
  end

  defmodule MissingTestCapability do
    @moduledoc false
    def deliver(_request, _opts), do: :ok
    def test(_request, _opts), do: :ok
    def validate_config(_config), do: :ok
    def capabilities, do: [:send]
  end

  defmodule BadCapabilities do
    @moduledoc false
    def deliver(_request, _opts), do: :ok
    def test(_request, _opts), do: :ok
    def validate_config(_config), do: :ok
    def capabilities, do: :send
  end
end

defmodule ServiceRadar.Notifications.Transports.RegistryTest do
  @moduledoc """
  The registry is the boundary that keeps a database column from naming an
  arbitrary module. These tests are database-free on purpose: resolution is a
  pure lookup over a compile-time list, and if it ever needs a repo it has
  stopped being an allowlist.
  """

  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.NotificationProvider
  alias ServiceRadar.Notifications.Transport
  alias ServiceRadar.Notifications.TransportFakes
  alias ServiceRadar.Notifications.Transports.Registry

  describe "allowlist/0" do
    test "pairs every stored name with a module" do
      assert [_ | _] = Registry.allowlist()

      for {name, module} <- Registry.allowlist() do
        assert is_binary(name)
        assert is_atom(module)
        assert Atom.to_string(module) == "Elixir." <> name
      end
    end

    test "names and modules are unique" do
      names = Enum.map(Registry.allowlist(), &elem(&1, 0))
      modules = Enum.map(Registry.allowlist(), &elem(&1, 1))

      assert names == Enum.uniq(names)
      assert modules == Enum.uniq(modules)
    end

    test "allowlisted_module_names/0 is sorted and matches the pairs" do
      names = Registry.allowlisted_module_names()

      assert names == Enum.sort(names)
      assert Enum.sort(names) == Enum.sort(Enum.map(Registry.allowlist(), &elem(&1, 0)))
    end

    test "covers the four Phase 1 launch transports plus stream" do
      assert Registry.allowlisted_module_names() == [
               "ServiceRadar.Notifications.Transports.Discord",
               "ServiceRadar.Notifications.Transports.Email",
               "ServiceRadar.Notifications.Transports.GenericWebhook",
               "ServiceRadar.Notifications.Transports.Slack",
               "ServiceRadar.Notifications.Transports.Stream"
             ]
    end
  end

  describe "single source of truth" do
    test "NotificationProvider validates against the registry's list, not a copy" do
      # Two copies of an allowlist drift, and the drift is invisible until a
      # provider saves with a module dispatch cannot resolve (or the reverse).
      assert NotificationProvider.implementation_module_allowlist() ==
               Registry.allowlisted_module_names()
    end

    test "every name the provider resource accepts resolves here" do
      for name <- NotificationProvider.implementation_module_allowlist() do
        assert {:ok, module} = Registry.resolve(name)
        assert is_atom(module)
      end
    end
  end

  describe "resolve/1" do
    test "resolves an allowlisted name to its module" do
      {name, module} = hd(Registry.allowlist())

      assert {:ok, ^module} = Registry.resolve(name)
    end

    test "rejects an unknown module name with a typed error instead of raising" do
      assert {:error, {:unknown_transport_module, "ServiceRadar.Evil"}} =
               Registry.resolve("ServiceRadar.Evil")
    end

    test "rejects a real, loaded module that is not allowlisted" do
      # The point of the allowlist: an existing, loaded, perfectly ordinary
      # module is still refused. String.to_existing_atom/1 would have admitted
      # every one of these.
      assert {:error, {:unknown_transport_module, _}} = Registry.resolve("Elixir.System")
      assert {:error, {:unknown_transport_module, _}} = Registry.resolve(System)
      assert {:error, {:unknown_transport_module, _}} = Registry.resolve(:os)
      assert {:error, {:unknown_transport_module, _}} = Registry.resolve(Enum)
    end

    test "accepts an already-resolved allowlisted module" do
      {_name, module} = hd(Registry.allowlist())

      assert {:ok, ^module} = Registry.resolve(module)
    end

    test "rejects non-string, non-module values" do
      for value <- [nil, 42, %{}, ["a"], {:slack, 1}, 1.5] do
        assert {:error, {:invalid_transport_module, ^value}} = Registry.resolve(value)
      end
    end

    test "does not create an atom for an unknown name" do
      name =
        "ServiceRadar.Notifications.Transports.NeverDefined#{System.unique_integer([:positive])}"

      assert {:error, {:unknown_transport_module, ^name}} = Registry.resolve(name)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom("Elixir." <> name)
      end
    end

    test "a name that differs only in case or whitespace is refused" do
      assert {:error, _} = Registry.resolve("serviceradar.notifications.transports.slack")
      assert {:error, _} = Registry.resolve(" ServiceRadar.Notifications.Transports.Slack")
      assert {:error, _} = Registry.resolve("ServiceRadar.Notifications.Transports.Slack ")
    end
  end

  describe "allowed?/1 and name_for/1" do
    test "allowed? mirrors resolve" do
      {name, _module} = hd(Registry.allowlist())

      assert Registry.allowed?(name)
      refute Registry.allowed?("ServiceRadar.Notifications.Transports.Nope")
      refute Registry.allowed?(nil)
    end

    test "name_for round-trips every allowlisted module" do
      for {name, module} <- Registry.allowlist() do
        assert {:ok, ^name} = Registry.name_for(module)
        assert {:ok, ^module} = Registry.resolve(name)
      end
    end

    test "name_for rejects a module outside the list" do
      assert {:error, {:unknown_transport_module, _}} = Registry.name_for(Enum)
      assert {:error, {:invalid_transport_module, "Enum"}} = Registry.name_for("Enum")
    end
  end

  describe "describe_error/1" do
    test "names the offending value and lists the allowlist" do
      message = Registry.describe_error({:unknown_transport_module, "ServiceRadar.Evil"})

      assert message =~ "ServiceRadar.Evil"
      assert message =~ "ServiceRadar.Notifications.Transports.Slack"
    end

    test "describes a malformed value" do
      assert Registry.describe_error({:invalid_transport_module, 42}) =~ "42"
    end
  end

  describe "conformance/1" do
    test "accepts a module implementing all four callbacks" do
      assert :ok = Registry.conformance(TransportFakes.Conforming)
      assert Registry.conforms?(TransportFakes.Conforming)
    end

    test "rejects the legacy send/2 spelling" do
      assert {:error, problems} = Registry.conformance(TransportFakes.LegacySend)
      assert {:legacy_send_callback, {:send, 2}} in problems
    end

    test "names a missing callback" do
      assert {:error, problems} = Registry.conformance(TransportFakes.MissingTestCallback)
      assert {:missing_callback, {:test, 2}} in problems
    end

    test "requires both send and test capabilities" do
      assert {:error, problems} = Registry.conformance(TransportFakes.MissingTestCapability)
      assert {:missing_capabilities, [:test]} in problems
    end

    test "rejects a non-list capabilities/0" do
      assert {:error, problems} = Registry.conformance(TransportFakes.BadCapabilities)
      assert {:capabilities_not_a_list, :send} in problems
    end

    test "reports a module that is not compiled into the release" do
      absent = Module.concat(["ServiceRadar", "Notifications", "Transports", "NotBuilt"])

      assert {:error, [{:not_loaded, ^absent}]} = Registry.conformance(absent)
    end

    test "required callbacks are exactly the four in design D2" do
      assert Enum.sort(Transport.required_callbacks()) == [
               capabilities: 0,
               deliver: 2,
               test: 2,
               validate_config: 1
             ]

      refute {:send, 2} in Transport.required_callbacks()
    end
  end

  describe "Transport result dispositions" do
    alias ServiceRadar.Notifications.Transport.Result

    test "the vocabulary is exactly three" do
      assert Result.dispositions() == [:delivered, :retryable_failure, :permanent_failure]
    end

    test "outcome/2 encodes C7: retries stay pending, failed is terminal" do
      delivered = Result.delivered(external_correlation_id: "1712345.000100")
      retryable = Result.retryable_failure("http_503")
      permanent = Result.permanent_failure("http_400")

      assert Result.outcome(delivered, true) == :sent
      assert Result.outcome(delivered, false) == :sent

      # Retry-eligible: the row stays :pending with next_attempt_at set. It does
      # NOT pass through :failed, because retry-due selection reads :pending.
      assert Result.outcome(retryable, true) == :retry
      # Budget exhausted is the only retry path into the terminal state.
      assert Result.outcome(retryable, false) == :failed

      # A permanent failure never consumes further attempts.
      assert Result.outcome(permanent, true) == :failed
      assert Result.outcome(permanent, false) == :failed
    end

    test "predicates agree with the disposition" do
      assert Result.delivered?(Result.delivered())
      refute Result.delivered?(Result.retryable_failure("timeout"))
      assert Result.retryable?(Result.retryable_failure("timeout"))
      refute Result.retryable?(Result.permanent_failure("http_404"))
      refute Result.retryable?(Result.delivered())
    end

    test "http status classification matches the spec's retry rules" do
      for status <- [200, 201, 202, 204],
          do: assert(Transport.classify_http_status(status) == :delivered)

      for status <- [408, 429, 500, 502, 503, 504],
          do: assert(Transport.classify_http_status(status) == :retryable_failure)

      for status <- [301, 400, 401, 403, 404, 409, 422],
          do: assert(Transport.classify_http_status(status) == :permanent_failure)
    end

    test "result_from_http_status/2 carries a stable error_class" do
      assert %Result{disposition: :retryable_failure, error_class: "http_503"} =
               Transport.result_from_http_status(503)

      assert %Result{disposition: :permanent_failure, error_class: "http_400"} =
               Transport.result_from_http_status(400)

      assert %Result{disposition: :delivered, external_correlation_id: "abc"} =
               Transport.result_from_http_status(200, external_correlation_id: "abc")
    end

    test "capability contract requires both send and test in every tier" do
      assert Transport.required_capabilities() == [:send, :test]
      assert Transport.declares_required_capabilities?([:send, :test, :threading])
      refute Transport.declares_required_capabilities?([:send])
      refute Transport.declares_required_capabilities?([:test])
      refute Transport.declares_required_capabilities?(:send)
      refute Transport.declares_required_capabilities?(nil)
    end
  end
end
