# Modules That Do Things: Retiring the Pure/Effectful Split

Status: **PLAN**, nothing implemented beyond the compile-and-run spikes recorded in §7. Written
2026-08-12 against the compiler at `robertbraeutigam/eliot@f7a546b` and the framework at
`eliotlang/eliot-test@d136e0f`.

## 1. The constraint that shaped these modules is gone

`docs/build-system.md` records this as the single most load-bearing lesson of building the tool:

> **The pure/effectful boundary is imposed, not chosen.** A test case body is pinned to
> `{Throw[AssertionError] | Id}` and may only assert, so *nothing effectful is reachable from the
> test suite* — not "hard to test", unreachable. Every module that touches the outside therefore
> splits in two: all the decisions on the pure side where tests can reach them, and a shell next door
> thin enough to trust unexamined.

The premise was true and the conclusion followed. Both halves have since been fixed in the compiler,
recorded in the eliot repository's `docs/testing-effects.md` (status: *adopted, done*):

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

What follows is that a `{Process, FileSystem}` module is reachable from the test suite *as it is*.
The split into "`Git` decides, `Cache` performs" was a workaround for a limitation that no longer
exists, and it is now costing what workarounds cost: the module with the behaviour has no tests, and
the module with the tests has no behaviour.

## 2. Where the anaemia is

| Module | Verdict | What is wrong |
|---|---|---|
| `Git` | **anaemic** | Four of its eight exported functions answer a command line as `List[String]`, for somebody else to run; the rest read strings git already wrote. It knows how to *say* things to git and never says them. |
| `Cache` | **the mirror image** | It holds every real decision — when to clone, which working directory a command needs, when a non-zero exit is data and when it is a failure — and it is the one module with no tests, because it could not have any. |
| `Resolution` | **distorted, not anaemic** | The algorithm is all here, but its source arrives as two callbacks (`descriptorAt`, `anchorAt`) threaded verbatim through nine private functions — 22 parameter occurrences of plumbing. The module's own doc comment says an `ability` was tried first and rejected *only* because nothing could discharge it. |
| `Descriptor`, `Clause`, `Version`, `PackageId` | **healthy** | Genuinely pure subject matter — parsing, ordering, canonical form. No behaviour is being withheld from them. Leave them alone. |
| `Probe` | **keeps its job** | See §6: fake carriers do not replace it. |

The concrete shape of the `Git`/`Cache` split today: `lsRemoteTagsCommand(target)` answers
`["git", "ls-remote", "--tags", target]`, and `Cache.publishedTags` runs it, checks the exit code,
raises `GitError`, and hands the output back to `Git.parseTagRefs`. One operation, split across two
modules and a `ProcessResult`, so that half of it could be tested. `GitTests` accordingly asserts
things like

```eliot
lsRemoteTagsCommand("github.com/x/foo").joined(" ") shouldBe "git ls-remote --tags github.com/x/foo"
```

which pins the *spelling* of a command nobody in the test has run. It cannot catch the one class of
bug this code has actually had — the relative-path bug recorded in `build-system.md`, where a clone
launched from the wrong working directory buried the mirror at `target/cache/target/cache/…`. The
working directory is not part of a command line, so no assertion about a command line can see it.

## 3. The mechanism

A test declares its own carrier — an ordinary `data` with an `Effect` instance and, for each effect
in the row, an instance of that effect for the carrier. Production code is untouched, because a
`{Process, FileSystem}` signature names no carrier and therefore commits to no interpretation of it.
Instantiating that code at the test's carrier and running it yields a plain value to assert on.

Four rules govern it, all verified in §7:

1. **The carrier implements the row flat, itself — including each failure channel.** For
   `{Process, FileSystem, Throw[IoError], Throw[GitError]}` the fake needs five instances: `Effect`,
   `Process`, `FileSystem`, `Throw[IoError, Fake]`, `Throw[GitError, Fake]`. It is tempting to
   discharge the `Throw`s with the real `runThrow` over the fake as a base — that does not work and
   cannot be made to: `Process[ThrowCarrier[E, Fake]]` would need a lift of the fake's `Process`
   through `ThrowCarrier`, the real effects get theirs for free by riding `Suspend`, and writing one
   by hand is an orphan instance (neither `Process`'s module nor `ThrowCarrier`'s is ours). So the
   fake owns the whole row and reflects a raise into its own result slot.
