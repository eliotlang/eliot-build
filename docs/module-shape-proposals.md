# Proposed module shapes — the four files still over two hundred lines

A proposal, not a record: nothing here has been done. `docs/effectful-modules.md` §12 split eight modules
into four packages by *what a file is allowed to know*, and four files came out of it still large enough
to be holding more than one idea:

```
396  format/PackageFile
303  resolve/Resolution
265  git/Git
199  format/Clause
```

Length alone is not a defect — `model/PackageId` is 165 lines of one idea and should stay one file. What
follows are the cuts where a *second* idea is in there with a name of its own, ordered by what they buy
against what they cost. Each says what moves, what the new module is called, which way the imports point,
and what the test tree does in response.

## A. `Commit` belongs to the model, and moving it deletes an edge

`model/Lineage` — new, ~45 lines: `data Commit(hash: String)`, its `Eq` and `Show`, and `sameAnchor`
(lifted out of `Resolution`).

A commit hash is vocabulary. It has no syntax, no I/O and no effect; it is what a tag ultimately names,
what a lockfile pins and what identity compares — the same kind of thing as `Version` and `Repository`,
and it sits in `git/Git` only because git is where it was first needed.

The payoff is not the 20 lines. `resolve/PackageSource` and `resolve/Resolution` currently
`import eliot.build.git.Git`, and **`Commit` is the only thing either of them takes from it** — the
resolver's `anchorAt` answers an `Option[Commit]`, and a `Selection` carries one. So the whole
`resolve → git` edge in §12's layering exists to name a hash. Move the type and the edge is gone: MVS
imports `model` and nothing else, and `git/` drops out of the resolver's import list the way
`eliot.system.Process` dropped out of `git/Git`'s. That is the same argument §12 made for splitting
`ShellGit` out — a separation the imports *state* rather than one the signatures merely promise.

Why `Lineage` rather than a bare `model/Commit`: the anchor question is the reason the resolver holds a
commit at all — a compatibility line is identified by the commit its first release names, and two anchors
unify only when both are present and equal. `sameAnchor` is that rule, it is pure, and it currently sits
as a private in the middle of the MVS closure where nothing about it is discoverable. `firstRelease` could
join it from `model/Version`, though that is a coin-flip: it is also just "the `vN.0` of a line".

This one is also a precondition for B.

## B. `git/Git` (265) → `git/Git` (~150) + `git/Tags` (~120)

Two jobs are in that file, and its own doc comment names them both in its first sentence: *the operations
the tool performs on a repository, as an effect, and the reading of what git says back, as plain
functions.*

| module | holds | imports |
| --- | --- | --- |
| `git/Tags` | `TagRef` and its `Compare`, `parseTagRefs`, `commitOf`, `anchorCommit`, and the peeling rules (`tagNameOf`, `withTag`, `isPeeled`, `bareTagName`, …) | `model` only |
| `git/Git` | `GitError`, `Mirror`, `Remote`, `Revision`, `effect Git`, `remoteOf`, `revisionName` | `git/Tags`, `model` |

`git/Tags` is the listing a repository publishes and every question asked of one; it knows nothing about
an effect, a mirror or a subprocess, and a reader of it never has to hold the effect in their head. `Git`
imports it because the effect's members answer in `TagRef`. The direction is one-way and only works once
`Commit` has left for `model` (A) — otherwise `Tags` needs `Commit` from `Git` and `Git` needs `TagRef`
from `Tags`, which is a cycle. That is the dependency between the two proposals.

**The tests have already made this cut.** `GitTests` is 20 cases and 17 of them are `parseTagRefs` (9),
`anchorCommit` (4), `commitOf` (3) and `TagRef` ordering (1); the other three are `remoteOf` and
`revisionName`. It becomes `git/TagsTests` almost whole, with a three-case `GitTests` left beside
`ShellGitTests` — exactly the shape §12 produced when `shellGit` moved out.

## C. `format/PackageFile` (396) → four modules

The biggest file, and it is carrying four separable things: the descriptor vocabulary read, the same
vocabulary written, a generic checked reading of clauses, and the `dep` line — which is not a top-level
clause at all but the one clause that appears at *every* level.

### C1. `format/ClauseReader` (~95) — one clause, read carefully

`required`, `optional`, `atMostArguments`, `knownChildren`, `requireKnown`, `requireThat`, `unknown` and
`unknownReason` are not about the build vocabulary. They are about reading a clause and complaining in
terms of the clause when it does not say what was expected, and `format/Clause` — which decides shape and
only shape — is the wrong home for them too, because they raise.

