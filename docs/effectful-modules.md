# Modules That Do Things: Retiring the Pure/Effectful Split

Status: **DONE**, 2026-08-12, and **revisited 2026-09-04 — read §9 first**. Built against the compiler
at `robertbraeutigam/eliot@f7a546b` and the framework at `eliotlang/eliot-test@d136e0f`. The suite went
from 124 cases to 141, and the seventeen new ones are about code that could not previously be tested at
all.

§1–§8 are that refactor as it stood on the day it landed, kept as written. §9 is what the compiler and
the framework changed under it since, what still holds, and what it now costs: **rule 2 is retired**,
one rule is added, and the tree did not compile at all until §9.1.

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
2. **Run-then-assert.** *(Retired 2026-09-04 — the capture tag removed the requirement; see §9.4.)*
   The run must sit in a definition with no ambient carrier of its own. Inside a
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

*(`probe/` was deleted on 2026-09-04 and this section describes a directory that no longer exists. Its
job is now done by two ordinary test cases that name the platform's run boundary — §9.6.)*

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
- ~~**How much of the world one fake should model.**~~ *Answered 2026-09-04 (§9.3): the fake's
  `git clone --mirror` makes its target exist, so the first-visit/second-visit distinction is observed
  within one run rather than seeded. The rest of the world is still seeded, and that is still fine —
  a directory nothing in the code creates has nothing to learn from.*


## 9. Revisited, 2026-09-04

Against compiler `3be06cc` and framework `36ccc10`, on the two questions this document exists to
answer: *do the modules carry behaviour rather than data-oriented interfaces*, and *do the tests
exercise that behaviour without doing I/O*. Both answers are yes. Everything below is what changed
around them, and one of the changes is that the tree had stopped compiling.

### 9.1 The tree had stopped building, and nothing said so

`type Test` no longer exists. The framework removed it in *"No pinned carriers anywhere: suites are
computations, not stored data"* (2026-08-18) — an alias may not carry an open row, so a suite states
its row itself — and all seven suites here declared `def testCases: Test`. `FakeWorld.outcomeOf` also
collided with an `outcomeOf` the framework gained in the same commit. Both are one-line-per-file fixes
(`{Writer[List[TestResult]]} Unit`, and a rename to `answerOf`), and with them the 141 cases §7 claims
are green again.

Worth stating plainly, because it will happen again: **this project has no build of its own and pins no
framework version.** The compiler and `eliot-test` are sibling checkouts at whatever commit they happen
to be on, so a "DONE" here decays without a signal. §7's evidence table was a true statement about a
tree that no longer compiled three weeks later.

### 9.2 Do the modules carry behaviour? Yes — and §2's anaemia is gone

| Module | Verdict now | Evidence |
|---|---|---|
| `Git` | **behaviour** | Its surface is four operations that *spawn* — `lsRemoteTags`, `mirrorClone`, `fetchTags`, `showFile` — plus the three pure readings of what git wrote. No function answers a command line for somebody else to run; `checked`/`failureOf` are private. |
| `Cache` | **behaviour** | Six operations, all of them cache *policy* expressed in `Git`'s operations: where a mirror lives, whether it must be made, which directory each command stands in. `ProcessResult` never appears. |
| `PackageSource` | **behaviour** | An ability with two methods and a constrained catch-all instance. `Resolution` declares `{PackageSource, Throw[ResolutionError]}` and carries no callbacks. |
| `Descriptor`, `Clause`, `Version`, `PackageId` | **healthy, unchanged** | Parsing, ordering, canonical form. Pure subject matter, nothing withheld. |

The one thing still shaped by a limitation rather than by the subject is `packageCacheRoot`, a constant
in `PackageSource` because `Dep` cannot ride the same carrier stack as `Throw` (§4.3, §8). It is
configuration, not behaviour, so it is not anaemia — but it is the one place a module states something
it should be told.

### 9.3 Do the tests exercise mocked behaviour? Yes, and two things now make them exercise more

`GitTests` and `CacheTests` run production code on `Fake`, which has **no `Suspend` instance**, and
`Suspend` is the only route to a native side effect: a body that tried to touch a real process or a
real file would not compile. So "unit tests that do no I/O" is structural here rather than a
convention, and that has not changed.

What changed is how much they can see:

- **A faked case costs no helper definitions.** *(Superseded 2026-09-04: the fixture these words lived in
  is deleted, and `eliot.test.Mock` provides the doubles. What follows is why it worked.)* `journalOf` and
  `answerOf` declare their computation slot with the **capture tag** `{| Fake}` — the pinned row at zero entries, the same type as `Fake[A]`
  but declaring that the slot hosts a computation on that carrier (compiler `docs/effects.md` §2.3,
  shipped as W3 on 2026-09-04). The run is therefore written inline in an ordinary `pure` body, and a
  whole *script* of operations can be, sharing one world. Fourteen private definitions — one per
  scenario, the tax §6 called "continuity rather than a new tax" — are gone.
- **The fake learns from git.** A successful `git clone --mirror` now makes its target directory exist
  in the fake world, because that is what the real one does and `Cache.ensuredMirror`'s presence test
  reads nothing else. "Clone on the first visit, not on the second" is consequently *observed within
  one run* rather than seeded by the test, and a clone landing anywhere other than where
  `cacheDirectory` looks now fails a case instead of passing unnoticed — the same bug class as the
  relative-path bug of §2, one layer deeper.

Three cases were added on the strength of it (144 green). They were mutation-tested rather than
believed: making `Cache`'s presence test always answer "absent" fails exactly those three and nothing
else.

### 9.4 Rule 2 is retired; 1, 3 and 4 stand

> **2. Run-then-assert.** The run must sit in a definition with no ambient carrier of its own. […]
> This is a real constraint, not a style choice — a test cannot assert part-way through a faked run.

The premise was the region rule and it is still true: a region writes every carrier-generic callee at
*its* carrier, so an untagged fake run inside a suite is written at the suite's own stack. What changed
is that a slot can now **declare that it hosts a computation on a carrier**, and the elaborator then
writes nothing into it. So the run may be written where it stands, and a discharge word taking a
`{| Fake} Unit` body would let a case interleave assertions with faked effects the way
`eliot-test`'s own `onConsole` does.

Run-then-assert survives as *the clearer shape when the assertion is about a finished answer* — which
is most of what these suites assert — but it is now a choice. **The replacement rule: a slot that takes
a computation on a fake carrier declares the capture tag; nothing else has to be arranged around it.**

Rules 1, 3 and 4 are unchanged and were re-confirmed by this pass: the carrier still implements its row
flat, two fakes still exist because one wide fake would collide with the constrained catch-all, and the
fake still cannot cheat.

### 9.5 The rule that had to be added: assertions cannot ride a `FileSystem` fake

`Fake` implements `Throw[GitError]` and `Throw[IoError]` but deliberately **not**
`Throw[AssertionError]`, which is what a body asserting between its own steps would need. The reason is
not a carrier problem — it is a name collision: `AssertionError` lives in `eliot.test.Assertion`,
`IoError` in `eliot.file.File`, and **both modules export a `message`**, so a file that fakes
`FileSystem` cannot import the assertions ("Imported names shadow other imported names"). There is no
selective import to reach around it, and the instance must be colocated with `Fake`, so it cannot be
moved to a file that imports only one of them.

It costs nothing *here* — the journal accumulates, so asserting it after a two-step script says
everything asserting it between the steps would have — but it is a wall for any fake of the filesystem
that wants interleaved assertions, and it will be hit again by anyone doing this. The fix is a rename
in one of the two libraries (`message(e: IoError)` in the stdlib, or the infix `message` in
`eliot.test.Assertion`); neither is this project's to make.

### 9.6 The platform carrier, and what became of `probe/`

`probe/` was deleted on 2026-09-04 (`f3f8d15`), and with it the only thing that ever checked that the
effectful modules have an interpretation **on the platform**. That check is not redundant with the
suite: ability resolution happens at monomorphization, so running production code at `Fake` resolves
`Process[Fake]` and never `Process[IO]`, and every real instance the tool depends on stays unresolved
and unchecked by a green faked run.

Its replacement is `test/eliot/build/RealWorldTests.els`: two **ordinary** cases in an ordinary suite,
which spawn a real `git` and a real missing program — no network, nothing written — and assert the
*shape* of what each reported. The suite declares `{Writer[List[TestResult]]}` like every other one,
and the bodies are `in pure`; how that can be true while `git` really runs is below.

The `catch`es live next door in `test/eliot/build/RealWorld.els`, which answers plain `String`s and
declares `{Process}` alone: the platform's `Process` instance is
`implement[F[_] ~ Suspend & Throw[IoError] & Effect]`, so a real call needs a `Throw[IoError]` layer,
which a `catch` supplies — and naming `IoError` means importing `eliot.file.File`, which §9.5 says a
file that asserts cannot do. So the module that names the failure types is the module that does not
assert, and it is `{Process}` because the layer is supplied in the one region that needs it.

**What makes it work is that the platform carrier is injectable exactly like a fake one, and that is
the general answer to "who declares the row".**

A suite may only perform what the entry point running it declares, and `eliot.test.Runner.main`
declares `{Console}`. Widening that row would fix this project and nothing else — the row an entry
point owes is the union of what its suites perform, so the next project's suites perform `FileSystem`,
or an ability that project declared itself and no library can ever name. A framework that owns `main`
would get widened once per project, forever, and still could not serve a user-declared effect. Having
the *project* write its own entry point out of the framework's parts fixes that, and is worse: a test
project should no more assemble a runner than a JUnit user should assemble JUnit.

So no effect propagates to the runner at all. A test already runs production code on a fake by naming
that carrier at a slot which fixes it — `journalOf(world, computation)`. It runs the same code on the
*platform's* carrier the same way, by naming the jvm layer's **run boundary**:

```eliot
def runMain[A](io: IO[A]): A          -- eliot.jvm.IO, registered in RunBoundaryFunctions
```

which is the very call a synthesized entry point wraps a program's `main` in. A run boundary's slot
fixes the concrete carrier, so the computation handed to it is performed **in `IO`** and is charged to
`IO` — the same rule (`RowChecker.fixesCarrier`) that keeps a faked run out of the harness's row. The
case is therefore written `in pure`, the strictest body the framework has, and the suite declares
`{Writer[List[TestResult]]}` and nothing else:

```eliot
"the platform" should "run git for real, and report what git said when it said no" in pure {
   opening(refusalPrefix, runMain(tagReportOf("no-such-repository-anywhere", here))) shouldBe refusalPrefix
}
"the platform" should "raise, not answer, when a program cannot be started at all" in pure {
   opening("io: ", runMain(spawnReportOf("no-such-program-anywhere", here))) shouldBe "io: "
}
```

**The framework is untouched, and stays untouched for any effect that will ever exist** — including one
declared in a project it has never heard of. There is no row to widen, because a suite's row never
grows: a faked effect is discharged at the fake carrier, a real one at the platform's boundary, and
what reaches the runner is a verdict either way.

Two costs, both stated rather than hidden:

- **Naming `runMain` means `import eliot.jvm.IO`, so a file doing this is pinned to the jvm platform.**
  That is correct for a test *about* the platform's instances, and it is the only kind of test that
  wants a real effect. Portable suites stay carrier-generic and use fakes. It is also the reason this
  is not a general escape hatch smuggled into portable code: a module that imports the platform's
  carrier is platform code by definition, and platform code could always do this — the run boundary is
  ordinary Eliot in the jvm layer, not a compiler privilege.
- **The discharges still need a module that does not assert** (`RealWorld.els`), because of §9.5's
  `message` collision. That is the one wart, and it is a naming problem rather than a design one.

146 green, through the stock `eliot.test.Runner`.

### 9.7 Where the open questions stand

`packageCacheRoot`'s home, where a test carrier lives, and whether `Cache` stays separate from
`PackageSource` are all unchanged and still waiting on the launcher (§8). The world-modelling question
is answered (§9.3), and so is the platform-carrier one (§9.6): the real instances are checked again, by
two ordinary tests that name the platform's run boundary, with no framework change and no entry point
of this project's own. Two are new. **The fixture itself is gone**: `eliot.test.Mock` now ships the doubles for every base effect,
so `FakeWorld.els` (195 lines) was deleted and `CacheTests`/`GitTests` say only what they are about —
`eliot-test/docs/mocking.md`, built 2026-09-04. `TablePackages` stays, for §3's rule-3 reason and because an
instance for `PackageSource` could live only in production code or in the framework. The `message` collision
of §9.5 is settled the same way: the framework's infix `message` is now `describedAs`, so a file may name
both a file and an assertion. The one that stays open is the language question underneath all of it: an ability may have at most one
carrier-generic instance, which is why a double must be concrete and why the framework must own it
(`mocking.md` §2, fact 1).
