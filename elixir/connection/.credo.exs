{build_config, _binding} = Code.eval_file(Path.expand("../.credo.base.exs", __DIR__))
{ex_slop_checks, _binding} = Code.eval_file(Path.expand("../.credo.ex_slop.exs", __DIR__))
{ex_dna_checks, _binding} = Code.eval_file(Path.expand("../.credo.ex_dna.exs", __DIR__))

extra_checks = ex_slop_checks ++ ex_dna_checks

build_config.(
  included: ["lib/", "test/"],
  extra: extra_checks,
  requires: ["deps/ex_dna/lib/ex_dna/integrations/credo.ex"],
  disabled: [
    {Credo.Check.Design.DuplicatedCode, []},
    {Credo.Check.Readability.PreferImplicitTry, []},
    {Credo.Check.Refactor.Apply, []}
  ]
)
