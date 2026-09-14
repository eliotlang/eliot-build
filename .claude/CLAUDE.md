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

Two source roots, five packages each. `src/eliot/build/` is the tool, split by what a file is allowed
to know — `assemble` → `resolve` → `git` → `format` → `model`, and `model` imports nothing of the tool
(`docs/effectful-modules.md` §12, §13, §15):

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
- **`resolve/`** — `PackageSource` (what the tool asks of somebody else's repository: a descriptor, a
  lineage anchor, and — since assembly — a checked-out tree), `GitPackages` (`gitPackages`, the
  named git-backed answer, which asks `{Dep[Path]}` for the cache root rather than knowing one),
  `Configuration` (`TestScope` or `ArtifactNamed`, which of a descriptor's scopes each opens, and
  `configurationNamed` — `Show`'s inverse, since the word a command line carries is the word that
  instance writes), `Selection` (a version chosen per repository, the canonical order, `sameLineage`),
  `Resolution` (MVS itself: the closure over rounds, the merge of two minimums, the depth ceiling, and
  the module set a selection carries — the selector narrows the closure as well as the mount).
- **`assemble/`** — `Assembly` (a resolution plus the standard layout become the source roots one
  configuration compiles from; pure but for `{PackageSource}`, and it names no git).

Above the five, two files at `src/eliot/build/` are the tool itself: **`Launcher`** — the one `main`,
the run boundary, the one place writing `with gitPackages with shellGit` and the `provide` that tells
the source where mirrors live, and where the four failure channels are discharged separately and
each reports as itself — and **`Command`**, the half that is about text rather than about running
(the `Request` sum a command line asks for, what a resolution and an assembly read as), split out
because it is testable with no platform beneath it and the boundary never can be. Two verbs:
`eliot resolve <configuration>` prints the version selected per package, `eliot roots <configuration>`
checks each out and prints the source directories that configuration compiles from — handed to the
compiler verbatim, those lines build the project. The lockfile, spawning the compiler (blocked on
published plugin assets — the descriptor's side of that is done, `plugin <asset> { backend <word> |
compiler }`) and the rest of the verb set are the steps after them.

Neither `Git` nor `PackageSource` has a default: the run boundary in `Launcher` writes
`with gitPackages with shellGit` once, and `ShellGit`/`GitPackages` are the two modules nothing but
that boundary imports. `test/` mirrors
the tree package for package, plus `git/TableGit` and `resolve/TablePackages` — named implementations of
this project's own two effects, which the framework cannot double. **Bind a named implementation with an
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
`docs/effectful-modules.md` — **read §10, §11, §12, §13 and §15 of it first**, and read them before touching `Git`,
`Cache`, `PackageSource` or a double. §1–§9 are a record of the carrier era and answer the two questions
the document exists for, but every mechanism they name (carriers, `Suspend`, capture tags, the four
rules) was deleted by effects v6; §10 says what replaced each one, §11 says what binding an
implementation actually does and what is now genuinely unchecked. §12, §13 and §15 are where the modules
came from and what was deliberately left whole.

A suite declares `def testCases: Test` — the framework's row alias for
`{Writer[List[TestResult]]} Unit`, which reaches this project now that a row alias is an ordinary name
resolved through import scope rather than matched by spelling within one file.

**That return type is the only thing deciding what a case may do.** A bare `Test` admits bodies that
assert and nothing else — a `printLine` in one is a compile error at the reference, verified. `in`
supplies `Throw[AssertionError]` per case and is transparent to everything else, so a case wanting
doubles writes `in mocked { … }` and they are bound by `mocked`'s own slot; a suite whose cases must
*really* perform composes the alias with a written-out row, `{Console} Test`. No suite here needs
that. There is no `pure` any more, no capture tag and no carrier.

## Committing

**Commit and push automatically** once a change builds and the suite is green — do not wait to be
asked. One commit per coherent change, with a message that says what the code now means and why, in
the style of the existing history.

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

### Running the tool

The tool has a `main`, and it is built the same way with its own module:

```bash
cd /home/robert/personal/eliot
./mill examples.run jvm exe-jar -m eliot.build.Launcher \
   /home/robert/personal/eliot-build/src \
   -o /home/robert/personal/eliot-build/target
cd <any project with an eliot.pkg>
java -jar /home/robert/personal/eliot-build/target/Launcher.jar resolve test
java -jar /home/robert/personal/eliot-build/target/Launcher.jar roots test
```

`roots` is the one that exercises the whole stack, and its output *is* the compiler's argument list.
The end-to-end check: run it in `../eliot-test` (delete `target/cache` first, so the clone and the
checkout are part of what is checked) and pass every line it prints to the compiler as a positional
source root. It cannot go through `examples.run`, which always appends the checkout's own layer roots
and would mount each layer twice — drive `Main` directly with that task's classpath instead:

```bash
cd /home/robert/personal/eliot-test
rm -rf target/cache
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

What that means for a change: **do not read a green 205 as evidence the tool runs** — the suite and the
launcher check different things, and a change to `Git`, `Cache`, `ShellGit`, `GitPackages`, `Assembly` or the
boundary is verified only when both have been run. Compiling the launcher is most of it (the platform
instances are resolved from its `main` or not at all); running it against a real repository is the
rest.

Two build gotchas recorded in §11.3: a rename that fails at `Git.els:1:1: Could not find '…'` with
correct sources is the stale incremental cache — delete `target/.eliot-index-*` and
`target/.eliot-objects-*`; and two `provide`s over one `Dep` type whose results are both `Option[_]`
get one native between them and the other dies at run time with `NoSuchMethodError`, so the suites
render inside every `provide`.

### `eliot.paths` — LSP only

`eliot.paths` lists all source roots (this project's `src`/`test` plus the base/stdlib/jvm layer
roots, and the `compiler`-pool overlays). **Only the IntelliJ LSP reads it** — in the IDE, "Run main"
on `eliot.test.Runner` builds and runs with no arguments. The compiler CLI ignores `eliot.paths`
entirely and requires every root as an explicit path argument; the `examples.run` task above supplies
the layer roots, and you supply `src`/`test`. Keep `eliot.paths` in sync with the CLI invocation if
you change either.
