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

Two source roots, four packages each. `src/eliot/build/` is the tool, split by what a file is allowed
to know — `resolve` → `git` → `format` → `model`, and `model` imports nothing of the tool
(`docs/effectful-modules.md` §12):

- **`model/`** — the vocabulary, no syntax and no effects. `Version` (with `Line`, the compatibility
  line, and `firstRelease`), `PackageId` (`Repository` is what is cloned, cached and selected; `Package`
  adds the module wanted; the `PackageId` sum is what a `dep` line spells, `Sibling` or `Foreign`, never
  an empty-URL sentinel), and `Descriptor` — the typed `eliot.pkg` model as data alone, where a
  `Dependency` is a `SiblingDependency` or a `Requirement` with a mandatory minimum.
- **`format/`** — the `eliot.pkg` file. `Clause` is the generic clause tree and its parser; `PackageFile`
  interprets one into a `Descriptor`, writes one back out, owns `DescriptorError` and
  `descriptorFileName`, and is the only place that knows the vocabulary. The minimum on a requirement is
  checked here, at parse time.
- **`git/`** — `Git` (`effect Git` — five operations over `Remote`, `Mirror`, `Commit` and `Revision`,
  git's own vocabulary; a mirror is a bare `--mirror` clone and nothing is ever checked out — plus the
  pure reading of git's output), `ShellGit` (`shellGit`, the *named* implementation that spawns and alone
  decides which directory each command stands in; the only module naming `eliot.system.Process`), and
  `Cache` (mirroring repositories, on `{Git, FileSystem}`).
- **`resolve/`** — `PackageSource` (the resolver's two questions), `GitPackages` (`gitPackages`, the
  named git-backed answer), `Resolution` (MVS over a `Configuration`: `TestScope` or `ArtifactNamed`).

Neither `Git` nor `PackageSource` has a default: a run boundary writes `with gitPackages with shellGit`
once, and `ShellGit`/`GitPackages` are the two modules nothing but that boundary imports. `test/` mirrors
the tree package for package, plus `git/TableGit` and `resolve/TablePackages` — named implementations of
this project's own two effects, which the framework cannot double. **Bind a named implementation with an
expression `with` inside `mocked`'s body, never on a slot's type**: a slot's `with` binds the
implementation's own clause effects to the platform's real ones (`docs/effectful-modules.md` §11.2).
Everything else is mocked by `eliot.test.Mock`: a case declares nothing, arranges with
`whenSpawning`/`withDirectory`/…, acts, and verifies with `wasCalledOnce`/`calls`/…
(`eliot-test/docs/mocking.md`). `FakeWorld` — 195 lines of hand-written doubles — was deleted when that
landed. (`probe/` was deleted on 2026-09-04; `docs/effectful-modules.md` §9.6 says what that leaves
unchecked.)

The design is `docs/build-system.md`; how the effectful modules are shaped and tested is
`docs/effectful-modules.md` — **read §10, §11 and §12 of it first**, and read them before touching `Git`,
`Cache`, `PackageSource` or a double. §1–§9 are a record of the carrier era and answer the two questions
the document exists for, but every mechanism they name (carriers, `Suspend`, capture tags, the four
rules) was deleted by effects v6; §10 says what replaced each one, §11 says what binding an
implementation actually does and what is now genuinely unchecked.

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

### The real-carrier check — there isn't one, and that is the standing gap

A green suite says nothing about whether the effectful modules have an interpretation **on the
platform**: `mocked` binds the doubles by name, `shellGit` is only ever bound under it, so the
platform's own `Process` and `FileSystem` implementations are never resolved and a green run never
touches them. (The git-backed `PackageSource` *is* typechecked and tested now, over `tableGit` —
that half of the gap closed on 2026-09-12.)

Two things used to check that and both are gone. `probe/` was deleted on 2026-09-04; its replacement,
`test/eliot/build/RealWorldTests.els`, was deleted by the v6 port (`76e50fb`) because it worked by
naming the jvm run boundary `runMain` to fix the carrier to `IO`, and v6 has no carrier and no such
value. A case that performs `Process` now simply propagates it to `eliot.test.Runner`, which caps at
`{Console}` by design — so a platform check has to be a program with a `main` of its own rather than a
test case. **Nobody has written that program.** `docs/effectful-modules.md` §11.4 records exactly what
it leaves unchecked; do not read a green 159 as evidence the tool runs.

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
