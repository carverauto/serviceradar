defmodule ServiceRadar.Automation.Ansible.PlaybookLaunchableReadTest do
  @moduledoc """
  DB-backed regression coverage for `Playbook.list_launchable/2` — the single
  source of truth the device-details Ansible panel and `/ansible/launch` page
  use to enumerate parse-valid AWX launch candidates.

  Before the fix, every launch surface piped the bare `Playbook` module into
  `Ash.Query.filter/2 |> Ash.read/2` **without naming a read action**. Because
  `Playbook` had no primary read action, `Ash.read` raised
  `Ash.Error.Invalid.NoPrimaryAction`, which the callers' `case _ -> []` clauses
  swallowed into an empty list — so an AWX-managed device whose controller has
  bound job-templates showed the false "No launchable playbooks are bound to
  this device's AWX controller" empty state.

  This test drives the real read path against seeded controllers + playbooks and
  asserts:

    * a controller with parse-valid AWX job-template rows yields exactly its
      candidates (sorted, scoped, excluding unbound and other-controller rows);
    * omitting the controller scope lists candidates across all
      controllers;
    * a controller with no bound job-templates yields `[]` (the empty state only
      appears when the controller truly has none).

  It is DB-gated; run with:

      mix test --include integration \\
        test/serviceradar/automation/ansible/playbook_launchable_read_test.exs
  """
  use ServiceRadar.DataCase, async: true

  alias Ash.Seed
  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Automation.Ansible.Controller
  alias ServiceRadar.Automation.Ansible.Playbook
  alias ServiceRadar.TestSupport
  alias ServiceRadar.TestSupport.CredentialIntegrationFixtures

  @moduletag :integration

  setup_all do
    TestSupport.start_core!()
    :ok
  end

  setup do
    tag = System.unique_integer([:positive])

    c1 = seed_controller(tag, "one")
    c2 = seed_controller(tag, "two")
    c3 = seed_controller(tag, "three")

    # c1: two launchable (bound to an AWX job template) + one unbound.
    p1a = seed_playbook(c1.id, "#{tag}-c1-aaa", 100)
    p1b = seed_playbook(c1.id, "#{tag}-c1-bbb", 101)
    _unbound = seed_playbook(c1.id, "#{tag}-c1-unbound", nil)

    _parse_error =
      Seed.seed!(Playbook, %{
        source_type: :awx,
        name: "#{tag}-c1-parse-error",
        controller_id: c1.id,
        awx_job_template_id: 102,
        parse_status: :error
      })

    # c2: one launchable, to prove controller scoping.
    p2a = seed_playbook(c2.id, "#{tag}-c2-zzz", 200)

    # c3: only an unbound playbook -> genuinely no launchable playbooks.
    _c3_unbound = seed_playbook(c3.id, "#{tag}-c3-unbound", nil)

    %{c1: c1, c2: c2, c3: c3, p1a: p1a, p1b: p1b, p2a: p2a}
  end

  test "scopes to the controller's bound job-templates, sorted, excluding unbound", ctx do
    assert {:ok, rows} =
             Playbook.list_launchable(%{controller_id: ctx.c1.id}, actor: actor())

    assert Enum.map(rows, & &1.name) == [ctx.p1a.name, ctx.p1b.name]
    assert Enum.map(rows, & &1.id) == [ctx.p1a.id, ctx.p1b.id]
    assert Enum.all?(rows, &(&1.controller_id == ctx.c1.id))
    assert Enum.all?(rows, &(not is_nil(&1.awx_job_template_id)))

    # The other controller's playbook must not leak in.
    refute ctx.p2a.id in Enum.map(rows, & &1.id)
  end

  test "a second controller only sees its own launchable playbooks", ctx do
    assert {:ok, rows} =
             Playbook.list_launchable(%{controller_id: ctx.c2.id}, actor: actor())

    assert Enum.map(rows, & &1.id) == [ctx.p2a.id]
  end

  test "without a controller scope, lists launchable playbooks across controllers", ctx do
    assert {:ok, rows} = Playbook.list_launchable(%{}, actor: actor())

    ids = MapSet.new(rows, & &1.id)
    assert MapSet.member?(ids, ctx.p1a.id)
    assert MapSet.member?(ids, ctx.p1b.id)
    assert MapSet.member?(ids, ctx.p2a.id)

    # Every returned row is eligible for secure binding/membership resolution.
    assert Enum.all?(rows, &(not is_nil(&1.awx_job_template_id)))
  end

  test "empty state: a controller with no bound job-templates yields []", ctx do
    assert {:ok, []} =
             Playbook.list_launchable(%{controller_id: ctx.c3.id}, actor: actor())
  end

  defp actor, do: SystemActor.system(:test_playbook_launchable)

  defp seed_controller(tag, suffix) do
    Seed.seed!(Controller, %{
      name: "launchable-test-#{tag}-#{suffix}",
      base_url: "https://awx.test.invalid",
      agent_id: "agent-launchable-test",
      credential_secret_id: CredentialIntegrationFixtures.secret_id!()
    })
  end

  defp seed_playbook(controller_id, name, job_template_id) do
    Seed.seed!(Playbook, %{
      source_type: :awx,
      name: name,
      controller_id: controller_id,
      awx_job_template_id: job_template_id,
      parse_status: :ok
    })
  end
end
