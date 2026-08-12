# Modules That Do Things: Retiring the Pure/Effectful Split

Status: **DONE**, 2026-08-12. Built against the compiler at `robertbraeutigam/eliot@f7a546b` and the
framework at `eliotlang/eliot-test@d136e0f`. The suite went from 124 cases to 141, and the seventeen
new ones are about code that could not previously be tested at all.

## 1. The constraint that shaped these modules is gone

`docs/build-system.md` used to record this as the single most load-bearing lesson of building the
tool:

> **The pure/effectful boundary is imposed, not chosen.** A test case body is pinned to
> `{Throw[AssertionError] | Id}` and may only assert, so *nothing effectful is reachable from the
> test suite* — not "hard to test", unreachable. Every module that touches the outside therefore
> splits in two: all the decisions on the pure side where tests can reach them, and a shell next door
> thin enough to trust unexamined.

The premise was true and the conclusion followed from it at the time. Both halves have since been
fixed in the compiler, recorded in the eliot repository's `docs/testing-effects.md` (status:
*adopted, done*):

- **L1 — constraint-aware declination.** `implement[F[_] ~ Suspend & …] Process[F]` in the jvm layer
  used to match *every* carrier structurally, so a test's own `Process[Fake]` was a second candidate
  and the query was ambiguous. Candidate selection now consults `~` constraints and declines a
  candidate whose constraints have no implementation at the matched bindings. A pure carrier has no
  `Suspend`, so the jvm instance declines and the fake is the unique survivor. This is what extends
  fake carriers from application-owned abilities to `Console`, `Log`, `FileSystem`, `Process` and
  `Environment` — the effects this tool is written in.
- **L2 — the row verifier no longer charges a harness for the effect it faked.** A definition that
  runs carrier-generic code at a foreign concrete carrier may now return whatever it likes, including
  the plain `String` an assertion wants.

So a `{Process, FileSystem}` module is reachable from the test suite *as it is*. The split into "`Git`
decides, `Cache` performs" was a workaround for a limitation that no longer exists, and it had begun
to cost what workarounds cost: the module with the behaviour had no tests, and the module with the
tests had no behaviour.

## 2. Where the anaemia was

| Module | Verdict | What was wrong |
|---|---|---|
| `Git` | **anaemic** | Four of its eight exported functions answered a command line as `List[String]`, for somebody else to run; the rest read strings git had already written. It knew how to *say* things to git and never said them. |
| `Cache` | **the mirror image** | It held every real decision — when to clone, which working directory a command needs, when a non-zero exit is data and when it is a failure — and it was the one module with no tests, because it could not have any. |
| `Resolution` | **distorted, not anaemic** | The algorithm was all there, but its source arrived as two callbacks threaded verbatim through nine private functions — 22 parameter declarations of plumbing. Its own doc comment said an `ability` had been tried first and rejected *only* because nothing could discharge it. |
| `Descriptor`, `Clause`, `Version`, `PackageId` | **healthy** | Genuinely pure subject matter — parsing, ordering, canonical form. Nothing was being withheld from them, and nothing about them changed. |
| `Probe` | **keeps its job** | See §6: fake carriers do not replace it, and it now reaches further than it did. |

The concrete shape of the old `Git`/`Cache` split: `lsRemoteTagsCommand(target)` answered
`["git", "ls-remote", "--tags", target]`, and `Cache.publishedTags` ran it, checked the exit code,
raised `GitError`, and handed the output back to `Git.parseTagRefs`. One operation, split across two
modules and a `ProcessResult`, so that half of it could be tested. `GitTests` accordingly asserted
things like

```eliot
lsRemoteTagsCommand("github.com/x/foo").joined(" ") shouldBe "git ls-remote --tags github.com/x/foo"
```

which pinned the *spelling* of a command nobody in the test had run. It could not catch the one class
of bug this code has actually had — the relative-path bug recorded in `build-system.md`, where a clone
launched from the wrong working directory buried the mirror at `target/cache/target/cache/…`. The
working directory is not part of a command line, so no assertion about a command line can see it. It
is now asserted directly, in `CacheTests`, because the journal a test carrier keeps records where each
command ran as well as what it was.

## 3. The four rules

A test declares its own carrier — an ordinary `data` with an `Effect` instance and, for each effect in
the row, an instance of that effect for the carrier. Production code is untouched, because a
`{Process, FileSystem}` signature names no carrier and therefore commits to no interpretation of it.
Instantiating that code at the test's carrier and running it yields a plain value to assert on. Four
rules govern it, and all four were established by breaking them (§7).

1. **The carrier implements the row flat, itself — including each failure channel.** For
   `{Process, FileSystem, Throw[IoError], Throw[GitError]}` the fake needs five instances. Discharging
   the `Throw`s with the real `runThrow` over the fake as a base is not an alternative:
   `Process[ThrowCarrier[E, Fake]]` would need a lift of the fake's `Process` through `ThrowCarrier`,
   the real effects get theirs for free by riding `Suspend`, and writing one by hand is an orphan
   instance (neither `Process`'s module nor `ThrowCarrier`'s is ours). So the fake owns the whole row
   and reflects a raise into its own result slot.
