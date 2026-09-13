# The Eliot Build System: Git-Native Packages, Declarative Descriptor, Standard Verbs

Status: **DESIGN**, being built. Records the design discussion of 2026-07-21. Fixes the model, the
semantics, the descriptor contents, and the descriptor syntax (`eliot.pkg`). Amended 2026-08-02:
identity is decided by the URL *or* by a shared lineage anchor (see below). Amended 2026-08-06: the
`replace` clause is cut, and the implementation's own lessons are recorded (both below). Amended
2026-08-12: the modules that touch the outside carry their own logic and are tested
(`docs/effectful-modules.md`), which retires one lesson below and rewrites another. Amended
2026-09-13: the launcher has a `main` and one verb, which settles the second lesson below the way it
said it would be settled. Amended 2026-09-13: a module may say **where** it is (`at`), because the
convention cannot hold in the one repository that has to dogfood it (below).

**Where the implementation stands** (2026-09-13, 177 tests):

| Module | What it is | State |
|---|---|---|
| `Clause` | the `keyword args… { … }` grammar, and nothing about the build model | done |
| `Descriptor` | the typed `eliot.pkg` model, interpret and render | done |
| `Version` | tag parsing, numeric ordering, compatibility lines | done |
| `PackageId` | canonical URL identity, `//module` selector | done |
| `Resolution` | MVS per configuration, identity by URL then lineage | done, source is an effect |
| `Git` | the git operations, and the reading of what git says back | done |
| `Cache` | bare mirrors per package; tags, anchors, descriptors out of them | done |
| `PackageSource` | the resolver's two questions, and the git-backed answer to them | done |
| `Launcher` | the `main`, the composition, the failure channels | one verb: `eliot resolve` |
| `Command` | what a command line asks for, what a resolution reads as | done for that verb |
| — | lockfile, source assembly, the rest of the verb set, wrapper | not started |

**There is a tool now, and there is a package to point it at.** `eliot resolve <configuration>` reads
the descriptor where the user is standing, closes that configuration over the graph and prints what was
selected, cloning and reading mirrors on the way. As of 2026-09-13 it does that against a *published*
package: the eliot repository carries a root `eliot.pkg` and a `v0.0` release, and a consumer declaring
`dep github.com/robertbraeutigam/eliot//stdlib v0.0` gets the mirror fetched from GitHub, the descriptor
read out of the object database at that tag, and `github.com/robertbraeutigam/eliot v0.0` selected once
for both module selectors — modules of one repository version together, which is now a fact about a
remote rather than about a table in a test. That is one verb of a fixed set, and it is the boring one — but it is what makes
everything above it real: the launcher's `main` is the only place the platform's `Process` and
`FileSystem` are resolved at all, so until it existed the modules beneath it compiled green without
anybody knowing whether they ran (`docs/effectful-modules.md` §14).

What is still missing is the rest of a *build*. Nothing records what it resolved, so there is no
lockfile; nothing materialises the selected versions, so no source root reaches the compiler — and that
is the deferred problem below (`git worktree` against a checkout against `git archive`), now the next
thing in the way rather than a question for later. The compat-check verb, the plugin-jar closure and
the project-model query are unstarted.

## The core decision: a descriptor, not build-as-code

The build is described by an **inert data descriptor** at the repo root plus a **fixed verb set**
(`eliot build/run/test …`), Maven-model; it is *not* a program (Gradle/sbt/Mill-style). The
build-as-code trend is a polyglot-tool phenomenon — a general-purpose tool cannot assume a build
model, so it must let users program one. A language-owned tool *defines* the build model, and the
language-owned tools that took this route (Cargo, Go) are the ones their users praise. Rationale:

- **Same verbs on every project.** A build you have never seen is operable and readable.
- **Tools read data without executing it.** A mirror, a future `eliot migrate`, a syntax
  highlighter all parse the descriptor directly — its *literal content* is available to anyone
  without a build-tool daemon and without evaluating anything (contrast Gradle sync). Mechanical
  ecosystem-wide format migrations stay possible. The **resolved** project model is a different
  question with a single answerer — see the IDE section.
- **Opening a project runs no project code.** Reproducibility and supply-chain hygiene by
  construction: whatever a tool executes is fixed, pinned tooling, never something the repo
  supplied.
- **Eliot needs less build tool than almost any language.** The compiler already is the build
  engine (demand-driven facts, plugin backends, whole-program compilation from `main`, layer
  assembly via paths). The build tool reduces to: resolve dependencies → assemble roots →
  invoke compiler per configuration → package. Source generation — the classic pressure toward
  build scripts — already has a better home: compiler plugins contribute `SourceMount`s.

Maven's actual failure modes are designed out, not in: plugin configuration is schema-validated
(never stringly-typed blobs), there is no parent-descriptor inheritance and no profiles, and the
escape hatch is scoped Cargo-style — plugins extend *inside* the standard model and can never
redefine verbs or the meaning of the descriptor.

