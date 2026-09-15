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

Two source roots, six packages each. `src/eliot/build/` is the tool, split by what a file is allowed
to know — `assemble` → `resolve` → `assets` → `git` → `format` → `model`, and `model` imports nothing of
the tool (`docs/effectful-modules.md` §12, §13, §15, §17):

- **`model/`** — the vocabulary, no syntax and no effects. `Version` (with `Line`, the compatibility
  line, and `firstRelease`), `PackageId` (`Repository` is what is cloned, cached and selected; a
  `ModuleSelector` is `RootModule` or `ModuleSelected`, never an `Option[ModuleName]`; `Package` is the
  two together; the `PackageId` sum is what a `dep` line spells, `Sibling` or `Foreign`, never an
  empty-URL sentinel), `Lineage` (`Commit` and `sameAnchor` — a content hash is vocabulary before it
  is git's, which is why the resolver imports no git at all), and `Descriptor` — the typed `eliot.pkg`
  model as data alone, where a `Dependency` is a `SiblingDependency` or a `Requirement` with a
  mandatory minimum.
- **`format/`** — the `eliot.pkg` file. `Clause` is the generic clause tree and its parser
  (`clausesNamed` asks of a file what `childrenNamed` asks of a block, which is why the root is
  interpreted exactly as every block in it is); `ClauseReader` is the checked access to one clause and
  the `ClauseProblem` it complains with; `DependencyClause` is the `dep` line, the one clause every
  block reads; `PackageFile` owns the keywords, `DescriptorError` and `descriptorFileName`, and is where
  the parser's and the reader's error channels meet; `DescriptorWriter` writes a descriptor back out and
  imports `model` alone.
- **`git/`** — `Git` (`effect Git` — six operations over `Remote`, `Mirror`, `Worktree` and `Revision`,
  git's own vocabulary; a mirror is a bare `--mirror` clone, every *question* is answered from its object
  database, and the one thing ever checked out is a worktree, because a compiler mounts
  directories), `Tags` (`TagRef` and
  the pure reading of a `ls-remote` listing — `Git` imports it, never the other way round), `ShellGit`
  (`shellGit`, the *named* implementation that spawns and alone decides which directory each command
  stands in; the only module naming `eliot.system.Process`), and `Cache` (mirroring repositories and
  checking versions out beside them at `<url>@<tag>`, on `{Git, FileSystem}`).
- **`assets/`** — the other half of what a `dep` line buys. `Assets` (`effect Assets` — one question,
  `assetTree(asset)`, plus `Asset` itself, the repository/version/name triple a release asset *is*, and
  `assetUrlOf`, the one concatenation its location is derived by) and `ShellAssets` (`shellAssets`, the
  named implementation that spawns `curl`, falls back to `wget` where curl will not start, unpacks with
  `unzip`, and caches the result at `<root>/assets/<url>@<tag>/<asset>`). It imports `git` for one thing
  — `remoteOf`, the single place the scheme is decided — and knows nothing about resolutions.
- **`resolve/`** — `PackageSource` (what the tool asks of somebody else's repository: a descriptor, a
  lineage anchor, and — since assembly — a checked-out tree), `GitPackages` (`gitPackages`, the
  named git-backed answer, which asks `{Dep[Path]}` for the cache root rather than knowing one),
  `Configuration` (`TestScope` or `ArtifactNamed`, which of a descriptor's scopes each opens, and
  `configurationNamed` — `Show`'s inverse, since the word a command line carries is the word that
  instance writes), `Selection` (a version chosen per repository, the canonical order, `sameLineage`),
  `Resolution` (MVS itself: the closure over rounds, the merge of two minimums, the depth ceiling, and
  the module set a selection carries — the selector narrows the closure as well as the mount).
- **`assemble/`** — `Assembly` (a resolution plus the standard layout become the source roots one
  configuration compiles from; pure but for `{PackageSource}`, and it names no git) and `Toolchain`
  (the same closure read the other way: which asset is marked `compiler`, which word the backend
  answers to, and every asset the mounted modules ship — `ToolchainError` is where two packages
  claiming the marker is caught, because a descriptor reader sees one descriptor and the conflict only
  exists across a resolution).

Above the six, two files at `src/eliot/build/` are the tool itself: **`Launcher`** — the one `main`,
the run boundary, the one place writing `with gitPackages with shellGit with shellAssets` and the
`provide` that tells
the source where mirrors live, and where the six failure channels are discharged separately, each
reporting as itself and every one of them registering a non-zero exit code — and **`Command`**, the
half that is about text rather than about running
(the `Request` sum a command line asks for, what a resolution and an assembly read as), split out
because it is testable with no platform beneath it and the boundary never can be. Three verbs:
`eliot resolve <configuration>` prints the version selected per package, `eliot roots <configuration>`
checks each out and prints the source directories that configuration compiles from, and `eliot build
<configuration>` fetches the plugin assets those same versions ship and runs the compiler over those
same roots — inheriting its streams and registering its exit code. The lockfile and the rest of the
verb set are the steps after them.

Neither `Git`, `Assets` nor `PackageSource` has a default: the run boundary in `Launcher` writes
`with gitPackages with shellGit with shellAssets` once, and `ShellGit`/`GitPackages`/`ShellAssets` are
the three modules nothing but that boundary imports. `test/` mirrors
the tree package for package, plus `git/TableGit` and `resolve/TablePackages` — named implementations of
this project's own effects, which the framework cannot double (`Assets` needs none: `Toolchain` names
assets without fetching any, and `ShellAssets` is checked under `mocked` like `ShellGit`). **Bind a named implementation with an
expression `with` inside `mocked`'s body, never on a slot's type**: a slot's `with` binds the
implementation's own clause effects to the platform's real ones (`docs/effectful-modules.md` §11.2).
Everything else is mocked by `eliot.test.Mock`: a case declares nothing, arranges with
`whenSpawning`/`withDirectory`/…, acts, and verifies with `wasCalledOnce`/`calls`/…
(`eliot-test/docs/mocking.md`). Both suites that resolve render *inside* the `against`, and must: two
`provide[Universe, _]` instantiations whose erased JVM descriptors agree get one native between them
(§11.3), which a second resolving suite walks straight into. `FakeWorld` — 195 lines of hand-written
doubles — was deleted when that landed. (`probe/` was deleted on 2026-09-04; `docs/effectful-modules.md` §9.6 says what that leaves
unchecked.)