2. **Run-then-assert.** The run must sit in a definition with no ambient carrier of its own. Inside
   a test body pinned to `{Throw[AssertionError] | Id}` the ambient carrier *is* that pinned stack,
   and every carrier-generic callee is written at it, so the run fails there with
   `Expected: {Throw[AssertionError] | Id} Fake[String]` / `Actual: … String`. In practice: one
   private `def` per scenario computing a `String`, and a body that only compares it. This is a real
   constraint, not a style choice — a test cannot assert part-way through a faked run.
3. **One fake per seam, each implementing the minimum.** A production instance written as a
   constrained catch-all (`implement[F[_] ~ Process & FileSystem & …] PackageSource[F]`, the only
   placement the orphan rule allows for an instance over an arbitrary carrier) matches any fake that
   happens to satisfy those constraints. A *wide* fake that also fakes `Process` and `FileSystem`
   therefore collides with it: `Multiple ability implementations found for ability 'PackageSource'
   with type arguments [Fake]`. A resolver test wants a table of strings, not a fake process, so the
   narrow carrier is the natural thing to write anyway — but it is a rule, not a preference.
4. **The fake cannot cheat.** It has no `Suspend` instance and `Suspend` is the only route to a
   native side effect, so a test carrier is *structurally* incapable of touching a real process or a
   real file. An accidental `printLine` in tested code is a compile error, not a silent test that
   does I/O.

One convenience the shape depends on: `ProcessResult`, `IoError` and `Path` are abstract in the base
layer but concrete `data` in the jvm layer, and the test binary mounts jvm — so a fake can construct
`ProcessResult(128, "", "no such repository")` and a real `Path` without any test-only machinery.

## 4. Target shape

### 4.1 `Git` speaks git

Command construction and output parsing become private; the operations become the module's surface.
The working directory each command needs is part of the signature, which is what turns git's own
rule — *a command that names a repository by path runs where this program runs; one that operates on
the repository it stands in runs in the mirror* — from a comment into something a caller cannot get
silently wrong.

```eliot
def lsRemoteTags(target: String, from: Path): {Process, Throw[GitError]} List[TagRef]
def mirrorClone(source: String, target: String, from: Path): {Process, Throw[GitError]} Unit
def fetchTags(mirror: Path): {Process, Throw[GitError]} Unit
def showFile(revision: String, file: String, mirror: Path): {Process} Option[String]
def transportUrl(url: String): String
```

`GitError` and its `Show` move here from `Cache` — it is git's error, raised by the module that ran
git. `showFile` keeps `Option` and no `Throw`: a missing revision or a missing file is an ordinary
answer, and it is the one place a non-zero exit is read rather than raised, which the signature now
says out loud. `parseTagRefs`, `commitOf` and `anchorCommit` stay exported and stay pure — reading a
listing is a real question with real edge cases (annotated tags listed twice, peeled entries,
non-version tags) and its tests are good tests. `TagRef` and its `Compare` are unchanged.

### 4.2 `Cache` decides where mirrors live

Everything that is currently `checked`, `run`, `failureOf`, `outputWhenFound` and `here` leaves;
what stays is cache policy — `cacheDirectory`, `ensuredMirror`, `refreshed`, `publishedTags`,
`descriptorTextAt` — expressed in terms of `Git`'s operations. The module keeps its row and its two
failure channels; it loses the machinery of talking to a process.

### 4.3 `Resolution` takes a source ability

```eliot
ability PackageSource[F[_]] {
   def descriptorAt(target: PackageId, version: Version): {PackageSource} Option[Descriptor]
   def anchorAt(target: PackageId, majorLine: Int): {PackageSource} Option[String]
}
```

in its own module (`eliot.build.PackageSource`), which also carries the git-backed catch-all instance
— the ability's module being the only legal home for an instance over an arbitrary carrier. Every
`descriptorAt: PackageId => Version => {Effect} Option[Descriptor]` parameter disappears from
`Resolution`'s eleven functions; the rows become `{PackageSource, Throw[ResolutionError]}`.

This is the step the module's own doc comment asked for and it is now available, but it is also the
largest diff and the only one that touches an algorithm with 23 passing tests. It is staged last
(§5) and the callbacks remain a working fallback: nothing else in this plan depends on it.

## 5. Sequencing

Each step compiles and runs green on its own.

- **Step 0 — make the tree build again.** Already done in this branch: the compiler now enforces
  public-before-private declaration order within a file, and `Descriptor.els` and `Resolution.els`
  each declare a `data` after their first `private def`. Three declarations moved; 124 tests green.
- **Step 1 — the test carrier.** One new module in `test/`, holding the world, the carrier, the five
  instances, and two runners (`journalOf`, `outcomeOf`). Written once, used by every effectful suite
  after it. Nothing in `src/` changes.