There is no `upload` verb. What "upload" means is what *run* means on that platform: on jvm,
`eliot run` is `java -jar`; on an MCU it is flash + reset + monitor. The verb set stays fixed and
platform-neutral; the platform's backend plugin supplies the meaning of `run` (and `test` —
hardware-in-the-loop later). Precedent: embedded Rust never got `cargo flash`; it got
`runner = probe-rs` under an unchanged `cargo run`.

## Distribution: git-native

A **package is a git repo with the descriptor at its root**. There is no registry and no publish
step — pushing is publishing. This fits Eliot unusually well: whole-program compilation means
there is no intermediate representation and no binary artifact to host — a package *is* its
source tree, and git is already the world's content-addressed source store. Local development is
symmetric: a dependency is a URL or a filesystem path.

### Identity

**The URL is the package identity.** There is no separate name — a name would need a central
place to live, which is the registry we are avoiding (Go ran URL-as-identity at scale). What
follows:

- **The URL decides, and the lineage confirms when the URLs differ.** Canonical form first
  (lowercase host, strip `.git`, one scheme, no trailing slash): it settles the common case with no
  network, and it is what keys the cache and the tool's own output. But canonicalization is not
  where correctness lives, because a URL is exactly the thing that does not survive a rename, an org
  transfer, a host migration, or a local checkout standing in for a remote. **Two dependencies are
  the same package when their canonical URLs match *or* when their `vM.0` tags name the same
  commit.** Git is content-addressed, so the anchor costs nothing: the resolver already runs
  `git ls-remote` per package for version discovery, and the first release tag of a compatibility
  line is immutable, carried by every mirror and every fork, and *per-major* — precisely the
  granularity of the append-only contract that the identity question is really about. Whether the
  two histories diverged after `v1.0` is irrelevant: they are the same line. Swift's failure mode
  (spelling variants resolving one package twice, colliding at the FQN merge with a baffling error
  far from the cause) is defanged — a variant the canonicalizer misses still unifies on the anchor.
- **A match proves sameness; a mismatch proves nothing.** Re-tagged history exists, so the test is
  "there is a tag name present in both whose peeled commits agree" — `vM.0` is merely the first one
  to try. Where no such anchor exists (a line whose history was migrated and starts at `v1.3`), the
  rule degrades to URL equality, which is where it started: strictly additive, offline included.
- **Unifying identity is not trusting either source.** Once two URLs are one dependency, MVS takes
  the maximum of the declared minimums — and across genuinely diverged forks, one line's `v1.6` need
  not contain the other's `v1.5`, so the winner can silently lack what somebody required. The same
  gap is an escalation path: anything in the graph could declare a URL carrying the real `v1.0` plus
  a high tag and thereby supplant a package everyone else names by its official URL. One rule closes
  both — **fetch from the root-preferred URL, and require the selected version's commit to be a
  descendant of every other candidate's.** Where it is not, the lines have truly diverged and that is
  a resolver error naming both URLs, never a silent pick. The ancestry check needs the objects, so it
  happens at fetch, after the cheap anchor test has already settled identity.