2. **Run-then-assert.** The run must sit in a definition with no ambient carrier of its own. Inside a
   test body pinned to `{Throw[AssertionError] | Id}` the ambient carrier *is* that pinned stack, and
   every carrier-generic callee is written at it, so a run written there fails with
   `Expected: {Throw[AssertionError] | Id} Fake[String]` / `Actual: … String`. In practice: one
   private `def` per scenario computing a `String`, and a body that only compares it. This is a real
   constraint, not a style choice — a test cannot assert part-way through a faked run.
3. **One fake per seam, each implementing the minimum.** A production instance written as a
   constrained catch-all (the only placement the orphan rule allows for an instance over an arbitrary
   carrier) matches any fake that happens to satisfy those constraints. A *wide* fake that also fakes
   `Process` and `FileSystem` therefore collides with it: `Multiple ability implementations found for
   ability 'PackageSource' with type arguments [Fake]`. Hence two carriers rather than one —
   `FakeWorld` for the modules that spawn, `TablePackages` for the resolver, which wants descriptors
   and not a fake git anyway.
4. **The fake cannot cheat.** It has no `Suspend` instance and `Suspend` is the only route to a native
   side effect, so a test carrier is *structurally* incapable of touching a real process or a real
   file. An accidental `printLine` in tested code is a compile error, not a silent test that does I/O.

One convenience the shape depends on: `ProcessResult`, `IoError` and `Path` are abstract in the base
layer but concrete `data` in the jvm layer, and the test binary mounts jvm — so a fake constructs
`ProcessResult(128, "", "no such repository")` and a real `Path` with no test-only machinery.

## 4. What the modules are now

### 4.1 `Git` speaks git

Command construction and output parsing are private; the operations are the module's surface. The
working directory each command needs is part of the signature, which is what turns git's own rule — *a
command that names a repository by path runs where this program runs; one that operates on the
repository it stands in runs in the mirror* — from a comment into something a caller cannot get
silently wrong.

```eliot
def lsRemoteTags(target: String, from: Path): {Process, Throw[GitError]} List[TagRef]
def mirrorClone(source: String, target: String, from: Path): {Process, Throw[GitError]} Unit
def fetchTags(mirror: Path): {Process, Throw[GitError]} Unit
def showFile(revision: String, file: String, mirror: Path): {Process} Option[String]
```

`GitError` and its `Show` moved here from `Cache` — it is git's error, raised by the module that ran
git. `showFile` keeps `Option` and declares no `Throw`: a missing revision or a missing file is an
ordinary answer, and it is the one place a non-zero exit is read rather than raised, which the
signature now says out loud. `parseTagRefs`, `commitOf` and `anchorCommit` stay exported and stay
pure — reading a listing is a real question with real edge cases (annotated tags listed twice, peeled
entries, non-version tags) and its nine tests are good tests, unchanged.

### 4.2 `Cache` decides where mirrors live

`checked`, `run`, `failureOf`, `outputWhenFound` and the `ProcessResult` handling are gone; what
remains is cache policy — `cacheDirectory`, `ensuredMirror`, `refreshed`, `publishedTags`,
`anchorOf`, `descriptorTextAt` — expressed in `Git`'s operations. The module keeps its row and both
failure channels and has twelve tests where it had none.

### 4.3 `Resolution` runs on a source effect

```eliot
ability PackageSource[F[_]] {
   def descriptorAt(version: Version, target: PackageId): {PackageSource} Option[Descriptor]
   def anchorAt(majorLine: Int, target: PackageId): {PackageSource} Option[String]
}
```

in its own module, which also carries the git-backed catch-all instance — the ability's module being
the only legal home for an instance over an arbitrary carrier, which is why the git-backed source
lives there rather than beside the cache it uses. Every callback parameter is gone from `Resolution`'s
eleven functions and its rows read `{PackageSource, Throw[ResolutionError]}`. The 23 resolver tests
are unchanged apart from their fixture: the same `publishing(…)/published(…)` tables now seed a
carrier instead of two lambdas.

One thing the ability could not have: a cache root. The methods carry what the *resolver* knows — a
package and a version — and `Dep` cannot ride the same carrier stack as `Throw`, the cross-lift matrix
being partial and that pair one of the holes. So `packageCacheRoot` is a constant in the
`PackageSource` module, documented as the launcher's to own once the launcher exists; `Cache` itself
takes its root as a parameter and is indifferent.

## 5. What was done

Five steps, each green on its own.

- **Step 0 — make the tree build again.** The compiler now enforces public-before-private declaration
  order within a file, and `Descriptor.els` and `Resolution.els` each declared a `data` after their
  first `private def`. Three declarations moved; 124 tests green.
- **Step 1 — `test/eliot/build/FakeWorld.els`.** The world (directories, journal, canned replies), the
  carrier, its five instances, and the two runners every effectful suite uses (`journalOf`,
  `outcomeOf`). Not a suite — the fixture the suites share.