- **Step 2 — `Git` absorbs the spawning, `Cache` reduces to policy.** `GitTests`' command-line
  assertions do not disappear, they relocate: what was `lsRemoteTagsCommand(…).joined(" ") shouldBe
  "git ls-remote --tags …"` becomes an assertion about the journal of what the program actually ran,
  working directory included.
- **Step 3 — `CacheTests`, the file that could not exist.** The cases the shell has never been tested
  for: clone-on-first-visit, no-clone-on-second, fetch runs *in* the mirror while clone runs in
  `here`, a non-zero `ls-remote` raises `GitError` carrying the command line and the diagnostics, a
  non-zero `git show` answers absent instead of raising.
- **Step 4 — `Resolution`'s callbacks become `PackageSource`.** `ResolutionTests`' existing
  `publishing(…)/published(…)` tables become the narrow carrier's world; the test bodies are
  untouched.
- **Step 5 — the docs.** `build-system.md`'s "pure/effectful boundary is imposed" lesson is rewritten
  (the boundary is now chosen, and this is what it buys), its module table gains an honest
  tested/untested column, and `Resolution`'s "effects cross a module boundary as callbacks" lesson
  gets its revisit.

## 6. What this does not replace

Instantiating production code at a fake carrier resolves `Process[Fake]` — **not** `Process[IO]`.
Ability resolution happens at monomorphization, so a module reachable only from the test suite still
has its *real* instances unresolved and unchecked: a green suite is no evidence the code compiles in
the launcher. `probe/` keeps exactly the job `build-system.md` gives it, and the rule stated there
holds unchanged — the probe (and later the launcher's own `main`) must reach every effectful module
deliberately. Fake-carrier tests check the logic; a real `main` checks that the logic has an
interpretation on the platform. Neither substitutes for the other.

Two costs worth stating up front. A `FileSystem` fake is twelve methods, most of which a given suite
never calls — written once in step 1, but it is real bulk. And the run-then-assert rule means every
scenario costs a named private `def` above the suite; that is how the existing suites already read
(`GitTests`' `tags`, `commit`, `anchor` helpers), so it is continuity rather than a new tax.

## 7. Evidence

Everything above was compiled and run against the toolchain named at the top, in a scratch source
root shaped like the target design — not reasoned from the documentation.

| Claim | How |
|---|---|
| The tree does not build against the current compiler | `Descriptor.els:132` ⤳ "Public declaration after the private declarations starting on line 123"; three declarations moved, then 124 tests pass |
| A module that spawns, reads exit codes and raises a typed error runs on a pure carrier | a `Git` with `lsRemoteTags`/`mirrorClone`, a `Fake` with `Effect`/`Process`/`Throw[GitError]` ⤳ prints the parsed tags, the command log, and `raised: 'git ls-remote --tags' failed with exit code 128: no such repository` |
| The jvm `Process` instance declines rather than colliding | the same program resolves `Process[Fake]` with no ambiguity error, `Suspend[Fake]` being absent |
| `ProcessResult` is constructible in test code | the fake's `run` answers `ProcessResult(exitCode, output, error)`; jvm's `data` merges with the base layer's abstract accessors |
| The whole `{Process, FileSystem, Throw[IoError], Throw[GitError]}` row runs on one flat fake | a `Cache`/`Git` pair as in §4, five instances on one carrier, driven by the real `eliot.test` runner: **7 cases green**, asserting the journal (`mkdir target/cache; .$ git clone --mirror …; .$ git ls-remote --tags …`), the working directory of a fetch (`target/cache/github.com/x/foo$ git fetch --tags --prune`), the raised `GitError`, and absence from a non-zero `git show` |
| An ability-shaped source works, with a production catch-all beside a test instance | `PackageSource` + `implement[F[_] ~ Process & FileSystem & Throw[IoError] & Throw[GitError] & Effect] PackageSource[F]` + a narrow `Table` carrier ⤳ **2 further cases green**, 9 in total |
| Rule 3 is a rule, not a preference | giving the *wide* fake a `PackageSource[Fake]` instance ⤳ "Multiple ability implementations found for ability 'PackageSource' with type arguments [Fake]" |
| Rule 2 is a rule, not a preference | the same run written inside the pinned test body ⤳ `Expected: {Throw[AssertionError] \| Id} Fake[String]` / `Actual: {Throw[AssertionError] \| Id} String`; moved into its own `def`, it compiles |

## 8. Open questions

- **Where the test carrier lives.** `test/` today mirrors `src/` one-to-one. A carrier module is not
  a suite, and when the framework's own conventions grow a fixture directory it will want to move.
- **Whether `Cache` survives step 4.** Once `PackageSource` exists, `Cache`'s exported surface is
  precisely what that instance calls. Merging the two is tempting and probably wrong — the cache
  answers questions the resolver never asks (`refreshed`, and the ancestry check the fetcher is owed)
  — but it is worth asking again once the launcher has a shape.
- **How much of the world one fake should model.** The spike's world is directories, a journal and
  canned replies matched by substring. A journal of paths that git itself would have created (rather
  than an `existingDirectories` list a test seeds) would catch more, at the cost of a fake that is
  itself worth testing. Start with the seeded list.

## Appendix A — the test carrier, as it ran

Step 1's deliverable, from the spike, with the unused `FileSystem` methods elided (they answer a
constant and are one line each). This is the whole of the machinery: the rest of the work is
ordinary code.

```eliot
data Reply(replyExitCode: Int, replyOutput: String, replyError: String)
data Canned(whenCommandContains: String, cannedReply: Reply)
data World(existingDirectories: List[String], journal: List[String], replies: List[Canned])

data Fake[A](runFake: Function[World, Pair[Either[String, A], World]])

implement Effect[Fake] {
   def pure[A](a: A): Fake[A] = Fake(w -> Pair(Right(a), w))

   def flatMap[A, B](f: Function[A, Fake[B]], fa: Fake[A]): Fake[B] =
      Fake(w -> foldPair(
         e -> after -> foldEither(err -> Pair(Left(err), after), a -> runFake(f(a))(after), e),
         runFake(fa)(w)
      ))

   def map[A, B](f: Function[A, B], fa: Fake[A]): Fake[B] =
      Fake(w -> foldPair(
         e -> after -> Pair(foldEither(err -> Left(err), a -> Right(f(a)), e), after),
         runFake(fa)(w)
      ))
}

implement Process[Fake] {
   def run(command: List[String], workingDirectory: Path): Fake[ProcessResult] =
      Fake(w -> Pair(Right(replied(command, w)), noted(spawnNote(command, workingDirectory), w)))

   def runInheritingIo(command: List[String], workingDirectory: Path): Fake[Int] =
      Fake(w -> Pair(Right(replied(command, w).exitCode), noted(spawnNote(command, workingDirectory), w)))
}

implement FileSystem[Fake] {
   def isDirectory(path: Path): Fake[Bool] =
      Fake(w -> Pair(Right(w.existingDirectories.any(d -> d == show(path))), w))
   def createDirectories(path: Path): Fake[Unit] = Fake(w -> Pair(Right(unit), created(show(path), w)))
   -- … the other ten, each answering a constant or noting what it was asked to do
}

implement Throw[GitError, Fake] {
   def raise[A](err: GitError): Fake[A] = Fake(w -> Pair(Left(show(err)), w))
}

implement Throw[IoError, Fake] {
   def raise[A](err: IoError): Fake[A] = Fake(w -> Pair(Left(show(err)), w))
}

/**
 * Everything `computation` did against `world`, one entry per act, in order.
 */
def journalOf[A](world: World, computation: Fake[A]): String =
   second(runFake(computation)(world)).journal.joined("; ")

/**
 * What `computation` answered against `world`, rendered by `rendering` — or the error it raised.
 */
def outcomeOf[A](world: World, rendering: A => String, computation: Fake[A]): String =
   foldEither(err -> "raised: " ++ err, a -> rendering(a), first(runFake(computation)(world)))
```

And a suite against it, showing the run-then-assert shape rule 2 forces:

```eliot
def testCases: Test = {
   "publishedTags" should "clone a mirror this build has never seen, then list what it publishes" in {
      firstVisitJournal shouldBe expectedFirstVisit
   }
   "refreshed" should "fetch in the mirror, which is the repository the command stands in" in {
      refreshJournal shouldBe "target/cache/github.com/x/foo$ git fetch --tags --prune"
   }
}

private def expectedFirstVisit: String =
   "mkdir target/cache; " ++
      ".$ git clone --mirror https://github.com/x/foo target/cache/github.com/x/foo; " ++
      ".$ git ls-remote --tags target/cache/github.com/x/foo"

private def firstVisitJournal: String =
   journalOf(emptyWorld.answering("ls-remote", listing), publishedTags(cacheRoot, packageUrl))

private def refreshJournal: String =
   journalOf(emptyWorld.withDirectory(mirrorDirectory), refreshed(cacheRoot, packageUrl))
```

Two lexical traps the spike hit, both cheap once known: a file's declarations must be
public-before-private throughout (this is what §5's step 0 is about), and a test module may not
declare a `subject` — `eliot.test.Test` exports that accessor and an import that shadows a local name
is an error.