- **No package-level namespace claim.** An ownership rule ("only this package defines
  `com.acme.*`") was considered and **rejected**: layers *deliberately* redefine names they do
  not own — that is the platform-implementation mechanism. The compiler's merge already enforces
  what matters (at most one implementation, signatures agree, used ⇒ exists). The build tool's
  contribution is **attribution**: merge errors name the packages (URL + version + module) that
  contributed each colliding definition. Accepted residual: two strangers defining the same name
  with a lexically identical signature silently merge — rare enough to live with; an advisory
  warning can be added later with no descriptor change.

### Versions: branches are compatibility lines, tags are versions

- A **major version is a branch** (`v1`, `v2`): an append-only compatibility contract. Breaking
  changes start a new branch. `git ls-remote` on the branch is update discovery — no registry API.
- **Versions are annotated tags on the branch** (`v1.4`, `v1.5`). The resolver selects tags,
  never branch heads: a moving head names different code on different days, has no
  human-readable version, and gives MVS nothing to order. A commit must be tagged to be
  consumable (no Go-style pseudo-versions).
- **`v0` is the line that promises nothing.** The append-only contract is what a line *is*, so a
  package whose signatures are still moving needs somewhere to be that does not claim otherwise:
  line 0, by the same mechanics as any other (branch `v0`, tags `v0.0`, `v0.1`, and `v0.0`'s commit
  as the lineage anchor) and with the guarantee explicitly suspended. Nothing in the resolver treats
  it specially — MVS does not care which line it is selecting on — so this is a convention, and the
  only one the format needs: the eliot repository itself is on it (`v0.0`, 2026-09-13), and moving to
  `v1` is the ordinary act of starting a branch, done when the base stops changing shape and
  `compat-check` exists to keep the promise.
- **The guarantee has teeth**: `eliot compat-check` diffs exported signatures between the branch
  head and a candidate tag and refuses removals/changes (Elm precedent: computed, not promised).
  Caveat, accepted: use-site verification means a dependency's *body* change can surface new
  obligations at a consumer's call sites under an unchanged signature. This is safe because
  upgrades are explicit (lockfile): latent breakage appears only when the user opts into an
  upgrade, as an ordinary type error at a visible moment — never as silent drift.
- **This guarantee is load-bearing for the layer ecosystem.** The abstract↔concrete merge is
  lexically exact, so a third-party platform layer built against `foo v1.4` still merges when MVS
  selects `foo v1.6` — *only because* signatures are append-only within the branch. Git
  versioning and cross-repo layers are one design, not two features.

### Resolution: Minimal Version Selection

Go's MVS, adopted as-is: a dependency declaration is a **minimum** (never a range, never an upper
bound); resolution takes the transitive closure and picks, per package, the **maximum of the
declared minimums** — the oldest version satisfying everyone. Deterministic without a lockfile,
no silent upgrades (publishing changes nobody's build; only raising a minimum does), no solver.
Ancestry on a release branch gives the version ordering almost for free.

**One major per package per program** (v1 rule): two majors of one package would collide at the
FQN merge, so conflicting-major requirements are a resolver error. Known deferred problem —
Go added coexistence (module/v2 = distinct identity) because ecosystem-wide major migrations are
brutal without it; revisit when it hurts.

### Lockfile

Descriptor = intent ("`foo >= v1.3`"); lockfile = fact. Per resolved dependency: **tag + commit
hash + a content hash of the source tree** (the go.sum lesson: the commit hash pins history; the
content hash detects a rewritten or substituted remote). Since resolution is per build
configuration (below), the lock records **per-configuration resolutions**. With MVS the lock is
nearly redundant for resolution; it survives as the integrity record.

### Location drift and availability — registry-free indirection

Identity answers "same package?"; it does not keep repos findable or alive. Two mechanisms,
neither central:

1. **Mirrors as resolver configuration** (consumer-controlled), never descriptor content. Git is
   content-addressed — a commit hash is a Merkle root — so once the lock pins a hash, *any*
   remote can serve the bytes trustlessly. The design obligation is only negative: do not bake
   "fetch only from the identity URL" into the resolver. A proxy/cache can be run later with zero
   protocol change; the left-pad endgame (immutable proxy + checksum transparency log) stays
   available if the ecosystem ever needs it.
2. **Vanity URLs** (author-controlled, deferrable): identity under a domain the author owns, an
   HTTP response pointing at the current git remote. DNS is the decentralized registry.

**A root-only `replace` clause was specified and then cut** (2026-08-06), before anything read it.
The anchor rule had already taken its first job: a package named by two spellings — the old URL and
the new one after a move, a mirror, a local checkout — no longer *collides*, it unifies, so nothing
needs redirecting to prevent a duplicate. Availability is mechanism 1 above, which is consumer
configuration by design. What remained was the local-development story, and that argues against a
descriptor clause on this design's own terms: which checkout stands in for a dependency is an
*environment* property, not a project property — the same rule that keeps mirrors out of the
descriptor and the repo URL out of the wrapper's pin file. Go is the cautionary precedent rather than
the model here: `replace` had to be confined to the root to limit the damage, and `go.work` was
introduced later precisely to move local-development redirection back out of the committed manifest.
Substituting genuinely *different* content for a transitive dependency — a fork carrying a fix
upstream has not released — is the one job left with no other home, and it cannot arise before there
is an ecosystem of packages one does not control. Reintroducing the clause then costs nothing:
unknown-clause-is-fatal makes it purely additive, and only a descriptor that uses it needs the newer
launcher.

## The descriptor

Contents test: **does the resolver or compiler act on it?** Human-facing prose lives in the
README (rendered from git, the Go move); legal text in LICENSE. Deliberately absent: package
name (identity is the URL), the package's own version (the tag carries it — no bump-commit
ritual, no file/tag disagreement), authors, description, and a toolchain-version directive
(the toolchain is a dependency — see below).

What remains:

- **Dependencies**: URL (+ optional module selector into that repo) + minimum version. Scoped:
  base, per-module, test, per-configuration.
- **Modules**: the repo's build modules (the eliot repo itself: `lang`, `stdlib`, `jvm`). Per
  module: name, export flag (dependents mount every exported module's sources; examples/apps/test
  fixtures are internal), its own dependency list, and where it is. Directories by convention — the
  module's own name — with one clause to say otherwise (`at`, below).
  **One root descriptor** — per-module descriptor files reintroduce Maven's parent-POM web and
  Go's nested-modules mess, and break the one-parse LSP story.
- **Build configurations** (see below): name, additional dependencies, backend-plugin invocation
  + parameters (main module, artifact kind, output).
- **Plugin binaries** (Maven coordinates — transitional, see below), only in packages that ship
  compiler plugins.

The load-bearing property of the format: **inert data, parseable without the compiler**.
Types-are-values will tempt an Eliot-expression descriptor; resist — that is build-as-code
through the back door, re-coupling every tool to the evaluator.

## Descriptor syntax: `eliot.pkg`

A **custom line-oriented format**, not a general-purpose one (TOML/JSON/YAML):

- **The tool edits the file.** MVS workflows (`eliot get`-style commands raising minimums,
  adding dep lines) machine-edit it, and it lives in git — one clause per line survives
  programmatic edits, diffs, and three-way merges. Nested TOML tables do neither well.
