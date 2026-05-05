# Purity enforcement

You probably arrived here because your build emitted a `CRANK_*` error or warning. This page explains the layers that produce those messages and points you at the right reference guide.

`turn/3` is pure: same inputs, same outputs, no side effects. Crank enforces this in three layers, each catching a different class of violation:

- **Compile-time call-site checks.** Calling a known-impure function from inside `turn/3` is a compile error.
- **Post-compile topology checks** (via [Boundary](https://github.com/sasa1977/boundary)). The machine module is forbidden from depending on infrastructure modules.
- **Runtime tracing under property tests.** During `Crank.PropertyTest` runs, any process message, ETS write, or other observable effect from inside `turn/3` fails the test.

Most users never read past this paragraph. The layers are silent when your code is clean. The pages below exist for the moment something fails.

## Reference

- [Violations index](violations/index.md) — every `CRANK_*` code with its detection layer and doc page. Start here if you have an error code in hand.
- [Boundary setup](boundary-setup.md) — wire the topology layer with `mix crank.gen.config` (or by hand).
- [Property testing](property-testing.md) — pure-mode + StreamData + tracing, the canonical purity-verification pattern.
- [Suppressions](suppressions.md) — the three layer-specific suppression mechanisms (source comments / Boundary config / `:allow` opt). Read this before suppressing anything.