Give the module its own error, `data ClauseProblem(clauseText: String, problem: String)`, and the
descriptor error becomes the union of the two channels underneath it:

```eliot
data DescriptorError = Malformed(syntax: ClauseError) | Unreadable(problem: ClauseProblem)
```

`parseDescriptor` already discharges `ClauseError` from the parser with `runThrow` and wraps it; it would
discharge `ClauseProblem` from the reader the same way, in the same function. Two lower modules, two
error types, one `catch` for the caller — and the reader's diagnostics stop being reachable only through
the vocabulary that happens to use them. Alternative names considered: `ClauseCheck`, `Expected`.

### C2. `format/DependencyClause` (~90) — what a `dep` line names

`dependencyOf`, `siblingDependencyOf`, `requirementOf`, `referenceOf`, `versionOf`, `checkedVersion`,
`checkSchemeless`, `dependenciesOf`, `testDependenciesOf`.

Every other clause reader in the file reads one clause into one thing at one place in the file. `dep` is
read by the top level, by a `module`, by a `test` block inside a module and by an `artifact` — four
parents, and a `backend` reuses `referenceOf` for a fifth. It also carries rules nothing else does: a
version token is a git tag and is *parsed* here, a URL is scheme-less by invariant, a sibling may carry no
version and a foreign package must. That is a module's worth of decisions with one sentence of
documentation covering them, and the sentence is already written on `dependencyOf`.

Imports `ClauseReader`, `Clause` and `model`; imported by `PackageFile`.

### C3. `format/DescriptorWriter` (~75) — the descriptor written back out

`renderDescriptor` and the eleven `render*` privates.

The strongest evidence is the import list: the writer needs `model` and string operations, and **never
touches `Clause` at all**. It is not in the reading chain — it is the one half of the format that turns a
model into text rather than text into a model, and it is 75 lines of its own vocabulary of layout.

The cost, stated plainly: `PackageFile`'s doc says it is "the only place that knows the vocabulary", and
after this two modules know it. That is true today in substance already — `"dep"`, `"test"`, `"module"`,
`"artifact"`, `"sha256"` are each spelled in both halves of the file — and what actually binds the two is
a round-trip test, not proximity. Which leads to the gap this split exposes: **the writer has no tests of
its own.** It is used as the *assertion vocabulary* of 24 `parseDescriptor` cases (`renderDescriptor` is
how a parsed descriptor is shown) and is never the subject of one. Splitting it out makes that
conspicuous and gives the cases a place to live.

### C4. What is left, and a simplification that should ride along

`PackageFile` keeps `DescriptorError`, `descriptorFileName`, `parseDescriptor`, the top-level assembly and
the `module` / `artifact` / `plugin` / `jar` / `backend` readers — about 230 lines, which is still the
largest file in the tree. One change takes it to ~180 and is worth doing on its own merits.

The top level is currently read by a fold with a `ClauseKind` sum, a `kindOf`, a `withClause` and four
`with*` functions that each rebuild all four fields of `Descriptor` — 65 lines, of which the interesting
content is which keyword feeds which field. Every *nested* block in the same file is read differently and
better, through `childrenNamed`:

```eliot
private def interpret(clauses: List[Clause]): {Throw[ClauseProblem]} Descriptor = {
   knownClauses(descriptorKeywords, clauses)

   Descriptor(
      named("dep", clauses).map(dependencyOf),
      named("module", clauses).map(moduleOf),
      named("test", clauses).flatMap(dependenciesOf),
      named("artifact", clauses).map(artifactOf)
   )
}
```

That reads the root exactly as `moduleOf` reads a `module` block, deletes `ClauseKind`, `kindOf`,
`withClause` and all four `with*`, and removes four places where the four-field constructor is spelled out
and its arguments could silently swap. It needs one addition to `ClauseReader` — `knownClauses` over a
list, with `knownChildren` becoming `knownClauses(keywords, clause.children)` — and one to `Clause`, or a
local, for `named`. Order is preserved: `filter` keeps file order within a keyword, which is all the
current fold preserves either.

`ClauseKind`'s own doc already says it exists for a reason the carrier model imposed and effects v6
removed ("It stays because naming the alternatives is clearer…"). With the fold gone there are no
alternatives left to name.

Resulting package:

```
format/Clause            199   shape, and the parser         (unchanged)
format/ClauseReader      ~95   one clause, read carefully
format/DependencyClause  ~90   what a dep line names
format/PackageFile      ~180   the descriptor vocabulary, read
format/DescriptorWriter  ~75   the descriptor vocabulary, written
```