- **Step 2 — `Git` absorbed the spawning and `Cache` reduced to policy.** `GitTests`' command-line
  assertions did not disappear, they relocated: what was `lsRemoteTagsCommand(…).joined(" ")` is now
  an assertion about the journal of what the program actually ran, working directory included.
- **Step 3 — `CacheTests`, the file that could not exist.** Clone-on-first-visit,
  no-clone-on-second, fetch running *in* the mirror while clone runs in `.`, a non-zero `ls-remote`
  raising a `GitError` that carries the command line and the diagnostics, a non-zero `git show`
  answering absent instead of raising.
- **Step 4 — `PackageSource`.** The ability, the git-backed instance, `Resolution` rewritten without
  the callbacks, `test/eliot/build/TablePackages.els` as the resolver's narrow carrier, and `probe/`
  extended to reach the whole path at the real carrier.

## 6. What this does not replace

Instantiating production code at a fake carrier resolves `Process[Fake]` — **not** `Process[IO]`.
Ability resolution happens at monomorphization, so a module reachable only from the test suite still
has its *real* instances unresolved and unchecked: a green suite is no evidence the code compiles in
the launcher. `probe/` therefore keeps exactly the job `build-system.md` gives it, and now reaches
further than it did — through `Resolution` and the git-backed `PackageSource` as well as through
`Cache` — because that binding is precisely what a test carrier by construction cannot exercise. Fake
carriers check the logic; a real `main` checks that the logic has an interpretation on the platform.
Neither substitutes for the other.

Two costs, both as expected. A `FileSystem` fake is twelve methods, most of which no suite calls —
written once, but real bulk. And run-then-assert means every scenario costs a named private `def`
above the suite; that is how the existing suites already read, so it is continuity rather than a new
tax.

## 7. Evidence

Every claim below was compiled and run, not reasoned from documentation. The suite is
`./mill examples.run jvm exe-jar -m eliot.test.Runner <eliot-test>/src src test`; the probe is the
same with `-m eliot.build.Probe` over `src probe`.

| Claim | How |
|---|---|
| The tree did not build against the current compiler | `Descriptor.els:132` ⤳ "Public declaration after the private declarations starting on line 123"; three declarations moved, then 124 tests pass |
| The refactor loses nothing and adds seventeen | 141 cases green, with `parseTagRefs`/`commitOf`/`anchorCommit`/`parseDescriptor`/`parseVersion`/`packageId`/`resolveTests` counts unchanged |
| A module that spawns, reads exit codes and raises a typed error runs on a pure carrier | `GitTests`, nine cases over `lsRemoteTags`/`mirrorClone`/`fetchTags`/`showFile` — including `raised: 'git ls-remote --tags github.com/x/foo' failed with exit code 128: no such repository` |
| The jvm `Process` instance declines rather than colliding | the same program resolves `Process[Fake]` with no ambiguity error, `Suspend[Fake]` being absent |
| The working directory is now assertable | `CacheTests` pins `mkdir target/cache; .$ git clone --mirror … target/cache/github.com/x/foo; .$ git ls-remote --tags target/cache/github.com/x/foo` and `target/cache/github.com/x/foo$ git fetch --tags --prune` |
| The resolver runs unchanged on a table carrier | `TablePackages` + the 23 existing resolver cases, whose bodies did not change |
| Rule 3 is a rule, not a preference | giving a *wide* fake a `PackageSource` instance ⤳ "Multiple ability implementations found for ability 'PackageSource' with type arguments [Fake]" |
| Rule 2 is a rule, not a preference | a run written inside the pinned test body ⤳ `Expected: {Throw[AssertionError] \| Id} Fake[String]` / `Actual: {Throw[AssertionError] \| Id} String`; moved into its own `def`, it compiles |
| The whole stack resolves at the *real* carrier | `probe/` compiles: `PackageSource` over four nested `ThrowCarrier`s on `IO`, with `Process`/`FileSystem` riding `Suspend` through all of them |
| …and runs | `java -jar Probe.jar github.com/eliotlang/eliotlang.github.io` clones a real bare mirror, lists its tags, and prints the resolver's honest `publishes no v1` for a repository that publishes no versions |

## 8. Open questions

- **Where the cache root belongs.** `packageCacheRoot` is a constant because the ability's methods
  carry only what the resolver knows and `Dep` cannot stack with `Throw`. When the launcher exists it
  owns cache location, and the shape that replaces the constant is worth choosing then rather than
  guessing now — a `Dep` cross-lift in the platform layer would also make the question go away.
- **Where a test carrier lives.** `test/` mirrors `src/` one-to-one, and `FakeWorld`/`TablePackages`
  are not suites. When the framework grows a fixture convention they should move to it.
- **Whether `Cache` stays separate from `PackageSource`.** The instance calls precisely `Cache`'s
  exported surface. Merging them is tempting and probably wrong — the cache answers questions the
  resolver never asks (`refreshed`, and the ancestry check the fetcher is owed) — but worth asking
  again once the launcher has a shape.
- **How much of the world one fake should model.** `FakeWorld`'s directories are seeded by the test
  rather than created by the operations that would have made them. A world that only learns of a
  directory by watching git create it would catch more, at the cost of a fake worth testing itself.
