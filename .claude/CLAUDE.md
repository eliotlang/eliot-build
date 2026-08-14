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

Four source roots. `src/` is the tool: `Clause`/`Descriptor` (the `eliot.pkg` format), `Version` and
`PackageId` (identity and ordering), `Git` and `Cache` (talking to git and mirroring repositories),
`PackageSource` (the resolver's two questions plus the git-backed answer), `Resolution` (MVS).
`test/` mirrors it, plus two fixtures that are not suites — `FakeWorld` and `TablePackages`, the pure
carriers effectful code is tested on. `it/` is the integration project: real git, real filesystem, real
assertions (see below). `probe/` is a `main` that runs the effectful modules against a real *remote*
repository; it asserts nothing and wants a network.

The design is `docs/build-system.md`; how the effectful modules are shaped and tested is
`docs/effectful-modules.md`. Read the latter before touching `Git`, `Cache`, `PackageSource` or a
fixture — it carries four rules that are each a compile error to break.

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

### `it/` — the integration project

The unit suite runs effectful modules on a pure carrier, which resolves `Process[Fake]` and never
`Process[IO]`, and asserts against a journal of commands that were never run. `it/` runs them for real:
it builds two git repositories under `target/it/fixtures`, clones them through `Cache`, and asserts on
what git actually answered — where the mirror landed on a real filesystem, that a second visit does not
re-clone, which commit an annotated tag peels to, and that `git show` at an untagged revision is read as
absence rather than raised.

It is a separate project, not more suites: it declares its cases under `integrationCases` rather than
`testCases`, so the fast run cannot pick them up and no exclusion list has to be maintained. Its own runner
takes **both** lists and prints one report — the pure suites by reflection, the integration ones named
explicitly in `IntegrationRunner` (a suite type carrying `Process`/`FileSystem` is an open row, and
`namedValues` over one does not resolve, so each new integration suite costs a line there):

```bash
./mill examples.run jvm exe-jar -m eliot.build.IntegrationRunner \
   /home/robert/personal/eliot-test/src \
   /home/robert/personal/eliot-build/src \
   /home/robert/personal/eliot-build/test \
   /home/robert/personal/eliot-build/it \
   -o /home/robert/personal/eliot-build/target
./it/run.sh          # from the repository root; wraps the jar, wants a git on the path, no network
```

`it/run.sh` is load-bearing, not convenience. `Git.transportUrl` prepends `https://` to every dependency
URL, so a cold clone always asks git for `https://github.com/x/foo`; the script writes a `GIT_CONFIG_GLOBAL`
using git's own `url.<base>.insteadOf` to point that at the fixtures. The clone path is therefore exercised
for real, offline, with nothing in `src/` knowing. It has to come from outside the program because
`eliot.system.Process` sets no child environment and `Environment` only reads.

Cases in a suite **share one world, in order** — the first builds the fixtures, the second clones cold, the
third depends on the second having cloned. That is what makes "did not clone twice" observable: `git clone`
into a directory that already holds a repository fails, so a second visit that answers at all took the
mirror as proof.

Nothing exits non-zero on failure — the stdlib has no `exit` — so CI must read the summary line. That is
equally true of the plain `Runner.jar`.

### The probe — the networked check

`it/` is hermetic and says nothing about real remotes. `probe/` still exists for that, and remains the only
thing that reaches `Resolution` through the git-backed `PackageSource`: an ability method's effect
propagates to its caller, and a case body's row is fixed by `in`, so `{PackageSource}` cannot be declared
there. Build and run it after changing anything effectful:

```bash
./mill examples.run jvm exe-jar -m eliot.build.Probe \
   /home/robert/personal/eliot-build/src \
   /home/robert/personal/eliot-build/probe \
   -o /home/robert/personal/eliot-build/target
java -jar target/Probe.jar github.com/some/repository    # wants a network and a git on the path
```

It asserts nothing and it clones for real. Keep it reaching every effectful module.

### `eliot.paths` — LSP only

`eliot.paths` lists all source roots (this project's `src`/`test` plus the base/stdlib/jvm layer
roots, and the `compiler`-pool overlays). **Only the IntelliJ LSP reads it** — in the IDE, "Run main"
on `eliot.test.Runner` builds and runs with no arguments. The compiler CLI ignores `eliot.paths`
entirely and requires every root as an explicit path argument; the `examples.run` task above supplies
the layer roots, and you supply `src`/`test`. Keep `eliot.paths` in sync with the CLI invocation if
you change either.