## D. `resolve/Resolution` (303) → `Configuration` (~55) + `Selection` (~80) + `Resolution` (~170)

Three decisions are folded together in there, and only the third is minimal version selection.

### D1. `resolve/Configuration` — which of a descriptor's scopes are opened

`data Configuration`, its `Show`, `artifactNamed`, and the dispatch currently inlined in `resolve`:

```eliot
def configuredDependencies(configuration: Configuration, descriptor: Descriptor): Option[List[Dependency]]
```

`None` means no artifact by that name, so `NoSuchConfiguration` stays with the other resolution errors and
this module raises nothing. What it owns is the answer to "an artifact's dependencies and the base
dependencies, or the test block's and the base dependencies" — a fact about descriptors and build
configurations that is true whether or not anybody resolves anything. §12 declined to move `Configuration`
to `model` on the grounds that it is the unit *resolution* resolves; that argument keeps it in `resolve/`
and says nothing against it having its own file there.

### D2. `resolve/Selection` — the answer, and when two spellings are one package

`Selection`, `Resolution`, their `Show` and `Compare`, `selectedVersionOf`, and `sameLineage`.

This is the vocabulary a *caller* of the resolver holds: what came out, in canonical package order, and
the version selected for a repository. None of it is the algorithm. `sameLineage` joins it because it is
the predicate about two selections' identity — with `sameAnchor` having gone to `model/Lineage` (A), what
is left here is "same compatibility line and same anchor", which is a statement about selections.

The effectful half of the identity question — `Identified`, `identified`, `byLineage`, URL first and a
lineage lookup only for an unfamiliar URL — stays in `Resolution`, because "ask the source only when the
URL misses" is an optimisation of the closure rather than a fact about selections.

### D3. Optional third cut: `resolve/Closure` (~85)

If ~170 is still too big, the next seam is the expansion engine: `ResolutionState`, `emptyState`,
`expanded`, `inserted`, `replaced`, `completed`, `resolutionDepthLimit`, `rounds` and `twice` — "a fixpoint
in a language with no loops, as a fold over a list of rounds, with a declared ceiling that raises rather
than answering partially". That is a nameable idea, and `resolutionDepthLimit` reading its bound back off
the same list would be entirely contained.

Flagged as optional because it is the least clean of these: the state's `pending` frontier exists because
of the *specific* rule that a selection re-enters it exactly when it is new or its version went up, so a
closure module would either take that rule as a function parameter or stay intimate with MVS while
pretending not to be. Worth doing only if the split above leaves `Resolution` still hard to read.

Tests follow the same lines: `selectedVersionOf` (2 cases) to `SelectionTests`, `resolutionDepthLimit`
(1) to wherever the ceiling lands, and the 19 `resolve` cases stay.

## E. Smaller, and only if the code is being touched anyway

**Indented blocks are rendered twice.** `Clause`'s `render` threads a depth through `header`/`block`/
`indent`, while `PackageFile`'s writer indents whole nested renderings with `renderBlock`/`indented`. The
second approach is the general one — it is why the writer needs no depth parameter — and `Clause.render`'s
three unrolled levels would shorten under it. A shared `format/Block` would be ~25 lines, which is under
the size §12 refused for a `Dependency` module; the honest version of this proposal is "write `Clause`'s
renderer in the writer's style if `Clause` is opened for another reason", not "add a module".

## What should stay as it is

- **`model/PackageId` (165)** — one idea (identity, and the canonical form it is compared in) plus ten
  one-line instances. Splitting `Repository` from `Package` would separate types whose whole point is how
  they relate.
- **`model/Version` (132)** — same: a version, a line, and the ordering MVS runs on. The parser is 30
  lines and belongs with the type it parses, since the type's invariants *are* what it refuses.
- **`format/Clause` (199)** — the grammar is one rule and the parser is one fold over it; the stack-based
  step functions are not separable from the state they step.
- **`git/Cache` (139), `git/ShellGit` (102), `resolve/GitPackages` (63), `resolve/PackageSource` (38),
  `model/Descriptor` (80)** — each already one job.

## Order to do them in

1. **A** (`model/Lineage`) — smallest, and it removes a layering edge on its own.
2. **B** (`git/Tags`) — depends on A, and the test split is already written.
3. **C4** (the `interpret` simplification) — deletes code, changes no module boundary, and makes C1 easier
   to see.
4. **C1 → C2 → C3**, in that order: the checked reader first, since the dependency reader needs it.
5. **D1 → D2**, and **D3** only if D1 and D2 leave `Resolution` still crowded.

Each step is independently green: none of them changes what any suite asserts, only which file the
assertion lives next to.
