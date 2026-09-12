# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`eliot.build` — is the build tool for the [Eliot language](https://github.com/robertbraeutigam/eliot),
written *in* Eliot. 

When reading or editing any `.els` file, use the `eliot-code` skill — it is the full language
reference. Eliot is total-by-default (no recursion/loops in user code), effects are written in
direct style, types are values, and there is one `Int` whose range is compiler-tracked
meta-information.

## Architecture

Two source roots. `src/` is the tool: `Clause`/`Descriptor` (the `eliot.pkg` format), `Version` and
`PackageId` (identity and ordering), `Git` and `Cache` (talking to git and mirroring repositories),
`PackageSource` (the resolver's two questions plus the git-backed answer), `Resolution` (MVS).
`test/` mirrors it, plus `TablePackages` — a *named* implementation of `PackageSource`, which is this
project's own effect and so cannot be doubled by the framework. Everything else is mocked by
`eliot.test.Mock`: a case declares nothing, arranges with `whenSpawning`/`withDirectory`/…, acts, and
verifies with `wasCalledOnce`/`calls`/… (`eliot-test/docs/mocking.md`). `FakeWorld` — 195 lines of
hand-written doubles — was deleted when that landed. (`probe/` was deleted on 2026-09-04; `docs/effectful-modules.md`
§9.6 says what that leaves unchecked.)

The design is `docs/build-system.md`; how the effectful modules are shaped and tested is
`docs/effectful-modules.md` — **read §10 of it first**, and read it before touching `Git`, `Cache`,
`PackageSource` or a double. §1–§9 are a record of the carrier era and answer the two questions the
document exists for, but every mechanism they name (carriers, `Suspend`, capture tags, the four rules)
was deleted by effects v6; §10 says what replaced each one and what is now genuinely unchecked.

A suite declares `def testCases: Test` — the framework's row alias for
`{Writer[List[TestResult]]} Unit`, which reaches this project now that a row alias is an ordinary name
resolved through import scope rather than matched by spelling within one file.

**That return type is the only thing deciding what a case may do.** A bare `Test` admits bodies that
assert and nothing else — a `printLine` in one is a compile error at the reference, verified. `in`
supplies `Throw[AssertionError]` per case and is transparent to everything else, so a case wanting
doubles writes `in mocked { … }` and they are bound by `mocked`'s own slot; a suite whose cases must
*really* perform composes the alias with a written-out row, `{Console} Test`. No suite here needs
that. There is no `pure` any more, no capture tag and no carrier.

## Building and running (compiler CLI)

The build will eventually dogfood itself, but is not yet available. Compilation is driven by a sibling checkout of the Eliot
compiler (see `eliot.paths` for its location — `/home/robert/personal/eliot`), whose `examples.run`
Mill task auto-appends the `lang`/`stdlib`/`jvm` layer source roots. You pass this project's own
roots, and the test framework's, as positional arguments:

```bash
cd /home/robert/personal/eliot          # the compiler checkout
./mill examples.run jvm exe-jar -m eliot.test.Runner \
   /home/robert/personal/eliot-test/src \
   /home/robert/personal/eliot-build/src \
   /home/robert/personal/eliot-build/test \
   -o /home/robert/personal/eliot-build/target
java -jar /home/robert/personal/eliot-build/target/Runner.jar   # runs the discovered tests
```

Argument ordering is strict (scopt): `-m <module>` must come **immediately after `exe-jar`**, before
the positional source roots (once positional roots are consumed the subcommand scope is lost and
`-m` errors as "Unknown option"). The output flag `-o <dir>` trails at the end. The module for `-m`
is **fully qualified** — `eliot.test.Runner`, not `Runner`.

Every source root that should contribute tests must be passed: the framework's `src`, this project's
`src`, and this project's `test`.

### The real-carrier check — there isn't one, and that is the standing gap

A green suite says nothing about whether the effectful modules have an interpretation **on the
platform**: `mocked` binds the doubles by name, so the platform's own `Process` and `FileSystem`
implementations are never resolved and a green run never touches them.

Two things used to check that and both are gone. `probe/` was deleted on 2026-09-04; its replacement,
`test/eliot/build/RealWorldTests.els`, was deleted by the v6 port (`76e50fb`) because it worked by
naming the jvm run boundary `runMain` to fix the carrier to `IO`, and v6 has no carrier and no such
value. A case that performs `Process` now simply propagates it to `eliot.test.Runner`, which caps at
`{Console}` by design — so a platform check has to be a program with a `main` of its own rather than a
test case. **Nobody has written that program.** `docs/effectful-modules.md` §10 records exactly what it
leaves unchecked; do not read a green 144 as evidence the tool runs.

### `eliot.paths` — LSP only

`eliot.paths` lists all source roots (this project's `src`/`test` plus the base/stdlib/jvm layer
roots, and the `compiler`-pool overlays). **Only the IntelliJ LSP reads it** — in the IDE, "Run main"
on `eliot.test.Runner` builds and runs with no arguments. The compiler CLI ignores `eliot.paths`
entirely and requires every root as an explicit path argument; the `examples.run` task above supplies
the layer roots, and you supply `src`/`test`. Keep `eliot.paths` in sync with the CLI invocation if
you change either.