- **The domain is small enough to own.** Seven-ish clause kinds; a tiny grammar makes illegal
  states unrepresentable instead of validating a generic tree after parsing. go.mod proved the
  approach (and is the most readable manifest in the industry for it).
- **It should feel like Eliot** — `--` comments, lowercase keywords, the language's restraint.
  This is still inert data: "parseable without the compiler" is about *no evaluation* and a
  trivially specified grammar, not about borrowing someone else's format. The spec plus the
  resolver library are the reference parser; a TextMate grammar ships in `ide/textmate/`.

Files: **`eliot.pkg`** (repo root) and **`eliot.lock`** (tool-written) — naming consistent with
the `eliot.paths` precedent this system retires.

### Invariants — the format teaches the model

1. **No version operators exist.** Every version token is a minimum (MVS), spelled exactly as
   the git tag (`v1.2`). There is no `>=` to write and no range to express — the syntax cannot
   state what the resolver doesn't do. The one exact pin in the system (plugin jars) rides
   inside the Maven coordinate string, which is exact by nature; the invariant holds without
   exception.
2. **Dependency URLs are scheme-less** (`github.com/x/foo`) — normalization by construction (no
   `https://` vs `ssh://` spellings to unify; transports are resolver config), and it frees `//`
   unambiguously as the **module selector**: `github.com/eliot-lang/eliot//stdlib`. A bare
   `//name` is a sibling module of this repo.
3. **Comments are `--`**, like the language.
4. A file is a sequence of clauses — `keyword args…`, optionally followed by a `{ … }` block of
   sub-clauses. That is the whole grammar. **Unknown clauses are fatal** with an upgrade hint
   ("this descriptor needs a newer eliot") — this is how the format evolves without a
   format-version field (see the toolchain section).

### Clause reference

```
dep github.com/x/foo v1.3                    -- base dep: all exported modules of that repo
dep github.com/eliot-lang/eliot//stdlib v1.2 -- module-selected dep

module lang {                                -- multi-module repos only
  at lang/eliot                              -- where it is (default: the module's name)
  internal                                   -- not exported (default: exported)
  dep //other-module                         -- intra-repo sibling
  dep github.com/x/bar v2                    -- module-scoped dep
  plugin com.vanillasource:eliot-lang:0.5.0 { -- ships a compiler plugin (Maven coord, exact)
    jar org.ow2.asm:asm:9.9 sha256 9f2c…     -- flat transitive closure, author-computed
  }
}

test {                                       -- test scope (also allowed inside module)
  dep github.com/eliot-lang/eliot-test v1
  dep github.com/eliot-lang/eliot//jvm v1    -- the host-runnable platform layer
}

artifact hello {                             -- a build configuration
  dep github.com/eliot-lang/eliot//jvm v1    -- platform layers live HERE, per artifact
  backend {                                  -- params schema-validated by the plugin
    kind exe-jar
    main HelloWorld
  }
}
```

- `backend` names no platform: the backend is located among the artifact's deps (the packages
  declaring `plugin`). With exactly one candidate no URL is needed; with several, disambiguate:
  `backend github.com/…//jvm { … }`. Its parameters are free-form keys validated against the
  plugin's declared schema — the typed-plugin-config promise, enforced at parse time.
- **No `module` clause** = the repo is one anonymous exported module with `src/`, `test/`,
  `compiler/` at the root — the zero-config common case.
- `at` is the module's directory, relative to the repo root, and defaults to the module's **name** —
  so a package laid out flat writes none, and the tool never invents a second way to spell the common
  case (a directory equal to the name is written back out as nothing). It buys one thing: the module's
  *name is not its path*. Names are half of package identity in a registry-less design (`URL//name`),
  so a repo that rearranges itself would otherwise be breaking every dependent's descriptor — silently,
  since `compat-check` diffs exported signatures and cannot see a layout. The concrete case is the
  eliot repo, which is permanently polyglot (the compiler is Scala and owns `lang/src`), so its layers
  sit at `lang/eliot/`, `stdlib/eliot/`, `jvm/eliot/` and are still selected as `//lang`, `//stdlib`,
  `//jvm`. A path inside the repo, and nothing else: an absolute path or a `..` segment is refused,
  since the descriptor is fetched from a remote and source assembly resolves this against a checkout.
- `plugin` carries the plugin's **full flat jar closure** as `jar` sub-clauses (exact coordinate
  + SHA-256), computed by the author at release time — the consumer's launcher fetches and
  verifies without ever resolving a POM (see the plugin-binaries section).
- Modules of one repo version together (tags are repo-wide): selector lines into the same repo
  at different minimums simply both feed MVS. Per-module versioning does not exist.

### Examples

A minimal library — fully explicit, satisfying the "src resolves against declared deps alone"
lint literally (nothing ambient, including the language itself):

```
dep github.com/eliot-lang/eliot//stdlib v1
dep github.com/somelib/collections v1.3
```

An application targeting two platforms:

```
dep github.com/somelib/sensor-api v2

artifact controller-jvm {
  dep github.com/eliot-lang/eliot//jvm v1
  dep github.com/somelib/sensor-api-jvm v2
  backend { kind exe-jar, main Controller }
}

artifact controller-attiny {
  dep github.com/vendor/eliot-avr v1
  dep github.com/somelib/sensor-api-avr v2
  backend { kind flash-image, main Controller, mcu attiny85 }
}
```