The design is `docs/build-system.md`; how the effectful modules are shaped and tested is
`docs/effectful-modules.md` — **read §10, §11, §12, §13, §15, §16 and §17 of it first**, and read them
before touching `Git`, `Assets`, `Cache`, `PackageSource` or a double. §1–§9 are a record of the carrier era and answer the two questions
the document exists for, but every mechanism they name (carriers, `Suspend`, capture tags, the four
rules) was deleted by effects v6; §10 says what replaced each one, §11 says what binding an
implementation actually does and what is now genuinely unchecked. §12, §13 and §15 are where the modules
came from and what was deliberately left whole; §16 is what the packages under them cost to revise, what
`eliotw` is allowed to know, and two findings recorded rather than fixed. §17 is the verb that
compiles: the sixth package, the toolchain read off a closure, and the three compiler workarounds the
build verb cost — one of which is why §16's "a failed build exits 0" is now closed.

A suite declares `def testCases: Test` — the framework's row alias for
`{Writer[List[TestResult]]} Unit`, which reaches this project now that a row alias is an ordinary name
resolved through import scope rather than matched by spelling within one file.

**That return type is the only thing deciding what a case may do.** A bare `Test` admits bodies that
assert and nothing else — a `printLine` in one is a compile error at the reference, verified. `in`
supplies `Throw[AssertionError]` per case and is transparent to everything else, so a case wanting
doubles writes `in mocked { … }` and they are bound by `mocked`'s own slot; a suite whose cases must
*really* perform composes the alias with a written-out row, `{Console} Test`. No suite here needs
that. There is no `pure` any more, no capture tag and no carrier.

## Releasing

A major version is a branch, a release is an **annotated** tag on it; the line is `v0`. To publish:
fast-forward `v0` to the commit, `git tag -a v0.<n>` on it, push both. `.github/workflows/release.yml`
then runs the suite through `./eliotw build test`, builds the jar with `./eliotw build launcher` and
attaches it as `eliot-launcher.jar` with its sha256 in the notes — so each release is built by the
launcher the *previous* release published, which is what `.eliot-version` pins. `v0.1` is the one
exception and had to be: it was built by the working tree that became it, because nothing before it
could build anything.

Bump `.eliot-version` to the new tag on `master` after publishing. A published asset is never replaced —
a mistake is a new tag.

## Committing

**Commit and push automatically** once a change builds and the suite is green — do not wait to be
asked. One commit per coherent change, with a message that says what the code now means and why, in
the style of the existing history.

## Building and running (compiler CLI)

**The build dogfoods now.** `java -jar target/Launcher.jar build launcher` in this repository fetches
eliot `v0.2`'s three plugin assets and produces the launcher jar, and that jar builds this project's own
suite — 239 green, no mill and no compiler checkout involved. The compiler CLI below is still how a
change to the *compiler* is picked up, and still the faster loop while iterating, but it is no longer
the only way this repository can be built. Compilation is driven by a sibling checkout of the Eliot
compiler (`/home/robert/personal/eliot`), whose `examples.run`
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

### Running the tool

There are two ways in. `./eliotw <verb> <configuration>` is the user's: the committed wrapper reads
`.eliot-version`, fetches that launcher release into `~/.cache/eliot/launcher/<tag>/` once and execs
it, so it needs no compiler checkout and no mill. As of `v0.1` that launcher has `build`, so
`./eliotw build test` in a checkout holding nothing but the wrapper is a working build of this project
— verified from an empty cache, 239 green. It still runs the *published* launcher and never your
working tree, which is what makes it the wrong tool for checking a change to the tool itself. `ELIOT_LAUNCHER_REPOSITORY` points
it at a mirror (a `file://` directory laid out as `releases/download/<tag>/eliot-launcher.jar` works,
which is how the wrapper is tested without publishing) and `ELIOT_CACHE` moves the cache.

