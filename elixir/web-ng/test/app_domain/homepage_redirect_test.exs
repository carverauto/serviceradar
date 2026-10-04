defmodule ServiceRadarWebNG.HomepageRedirectTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Auth.SSOProvisioning
  alias ServiceRadarWebNGWeb.HomepageForm
  alias ServiceRadarWebNGWeb.OIDCController
  alias ServiceRadarWebNGWeb.SAMLController
  alias ServiceRadarWebNGWeb.UserAuth

  @moduletag :unit
  @moduletag :db_free

  test "an explicit return path wins and is not replaced by the homepage" do
    assert UserAuth.login_destination("/devices/host01", fn ->
             raise "homepage must not run"
           end) == {"/devices/host01", nil}
  end

  test "a missing return path uses the homepage" do
    assert UserAuth.login_destination(nil, fn -> {"/dashboards", nil} end) == {"/dashboards", nil}
    assert UserAuth.login_destination("  ", fn -> {"/dashboards", "skipped"} end) == {"/dashboards", "skipped"}
  end

  test "an unsafe return path stays on the platform home and does not consult the homepage" do
    assert UserAuth.login_destination("https://evil.example", fn ->
             raise "homepage must not run"
           end) == {"/dashboard", nil}

    assert UserAuth.login_destination("//evil.example", fn ->
             raise "homepage must not run"
           end) == {"/dashboard", nil}
  end

  test "the homepage form accepts only an allowlisted kind and dashboard id" do
    assert HomepageForm.attrs_from(%{"choice" => "inherit"}) ==
             {:ok, %{homepage_kind: nil, homepage_target: nil}}

    assert HomepageForm.attrs_from(%{"choice" => "dashboard", "dashboard" => "package:edge-overview"}) ==
             {:ok, %{homepage_kind: :package, homepage_target: "edge-overview"}}

    assert HomepageForm.attrs_from(%{"choice" => "dashboard", "dashboard" => "https://evil.example"}) == :error
    assert HomepageForm.attrs_from(%{"choice" => "https://evil.example"}) == :error
  end

  test "sso provisioning syncs group membership before the caller logs the user in" do
    oidc = calls(OIDCController, :complete_oidc_login)
    assert call_before?(oidc, {:local, :find_or_create_user}, {UserAuth, :log_in_user})

    saml = calls(SAMLController, :handle_successful_assertion)
    assert call_before?(saml, {:local, :find_or_create_user}, {UserAuth, :log_in_user})
    refute "/dashboard" in binaries(SAMLController, :handle_successful_assertion)

    provisioning = calls(SSOProvisioning, :find_or_create_user)

    assert Enum.count(provisioning, &(&1 == {:local, :maybe_sync_group_memberships})) >= 2
    refute Enum.any?(provisioning, &match?({UserAuth, :log_in_user}, &1))
  end

  defp call_before?(calls, earlier, later) do
    earlier_at = Enum.find_index(calls, &(&1 == earlier))
    later_at = Enum.find_index(calls, &(&1 == later))
    is_integer(earlier_at) and is_integer(later_at) and earlier_at < later_at
  end

  defp calls(module, function) do
    module
    |> function_forms(function)
    |> Enum.flat_map(fn {:function, _anno, _name, _arity, clauses} -> walk(clauses) end)
  end

  defp binaries(module, function) do
    module
    |> function_forms(function)
    |> walk_binaries()
  end

  defp function_forms(module, function) do
    # :beam_lib resolves a module atom against the working directory rather
    # than the code path, so locate the compiled beam through the code server.
    {:module, ^module} = Code.ensure_loaded(module)

    {:ok, {^module, [{:abstract_code, {:raw_abstract_v1, forms}}]}} =
      :beam_lib.chunks(:code.which(module), [:abstract_code])

    matched =
      Enum.filter(forms, fn
        {:function, _anno, ^function, _arity, _clauses} -> true
        _other -> false
      end)

    assert matched != []
    matched
  end

  defp walk(list) when is_list(list), do: Enum.flat_map(list, &walk/1)

  defp walk({:call, _anno, {:remote, _anno2, {:atom, _anno3, module}, {:atom, _anno4, function}}, args}) do
    [{module, function} | walk(args)]
  end

  defp walk({:call, _anno, {:atom, _anno2, function}, args}) do
    [{:local, function} | walk(args)]
  end

  defp walk(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> walk()
  defp walk(_other), do: []

  defp walk_binaries(list) when is_list(list), do: Enum.flat_map(list, &walk_binaries/1)
  defp walk_binaries({:string, _anno, value}) when is_list(value), do: [List.to_string(value)]
  defp walk_binaries(value) when is_binary(value), do: [value]
  defp walk_binaries(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> walk_binaries()
  defp walk_binaries(_other), do: []
end