The dogfood — the eliot repo itself: `module lang { plugin … }`, `module stdlib { dep //lang }`,
`module jvm { dep //stdlib, plugin … }`, `module examples { internal, dep //jvm }`.

The lockfile uses the same clause style, machine-written: `lock <url> <tag> <commit>
<tree-hash>` per resolved dependency per artifact, `lock-jar <coord> <sha256>` for plugin
binaries. Its exact format is tool-owned output, not hand-polished here.

## Standard layout: one base plus conditional overlays

Per module, three conventional directories — under the module's own directory, which is its name
unless its `at` clause says otherwise. Only `src/` is mandatory. Libraries and layers are
**not differentiated** — layer-ness is not declared anywhere; it is just what your sources do
(even a pure-`src` package can concretely re-declare foreign abstract names).

| dir | active | runtime pool | compiler pool | exported |
|---|---|---|---|---|
| `src/` | always | yes | yes (borrowed) | per module flag |
| `compiler/` | always | no | yes, as **override** files | **yes** |
| `test/` | test verb only | yes | yes (borrowed) | **no** |

Each conventional name encodes a fixed answer to three orthogonal questions — when it activates,
which pools it mounts into *and how*, whether it ships to dependents. This is why the tracks
cannot be anonymous mill-style submodules: mounting mode is semantic information the tool must
know, and the name is what carries it. Note the two cells that are easy to get wrong: `compiler/`
**is exported** (a downstream program's checking needs your compile-time instances, exactly as
stdlib's overlay serves every program today), and `test/` joins both pools while testing yet
never ships — export is orthogonal to pool membership.

**The compiler–src borrow is kept, necessarily.** In Eliot any ordinary definition can appear in
a type-level position, so the NbE checker routinely evaluates user `src` code; severing the
borrow would break type-level use of your own definitions and force hand-copying every pure body
into `compiler/`. The native-leaf boundary is the existing fail-safe (a borrowed body reaching a
platform leaf stalls loudly, never misevaluates). `compiler/` therefore holds only what it holds
today as `eliot-compiler/`: self-sufficient redefinitions, checking-only instances, compile-time
natives.

**The compiler platform is the one special case** — the only platform *every* build activates,
on every consumer's machine, for every target. So its layer cannot be an opt-in dependency: it
travels with every package unconditionally (the conventional directory), and a library whose
compile track is not self-sufficient is broken for everyone. Two lints the tool owes at the
*author's* build, not some consumer's:

- `src` must resolve against declared dependencies alone;
- the compile track (`src` + `compiler/` across the dependency closure) must resolve **with no
  runtime platform layer present** — the existing self-sufficiency rule, machine-checked at the
  package boundary.

## Platforms: dependencies + a backend call, not a target vocabulary

There is **no "platform" or "target" concept in the descriptor**. A build configuration is:
additional dependencies + a compiler-plugin (backend) invocation + parameters. Platform is
*emergent* from which layer packages the configuration depends on and which backend it calls —
and those arrive together: the jvm package ships both the layer sources and `JvmPlugin` in one
unit today. The backend is identified by the package that ships it, and package identity is
already the URL — no platform-name namespace exists to govern.

- **Per-configuration dependency scoping is load-bearing, not organizational.** Flat-listing
  `eliot-jvm` and `eliot-avr` together would mount both layers into one resolution and the merge
  would correctly explode with "has multiple implementations" on every stdlib name. The
  configuration is the unit of resolution (and of the lockfile). Multi-platform = multiple
  configurations sharing the base, built independently.
- **No discovery, by design.** "Find the platform components" would need the registry we
  rejected. The user names their platform dependencies per configuration (the Cargo
  `[target.'cfg'.dependencies]` shape); the resolver follows declarations. What replaces search
  is a **diagnostic**: after resolving a configuration, every abstract name with no concrete
  provider is reported with attribution — "this configuration is missing a layer implementing
  `foo`'s 14 abstract values" — instead of a deep per-call-site failure.
- **Platform implementations are ordinary packages.** The author can keep one as a module of the
  library's own repo (co-versioned — this is why sub-module dependencies exist) or anyone else
  can ship one from an unrelated repo: layer redefinition has no orphan rule; the global
  at-most-one-implementation check keeps it coherent. Third-party layers stay viable across the
  base library's minor upgrades precisely because of branch compat-checking (above).
- **Test is a configuration** whose backend must be executable on the build host, plus the
  test-scope dependencies (framework + a runnable platform layer — jvm today). "The build system
  chooses" means: run the test configurations whose backend can execute here. It cannot conjure
  platform implementations nobody declared. On-target testing later = a platform plugin making an
  MCU configuration "executable" through the same delegated `test`/`run` verbs.

## Compiler plugins: Maven coordinates (transitional)

Plugins (backends, native contributors) are JVM binaries until the compiler is self-hosted, so a
plugin-shipping package's descriptor names its plugin as **exact-pinned Maven coordinates**. This
is a confined pragmatism, not a model change:

- **Identity/location split, again**: the package's identity stays the git URL; the coordinate is
  merely the *location of a binary* the descriptor at that tag points to. Ordinary users never
  write Maven coordinates; plugin loading flows transparently through the dependency graph.
- **Why not jars-in-git**: no dependency metadata — `JvmPlugin` needs ASM, and bare jars force
  fat/shaded jars, which this project already knows break plugin loading (`META-INF/services`
  collapse; `package.sh` exists to enforce per-module jars). Maven's POM metadata is what makes
  the transitive closure computable at all; separate jars on a classpath are the discipline
  already required. Building plugins from source collapses into the same thing plus an embedded
  Scala build.
- **Resolution happens author-side, at release time — never in the build path.** The
  plugin-shipping package's descriptor lists the plugin's **full flat jar closure**: exact
  coordinate + SHA-256 per jar (`jar` sub-clauses of `plugin`), computed once by the author
  (shelling to coursier is fine transitionally; plugin authors have dev environments). The
  consumer's launcher never walks a POM: it unions the flat lists across plugin-shipping deps,
  conflict-checks, fetches deterministic URLs, verifies hashes. Same philosophy as the rest of
  the design — resolve at author/lock time, fetch at build time — and it keeps the launcher's
  Maven story as dumb as the wrapper's (load-bearing for the Eliot-written launcher, below).
- **Exact pins, not minimums** — plugin jars are toolchain components, outside MVS. The lockfile
  additionally records the jar hashes (`lock-jar`), one integrity record for everything. Maven
  Central's immutability plus hash-locking covers availability and trust; mirrors are resolver
  config, same shape as git mirrors.
- **v1 conflict policy**: union all plugins' flat closures; surface version conflicts as errors.
  Per-plugin classloader isolation stays in the back pocket, not built speculatively.
- **Marked transitional**: when the compiler is self-hosted, plugins become Eliot source in
  ordinary git packages and this clause retires.

## The toolchain is a dependency

There is **no toolchain-version directive** (`eliot >= 0.x` was considered and dropped). Go and
Cargo carry one (`go 1.21`, `rust-version`) because their toolchain is *ambient* — installed
out-of-band, so the manifest can only document a constraint against something it doesn't
control. Here the toolchain is a package like any other: the eliot repo's modules ship the base
layers as sources and the compiler binaries as exact-pinned `plugin` coordinates. The dependency
line does everything the directive pretended to:

- `dep github.com/eliot-lang/eliot//stdlib v1.5` states the requirement; MVS unifies it across
  the graph; the lockfile pins the outcome — sources *and* compiler jars, since the selected
  tag's descriptor pins its own plugin coordinates. Base sources and compiler binaries cannot
  skew.
- The failure the directive guarded ("package built for a newer compiler dies with parse
  errors") **self-heals** instead: a dependency requiring eliot v1.5 raises the minimum, the
  launcher fetches the v1.5 compiler jars, and the right compiler compiles it. There is no
  "installed compiler" to be too old — only a resolved one.

### Bootstrap: wrapper → pin → launcher

Something must parse the descriptor and run the resolver before any resolution exists. The
split: a dumb committed wrapper pins the launcher; everything smart rides the dependency graph
(lang compiler, backends, base layers — exact-pinned via the lockfile). The launcher is only:
descriptor parser + resolver + artifact fetcher + classpath assembler + verb dispatch — boring
by design, changing rarely.

**The wrapper script is version-free and byte-identical in every repo** — all variance lives in
the pin file, so "grab the script from anywhere" is literally true. No hardcoded fallback
version: a baked-in default drifts, and "no pin → latest" silently breaks reproducibility. The
pin file is required; the script errors helpfully without it (`eliot init` writes both). The
script's whole job: find a JRE (`JAVA_HOME`/PATH, clear error if absent — JRE *provisioning* is
a later nicety, not v1), read the pin, check the local cache, download on miss, verify,
`exec java -jar launcher.jar "$@"`.

**The pin file** (`.eliot-version`, mill's pattern) is a third file, distinct from `eliot.lock`
— the lockfile is tool output, per-configuration, and does not exist before the first resolve.
It is one line:

```
v0.6.2
```

optionally followed by `sha256 <hex>`. No Maven coordinates: the launcher's group:artifact is
fixed forever, and Maven repo URLs are deterministic
(`<repo>/<group-path>/<artifact>/<ver>/<artifact>-<ver>.jar`), so the script constructs the URL
by string concatenation and fetches — no POM logic in shell. **No repo line either**: where to
fetch from is an *environment* property, not a project property (the same repo builds inside
and outside a firewall) — the wrapper honors an env-var mirror override, per the design's rule
that mirrors are consumer config, never committed content. The optional hash (Gradle's
`distributionSha256Sum` precedent; the wrapper checks with `sha256sum -c` before executing) is
near-redundant for the default HTTPS-from-Central fetch, but earns its keep exactly when the
env var redirects to unvetted infrastructure: the launcher is the root of trust, executing
before any verification machinery exists, and a committed, reviewed hash is what a poisoned
mirror cannot substitute past. The committed side pins *what*; the environment chooses *where
from*.

**The launcher is a single self-contained jar, written in Eliot.** The jvm backend's `exe-jar`
output is already exactly that artifact shape, so self-hosting the build tool and satisfying the
dumb-script constraint are the same act. No fat-jar/ServiceLoader hazard: that gotcha is about
collapsing *compiler-plugin* jars, which stay separate (fetched later, by the launcher);
generated Eliot bytecode carries no `META-INF/services` files to collapse. The bootstrap chain
is the standard compiler one: launcher v0 is built by mill and published; thereafter launcher
vN−1 builds launcher vN.

What the Eliot-written launcher demands is a set of jvm-layer effects/natives, and that was a
feature rather than an obstacle: the build tool is the forcing function for the effect system and
stdlib the way `namedValues` was for reflection — a real, fully effectful program we control. It
worked. `eliot.file.File`/`Path`, `eliot.system.Process` and `eliot.system.Environment` all exist
now, and `eliot.build.git.Cache` is a real `{Process, FileSystem}` program running against real
repositories — so "can the launcher be written in Eliot at all" is answered rather than assumed.
HTTP GET and sha256 are still absent and are the remaining two: both are reachable by shelling out
(`curl`, `sha256sum`) if they stay absent, at the cost of one more thing that must be installed.
Process spawn is the load-bearing
capability: the launcher **shells out to `git`** (Go's original choice; no embedded git
library) and **spawns the compiler as a second `java` process** with the assembled classpath —
dynamic jar loading from Eliot would need a bespoke native, while spawn is needed for git
anyway and keeps the compiler's classpath isolated from the launcher's.

**The full sequence**: script finds JRE → reads pin → fetches/caches/verifies launcher jar →
execs it. Launcher parses `eliot.pkg` (+ `eliot.lock` if present) → MVS over git tags (shelling
`git ls-remote`/`fetch`, verifying content hashes) → unions the plugin jar
closures (the flat lists above), fetches deterministic URLs, verifies hashes → assembles the compiler
classpath as separate jars → spawns the compiler per artifact → the backend emits. Stated
honestly: a JVM is required to *build* on every platform, MCU projects included, until a native
backend can one day emit a native launcher — a transitional cost already accepted by hosting
plugins on the JVM.

Two consequences:

1. **The language falls under the branch-compat contract.** As an ordinary MVS'd dependency, a
   minor tag on the eliot repo's v1 branch must be backward compatible — language and
   base-library evolution within a major is non-breaking, machine-checked by the same
   `compat-check` as everyone else's; a breaking language change is a new major branch.
2. **Descriptor-format evolution** is the one residual the directive used to cover (go.mod's
   `go` line also gates format features): handled by unknown-clause-is-fatal-with-hint, and a
   repo adopting a new clause commits the wrapper/launcher version that understands it —
   self-consistent by construction.

## IDE integration: a project-model query, not BSP

BSP assumes the build server compiles and streams diagnostics — the opposite of the Eliot LSP,
which embeds the compiler in-process (live VFS overlay, unsaved-buffer diagnostics). BSP solves
cross-vendor interop we do not have. The shape is rust-analyzer/gopls: **the LSP spawns the build
tool and asks it one question** — the **resolved project model** (runtime roots,
compiler-overlay roots, dependency checkout paths, configurations) — answered as JSON on stdout
by a machine-facing verb, `eliot project-model` (`cargo metadata`, `go list -json`). This retires
the `eliot.paths` stopgap.

**The descriptor and the project model are different artifacts, and only the second has a single
answerer.** Parsing `eliot.pkg` is the easy half and stays open to everyone (above); the project
model is the descriptor *plus* MVS over the transitive closure, mirror configuration, lockfile
pins, per-configuration scoping and cache checkout paths. A second implementation of that inside
the LSP would drift from the first, and the drift is the worst kind: the IDE reports diagnostics
against a different set of roots than the build compiles, with nothing in either output naming
the discrepancy. One resolver, one answer.

Consequences worth stating:

- **No linked-library option.** The launcher is written in Eliot (see the bootstrap section), so
  there is no shared Scala codebase for the LSP to link a resolver from — a jar of generated
  Eliot bytecode whose entry point is an effectful `main` is not a Scala-callable library. Process
  spawn is the only viable mechanism, and it is what the cited precedents do anyway.
- **The no-code-execution cornerstone is untouched.** Spawning the build tool executes a fixed,
  version-pinned, reviewed binary — the one the wrapper's pin file already selects. Gradle sync
  is a different thing entirely: it *evaluates a program the repo supplied*. The property was
  never about who does the parsing.
- **The query must answer offline and degraded.** Opening a project whose dependencies are not
  yet fetched must yield the model that is knowable — resolved where the lockfile and cache
  suffice, explicitly marked incomplete elsewhere — never block IDE startup on a network fetch
  (`cargo metadata --offline`). Fetching is a verb the user invokes, not a side effect of opening
  an editor.
- **Shared-state care shrinks to nothing.** Since the LSP never touches the download cache
  itself, only the build tool does, the CLI-vs-LSP race disappears in favour of the tool's own
  lock. The LSP watches `eliot.pkg`/`eliot.lock` and re-queries on change.
- **Transitional**: until the LSP learns the query, the build tool can *emit* `eliot.paths` as
  generated output. That is strictly better than today's hand-maintained file, which silently
  drifts from the CLI invocation it is supposed to mirror, and it deletes cleanly.

## Lessons from building it

Things the implementation taught that the design did not know, kept here because each one shapes
what is left to write rather than only what is written.

- **The pure/effectful boundary is chosen, and the test brings the carrier.** This entry used to read
  the opposite way, and the correction is worth keeping whole because the wrong version shaped four
  modules. A test case body is pinned to `{Throw[AssertionError] | Id}` and may only assert, from
  which it seemed to follow that nothing effectful is reachable from a suite, so every module
  touching the outside had to split into decisions on the pure side and an untested shell next door.
  The premise is still true; the conclusion never followed. Production code that declares an effect
  row *names no carrier*, so a test can declare its own — an ordinary `data` with an `Effect`
  instance and one instance per effect in the row — and instantiate the production code at it. Two
  compiler fixes were what made that reach the standard effects (`docs/testing-effects.md`), and
  since them a `{Process, FileSystem}` module is testable as it is. So `Git` performs git,
  `Cache` decides caching, and the split the lockfile and the assembler were going to inherit is
  cancelled. The one shape it costs: a run must sit outside the pinned body, so a test is
  run-then-assert rather than a script. See `docs/effectful-modules.md`.
- **A module is only checked if `main` reaches it, and a fake carrier does not count.** Checking is
  whole-program from `main`, and ability resolution happens at monomorphization — so an effectful
  module nothing calls compiles green while its `Process`/`FileSystem` instances are never resolved
  at all. `Cache` was in that state and looked finished. The subtler version of the same fact
  survives the entry above: running production code on a test's carrier resolves `Process[Fake]`,
  never `Process[IO]`, so a green suite is evidence about the logic and no evidence that the logic has
  an interpretation on the platform. Until the launcher has its own `main`, a `probe/` source root
  carries one and must reach every effectful module deliberately; when the launcher exists, that *is*
  the verification mechanism. **It exists** (2026-09-13), and it is: the platform's `Process` and
  `FileSystem` are resolved from `eliot.build.Launcher`'s `main` or from nowhere, so a change under
  `git/` or `resolve/` is verified by compiling and running the launcher, never by a green suite.
- **An effect crosses a module boundary as an ability once something can interpret it.** This also
  used to read the other way — a swappable package source had to be a callback with a row in the
  arrow codomain (`PackageId => Version => {Effect} Option[Descriptor]`), because an ability method
  that declares a row *is* an effect and an effect with no carrier and no handler can never be
  discharged. What was missing was the handler, and a test carrier is one: `PackageSource` is now an
  ability, `Resolution` names no source at all, and 22 parameter declarations of plumbing are gone
  from eleven functions. Nothing in the algorithm changed, exactly as predicted. Two rules came with
  it: the production instance must be a constrained catch-all in the ability's own module (the orphan
  rule allows nowhere else for an instance over an arbitrary carrier), and a test carrier must
  therefore implement the *minimum* — a fake that also satisfies those constraints makes the query
  ambiguous.
- **Failure wants more than one channel.** `IoError` (git could not be run) and `GitError` (git ran
  and said no) are different reports to a user and are kept apart, which costs a type-annotated
  `catch` per channel since two `Throw`s in one row cannot be told apart by inference. The launcher
  will carry four or five of these; the boundary that discharges them is the place to keep honest.
- **A relative path belongs to whoever is standing in a directory.** Shelling out means every path
  handed to git is resolved against git's working directory, not the tool's. Two bugs, one mistake:
  a clone launched from inside the cache root resolved `target/cache/…` a second time and buried the
  mirror at `target/cache/target/cache/…`. The rule that fell out — a command that *names* a
  repository by path runs where this program runs, one that operates on the repository it stands in
  runs in the mirror — is git's own split, and everything spawned later inherits the question.
- **Mirrors, not checkouts.** The cache holds bare repositories: a descriptor is read with
  `git show`, the ancestry check reads objects, and neither wants files on disk. This was not in the
  design and it creates one open question (below), but it makes resolution cost nothing on disk
  beyond history, and re-resolving a cached package is a local process at ~0.1s.

## Deferred / open problems

- **How resolved sources reach the compiler.** The cache deliberately has no working tree, and the
  compiler wants directories to mount as source roots — so something must materialise the selected
  version of each package. `git worktree add` per resolution is cheap and stays tied to the mirror;
  a plain checkout per (package, version) is simpler and duplicates; `git archive` into the cache
  sits between. Undecided, and it belongs with the assembly step rather than with the cache.
- **Major-version coexistence** in one program (resolver error today; Go-style identity split if
  ecosystem migrations ever demand it).
- **Availability endgame** — immutable proxy + checksum transparency log, only if the ecosystem
  outgrows lockfile-verified mirrors.
- **Plugin classpath isolation** — if the resolve-together policy bites.
- **On-target `run`/`test` mechanics** — the delegated-verb contract for MCU backends.