The second is the platform check, and it is the one a change is verified with. The tool has a `main`,
and it is built the same way as the suite with its own module:

```bash
cd /home/robert/personal/eliot
./mill examples.run jvm exe-jar -m eliot.build.Launcher \
   /home/robert/personal/eliot-build/src \
   -o /home/robert/personal/eliot-build/target
cd <any project with an eliot.pkg>
java -jar /home/robert/personal/eliot-build/target/Launcher.jar resolve test
java -jar /home/robert/personal/eliot-build/target/Launcher.jar roots test
java -jar /home/robert/personal/eliot-build/target/Launcher.jar build test
```

`build` is the one that exercises the whole stack, and it is the end-to-end check now that it exists:
it resolves, checks out, fetches every plugin asset the selected versions ship, and runs the compiler
over the roots itself. The strongest form of it is this repository building itself — `build launcher`
then running the jar that came out — and the broader form is another project, with `target/` deleted
first so the clone, the checkout and the download are all part of what is checked:

```bash
cd /home/robert/personal/eliot-test
rm -rf target
java -jar /home/robert/personal/eliot-build/target/Launcher.jar build test   # must exit 0
java -jar target/Runner.jar                                                 # must be green
```

A package's `eliot.pkg` must require eliot at `v0.1` or later for this to work at all — `v0.0` declares
no `plugin` clauses, so there is no toolchain to find and `build` refuses with "nothing 'test' depends
on ships a compiler". This repository requires `v0.2`, which is where `registerExitCode` arrives, and
`../eliot-test` requires `v0.1`. Two things to check while you are there: a deliberate syntax error in any
mounted source must make `build` exit 1 with the compiler's own diagnostics on the terminal, and
`build nosuch` must exit 1 rather than printing a failure and exiting 0.

The older half of the check still works and is what to fall back on when `build` itself is what is
suspect: `roots` prints the compiler's argument list, and passing those lines to `Main` by hand builds
the same jar. It cannot go through `examples.run`, which always appends the checkout's own layer roots
and would mount each layer twice — drive `Main` directly with that task's classpath instead:

```bash
ROOTS=$(java -jar /home/robert/personal/eliot-build/target/Launcher.jar roots test)
CP=$(cd /home/robert/personal/eliot && ./mill show examples.runClasspath | python3 -c \
   'import sys,json,re; print(":".join(re.sub(r"^.*?@","",x) for x in json.load(sys.stdin)))')
java -cp "$CP" com.vanillasource.eliot.eliotc.compiler.Main jvm exe-jar -m eliot.test.Runner \
   $ROOTS -o /tmp/roots-check
java -jar /tmp/roots-check/Runner.jar    # must be green
```

Note the source roots: the launcher needs `src` alone (no framework, no `test`).

### The platform check — it exists now, and it is the launcher

A green suite still says nothing about whether the effectful modules have an interpretation **on the
platform**: `mocked` binds the doubles by name and `shellGit` is only ever bound under it, so a suite
never resolves the platform's own `Process` and `FileSystem`. `eliot.test.Runner` cannot close that —
it caps at `{Console}` by design, so a case that performs `Process` does not typecheck — which is why
the check has to be a program with a `main` of its own. `probe/` was that program until 2026-09-04 and
`RealWorldTests.els` until the v6 port; **`eliot.build.Launcher` is that program now** (2026-09-13,
`docs/effectful-modules.md` §14).

What that means for a change: **do not read a green 237 as evidence the tool runs** — the suite and the
launcher check different things, and a change to `Git`, `Cache`, `ShellGit`, `GitPackages`, `ShellAssets`, `Assembly`, `Toolchain` or
the boundary is verified only when both have been run. Compiling the launcher is most of it (the platform
instances are resolved from its `main` or not at all); running it against a real repository is the
rest.

Two build gotchas recorded in §11.3: a rename that fails at `Git.els:1:1: Could not find '…'` with
correct sources is the stale incremental cache — delete `target/.eliot-index-*` and
`target/.eliot-objects-*`; and two `provide`s over one `Dep` type whose results are both `Option[_]`
get one native between them and the other dies at run time with `NoSuchMethodError`, so the suites
render inside every `provide`.

### `eliot.paths` is gone

It was the stopgap for exactly one thing — telling the IntelliJ LSP where every source root is, in a
world with no build tool to ask. There is one now: `./eliotw roots test` prints the same list, derived
from `eliot.pkg` rather than maintained by hand beside it, and a file that has to be kept in sync with
something that can be computed is a file that is eventually wrong.

The LSP has not learned to ask yet, so until it does it falls back to guessing roots and will not find
the layers. Regenerating the stopgap is one line if the IDE needs it meanwhile:

```bash
./eliotw roots test | sed 's/^/runtime /' > eliot.paths
```

That loses the `compiler` overlay directive, which `eliot roots` deliberately does not print: the
compile-time overlay is each source root's own sibling and the compiler derives it, so listing it is a
second place for the two to disagree. `docs/build-system.md` ("IDE integration") is where the query that
replaces all of this is designed.
