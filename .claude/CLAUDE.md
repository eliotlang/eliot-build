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
`test/` mirrors it, plus `TablePackages` — a carrier of our own for `PackageSource`, which is *this
project's* ability and so cannot be doubled by the framework. Everything else is mocked by
`eliot.test.Mock`: a case declares nothing, arranges with `whenSpawning`/`withDirectory`/…, acts, and
verifies with `wasCalledOnce`/`calls`/… (`eliot-test/docs/mocking.md`). `FakeWorld` — 195 lines of
hand-written doubles — was deleted when that landed. (`probe/` was deleted on 2026-09-04; `docs/effectful-modules.md`
§9.6 says what that leaves unchecked.)

The design is `docs/build-system.md`; how the effectful modules are shaped and tested is
`docs/effectful-modules.md` — **read §9 of it first**, and read it before touching `Git`, `Cache`,
`PackageSource` or a fixture. It carries four rules, three of which are still a compile error to
break; the fourth (run-then-assert) is retired.

A suite declares its own effect row — `def testCases: {Writer[List[TestResult]]} Unit` — because the
framework's `type Test` alias is gone (an alias may not carry an open row). A faked run goes in a
capture slot (`{| Fake}`), so it is written inline in a `pure` body rather than in a definition of its
own.

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

### The real-carrier check — two ordinary tests, no entry point of our own

A green faked suite says nothing about whether the code compiles in production: tests run effectful
modules on a pure carrier, which resolves `Process[Fake]` and never `Process[IO]`. `probe/` used to be
the `main` that resolved the real instances; `test/eliot/build/RealWorldTests.els` is now, with the
`catch`es next door in `RealWorld.els` (a module that does not assert, because naming `IoError` and
asserting cannot happen in one file — `docs/effectful-modules.md` §9.5).

**Nothing about it touches the framework.** A test names the platform carrier the same way it names a
fake one: `runMain(...)` — the jvm layer's run boundary, `def runMain[A](io: IO[A]): A` in
`eliot.jvm.IO` — fixes the carrier to `IO`, so the effect is performed and charged *there*. The case is
written `in pure` and the suite declares `{Writer[List[TestResult]]}` like every other. A suite's row
never grows, so `eliot.test.Runner` never needs widening, for this effect or any future one (§9.6).
Importing `eliot.jvm.IO` does pin that file to the jvm platform — correct for a test about the
platform's own instances. Keep those cases reaching every effectful module.

### `eliot.paths` — LSP only

`eliot.paths` lists all source roots (this project's `src`/`test` plus the base/stdlib/jvm layer
roots, and the `compiler`-pool overlays). **Only the IntelliJ LSP reads it** — in the IDE, "Run main"
on `eliot.test.Runner` builds and runs with no arguments. The compiler CLI ignores `eliot.paths`
entirely and requires every root as an explicit path argument; the `examples.run` task above supplies
the layer roots, and you supply `src`/`test`. Keep `eliot.paths` in sync with the CLI invocation if
you change either.
