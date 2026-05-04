# Violation fixtures

One fixture file per frozen catalog code (`Crank.Errors.Catalog`). The
fixtures fall into three families based on the layer the code is detected
at:

- **`*.exs` — compile-time fixtures.** Source that triggers the violation
  if compiled. Loaded by `Code.eval_string/2` inside the relevant test
  with `assert_raise CompileError, ~r/<code>/`. Static call-site codes
  (`CRANK_PURITY_001..006`) and type codes (`CRANK_TYPE_001..003`) live
  here.
- **`*.txt` — runtime/marker fixtures.** Plain-text files pointing at
  where in the test suite the code is exercised. Used for codes that
  can only be triggered at runtime (the `CRANK_RUNTIME_*` and
  `CRANK_TRACE_*` codes) or via mix-task wiring (`CRANK_SETUP_*`,
  `CRANK_META_*`, `CRANK_DEP_*`).
- **Topology fixtures (`CRANK_DEP_*`)** are exercised via the existing
  `test/crank/boundary_integration_test.exs` and the integration tests
  in `test/integration/`. The marker file documents the path.

`test/crank/errors/violation_fixtures_test.exs` walks the catalog and
asserts every code has a fixture file matching one of these patterns.
That test is what makes "every code has a fixture" enforceable; without
it, adding a code is allowed to skip fixture creation, which the v4 plan
forbids.
