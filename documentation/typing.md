# Owl Typing — syntax and semantics

Status: **design**. This refines the scratch sketch in `src/owl/typing.org` into a
full proposal: a Hindley–Milner style type system with inference and generics,
like OCaml's, laid over owl without disturbing its runtime grammar. The next
step after this design settles is a formalization in Lean (§ 11 sketches what
that needs).

Companions: [owl-examples.md](owl-examples.md) (the language as it runs today),
[reference-widgets.md](reference-widgets.md) (the signature tables the typed
layer will reuse).

- [0. Goals and non-goals](#0-goals-and-non-goals)
- [1. Three rules](#1-three-rules)
- [2. Types](#2-types)
- [3. Annotations](#3-annotations)
- [4. Definitions: `type`, `record`, `data`, `val`](#4-definitions-type-record-data-val)
- [5. Matching ADTs: `match`](#5-matching-adts-match)
- [6. Inference](#6-inference)
- [7. Typing the forms that already exist](#7-typing-the-forms-that-already-exist)
- [8. Libraries and `Dynamic`](#8-libraries-and-dynamic)
- [9. Errors](#9-errors)
- [10. Alternatives considered](#10-alternatives-considered)
- [11. Lean formalization plan](#11-lean-formalization-plan)
- [12. Open questions](#12-open-questions)

---

## 0. Goals and non-goals

**Goals.**

- Full HM: unification-based inference, parametric polymorphism, let-polymorphism.
  Annotations are optional — you write types where they document or disambiguate,
  the checker fills the rest (OCaml's ergonomics, not Haskell's mandatory signatures).
- **Typed records** and **sum types (ADTs)** with constructor syntax.
- Minimal footprint: *no new tokens* in the lexer, and *two small grammar
  extensions* to the reader (§ 3) that only turn today's parse **errors** into
  legal programs. Nothing that parses and runs today breaks, and nothing that
  runs today re-parses differently.
- Every new form (`type`, `record`, `data`, `val`, `match`) is an ordinary owl
  **command** — read as syntax, rewritten or checked — in the same family as
  `widget`, `emits` and `define-event`. No new evaluation semantics.
- Checkable per module, so `gui.owl` and the examples keep running untouched.
- Formalizable: the type grammar, the typing rules and the algorithm are
  written here so they can be mirrored in Lean almost line for line (§ 11).

**Non-goals.**

- Not a gradual typed-by-default language: there is no subtyping, no
  overloading-by-signature, no row polymorphism, no effect system. The one
  escape hatch (`Dynamic`, § 8) is a bridge to untyped code, not a feature.
- No change to how programs run. Types are a static layer over the existing
  evaluator; the runtime objects (`objects.nim`) are untouched in the first pass.
- Kind system beyond arity: type constructors are applied to exactly as many
  arguments as they declare, that is the whole of kinds.

---

## 1. Three rules

The entire design stands on three conventions owl already follows:

1. **Application is juxtaposition.** `f x y` calls `f`; a parenthesized group
   `(f x y)` is the same call as a value; `[] a b` and `{}` carry the same
   shape. *Type expressions reuse exactly this grammar*: `(List Number)` is a
   type the way `(button "ok" "OK")` is a call. No type-level syntax is added.

2. **Case discriminates.** Type constructor names and ADT constructor names
   start **uppercase** — as widget and event names already do (`Counter`,
   `Bumped`, `Pressed`). Everything at value level starts lowercase
   (`volume`, `tag-picks`, `fmt`). In a static position (a definition header,
   an annotation slot) an uppercase word is a type and a lowercase word is a
   type *variable*; there are no keywords inside types beyond `->` (§ 2).
   At call sites and in expressions nothing changes — bare words stay values.

3. **Definitions already read as data.** `command`/`fun`/`widget` bodies and
   parameters are lists of items the evaluator interprets; `emits Bumped by`
   parses as a call nobody evaluates. The new forms ride that rail: `record`,
   `data`, `match`, `val` are commands the *checker* interprets, so they cost
   zero reader syntax.

---

## 2. Types

### 2.1 Grammar

A type expression `T` is one of:

```
T ::= Number | String | Boolean | Unit      base types (capitalized words)
    | a b c ...                             type variables (lowercase words)
    | (T1 ... Tn)                           type constructor application (a group)
    | (-> T1 ... Tn Tr)                     function type (n ≥ 0 arguments,
                                            then the return; fixed arity)
```

That is all of it. In particular:

- `(List Number)`, `(Tree Number)`, `({} (w Number))` are applications of
  built-in or user-declared constructors — groups read like calls, per rule 1.
- `->` is an ordinary lowercase word with an official meaning in type
  position: `(-> Number Number)` is "a function from `Number` to `Number`";
  `(-> String Number Boolean)` is a two-argument function, arguments left,
  result right. With no arguments before the result, `(-> Tr)` is a **thunk
  type** — the zero-argument calls, `(theme)`, a `(view)` in `run-app`, an
  `&body` slot default. Application is **not curried** — owl's calling
  convention binds all parameters at once (`bindParams` in
  `evaluator.nim`), so a function of type `(-> a b c)` may only be applied
  to two arguments; deferring is a `lambda` (§ 7.3).
- There are no parentheses around variables and no apostrophes: `a`, `xs`,
  `elem` are type variables whenever they appear free in a definition's
  types (§ 6.1 quantifies them). A capitalized word that does not resolve to
  a declared or built-in constructor is an **error**, not a silent variable —
  that is the anti-typo half of rule 2.

### 2.2 Base types

They mirror the runtime kinds (`kindName` in `objects.nim`) one-for-one, so a
type error never blames the machine for something it cannot be:

| type      | values | notes |
|-----------|--------|-------|
| `Number`  | `1`, `2.5`, `-7` | the runtime's single `float64` kind; integers are numbers with no fractional part (no static `Int`, see § 12) |
| `String`  | `"milk, bread, coffee"` | no escapes, as today |
| `Boolean` | `true`, `false` | |
| `Unit`    | `nothing` | owl's "no value": the result of `set`, of a `when` without a value, of an empty body. `nothing` alone inhabits it |

Values of kind `symbol`, `pair`, `command`, `syntax`, `scope` have no type in
the core system (§ 7): symbols-as-values belong to untyped code (§ 8), pairs
are a *syntax* of calls, commands are what definitions build, syntax objects
are what `command` parameters receive (§ 7.3), scopes stay invisible.

### 2.3 Built-in type constructors

Two, and only two: `List` (1), and `{}` — the type of an anonymous record
literal, whose arguments are `(field Type)` groups (§ 4.2, § 7.5). The
record *constructor* and the record *type* share their head, exactly as the
literal `{}` shares its head with everything else in the grammar.

`Pair` is **not** built in — the pair `key = value` is call syntax, and any
real product type you want is a one-line `record`. This keeps the product of
types and the product of values from diverging. (`Optional` isn't built in
either; § 4.3 declares it the user way — but `nothing` has special sugar
against it, § 4.4.)

---

## 3. Annotations

An annotation is a type pinned to a name at the point the name is created.
Two grammar extensions, both backward-compatible:

### 3.1 R1 — annotated bindings: `name Type = value`

```owl
volume Number = 0.4
dark Boolean = true
name String = "notes"
```

A binding line may put exactly one type expression between the name and the
`=`. Today `x Number = 100` fails to parse ("a binding needs a name or a
grouped call on the left of '='"), so R1 only legalizes error programs. The
same shape also applies inside a group, giving default parameters their type:
`(b Number = 0.0)` (§ 3.3). `record` field lines (`x Number`) need no change
at all — they are juxtaposition read as *data* by the `record` command
(rule 3), and the checker applies the same annotation grammar there.

### 3.2 R2 — annotated blocks: `: Type` then the block

```owl
fun add a Number b Number: Number
    + a b
```

A trailing `:` may now be followed by a type expression at the end of the
line — with a block behind it, the type annotates the block's definition;
without a block it annotates a header that has no body, which is exactly the
`val` form of § 4.5. Today `:` must end the line, so `fun add a: Number` is a
parse error, and that error slot is what R2 claims. The annotated block is a
**check**: the body must have that type. `:` after a definition name with *no*
type stays "block follows" (`fun view:` is unchanged), and the trailing
annotation is accepted **only** in definition headers (`fun`, `command`,
`dynamic-command`, `widget`, `val`) — elsewhere it stays the parse error it
is today, so `f x: Int` as a value-level ascription does not sneak in (§ 3.4).

### 3.3 On definitions

Annotations ride the headers of `fun`, `command`, `dynamic-command`, `widget`
and on `=` bindings:

```owl
fun add a Number (b Number = 10): Number
    + a b

fun map f (-> a b) xs (List a): (List b)
    out = ([])
    for x (items xs):
        append out (f x)
    out
```

Parameter annotation rules (evaluator-side elaboration, not reader-side — the
header already parses as items):

- a **bare parameter** `x` may be followed by one **uppercase-headed** type
  word (`a Number`) or one **group** (`xs (List a)`); anything else that
  follows is a new parameter. So `fun map f (-> a b) xs (List a)` reads as
  two annotated parameters, while `fun id x a` reads as two parameters —
  `a` is lowercase and bare, so it is never an annotation. The rare
  "annotate with a bare variable" case wraps the variable: `(x a)`.
- a **default parameter** `(x = e)` gains its type inside the group:
  `(x Number = 0.0)` per R1; the default must check against the type.
- a parameter's type may name a type variable (§ 6.1 quantifies them);
  a parameter without an annotation gets a fresh variable —
  ```owl
  fun first xs:
      index xs 0
  ```
  *infers* `first : (-> (List a) a)` in a typed module.
- the return type after `:` (R2) is checked, never inferred-from; omit it for
  inference.
- `set` takes no annotation — assignment against an existing binding's type.

`add` above is the sketch from `typing.org`, kept intact except `Int` →
`Number` (§ 2.2): the runtime has one number kind.

### 3.4 In code

Annotations are **not** expressions. There is no ascription form at all: no
type arguments at call sites, no `(declare x Number)`-style pinning inside a
body — state is typed where it is bound (§ 3.1) or inferred; the rest is
unification. If inference
ever needs a hint, the binding gets an annotation at its `=`. This is what
keeps the surface tiny enough to formalize; the cost is that some hints need
a local binding instead of an ascription (§ 12).

---

## 4. Definitions: `type`, `record`, `data`, `val`

Four new words, zero new syntax — each parses today as a call (rule 3):
`type Set a (List a)` is the list `[type Set a (List a)]`; `record Point (x
Number) (y Number)` and `data Optional a None (Some a)` likewise; blocks use
the plain trailing `:` machinery.

### 4.1 `type` — aliases

```owl
type Id String
type Set a (List a)
type Handler e (-> e Unit)
```

`type Name vars... T` declares `Name` as an alias: same arity as its vars,
transparent to unification after unfolding the name's spine (a `Set Number`
*is* a `List Number`; the checker may still print the alias). No values come
with it.

### 4.2 `record` — named records

```owl
record Point:
    x Number
    y Number
```

or one-line `record Point (x Number) (y Number)`. Fields are annotated
bindings (R1's shape inside a block), in **declaration order**, names must be
distinct. A `record` is a **new nominal type** with one constructor:

- construction reuses option calls: `Point (x = 1) (y = 2)` — pairs checked
  against the declared fields, order-insensitive, all required, none
  missing, none unknown (§ 7.4). `p = Point (x = 1) (y = 2)` then infers
  `p : Point`.
- access reuses the dot: `p.x : Number` (§ 7.5). Runtime `index` on records
  is unchanged — the checker is what guarantees it can't miss.
- equality: `=` on two `Point`s compares fields (as records compare today).

Anonymous record literals `{}` stay structural (§ 7.5): `rec = {} (w = 1)`
has the structural type `({} (w Number))`, dots checked against the literal's
own field set, no subtyping, no extension. `record` is how a structure gets
a *name* and a nominal type.

### 4.3 `data` — ADTs

```owl
data Tree a:
    Leaf
    Node (Tree a) a (Tree a)

data Optional a:
    Nothing
    Some a

data Shape:
    Circle Number
    Rect Point Point
```

One constructor per line, block or one-line juxtaposition (`data Optional a
Nothing (Some a)`); each constructor is `Name payloads...` — bare `Name` for
nullary. Constructors are **uppercase** (rule 2) and are *value* definitions:
after `data Tree a`, the word `Node` is a value of type
`(-> (Tree a) a (Tree a) (Tree a))` and `Leaf` of `(Tree a)` — applied by
plain juxtaposition at any position, exactly like a widget call:

```owl
t = Node (Node Leaf 1 Leaf) 2 Leaf
```

Checking is what makes a bare juxtaposition *construct* rather than *call*:
`(Node a b c)` with `a b c` of the payload types is the application of the
3-ary constructor. How `evaluator.nim` chooses to represent the constructed
value is none of the type layer's business — the checker only promises the
`match` and dot access can't go wrong. The type name `Tree` is not a
value, and constructor names live in the value namespace; collisions are
errors: constructors distinct within a `data`, no constructor shadowing a
`fun`, no `data` constructor named like a base type. The `Nothing` of
`Optional` above does not collide with `nothing` — values are lowercase,
rule 2 keeps them apart.

### 4.4 `nothing`, `Unit`, and optionality

`nothing : Unit`, and `Unit` is *not* `Optional`: functions returning the
absence of a value (`when`, `set`, an `echo`'s result) return `nothing : Unit`,
which no payload accepts. For *maybe* values you `data` an optional, and the
sugar is one-sided:

- in a position whose expected type is a `data` with exactly **one nullary
  constructor** (like `Optional`'s `Nothing`), the literal `nothing` *is*
  that constructor. So the docs' idiom survives typed:
  ```owl
  pick (Optional Boolean) = nothing
  when (<> pick nothing):
      ...
  ```
- `<>`/`=` against `nothing` on an `Optional`-typed value is the "is none"
  test (§ 7.1).
- nullary constructors like `Leaf`/`Nothing` are generalized like values
  (they are pure): `tree = Leaf` infers `(Tree a)`, then `Node tree 2 Leaf`
  pins `a`. `nothing` alone generalizes to every such optional type under
  the same § 6.2 discipline (the value restriction is why `pick` carries the
  annotation above — a `set`-assigned binding never generalizes).

### 4.5 `val` — native signatures

Two shapes, both plain juxtaposition: a single type expression, or the header
of a `fun` without a body —

```owl
val number-field (-> String Number Number Number Number Number)
val button id String label String (width Size) (tab-index Number): Boolean
```

`val name T` / `val name params: T` declares the type of a binding the owl
source does not define: Nim builtins (`gui.nim`, `base.nim`), foreign helpers,
forward declarations. The param specs follow § 3.3's convention — `id String`
is a positional parameter, `(width Size)` an option — plus one liberty a
checked `fun` header doesn't have: an option may be declared **without** a
default, because the native's own `CallShape` fills omitted options at
runtime (a `fun`'s `(b Number)` group without `=` stays illegal, exactly as
today). Defaults, when written, are checked as usual. The primitives of
§ 7.1 — `index`, `concat`, `+`, `=` — are **not** declared by `val`: they are
typing rules, not signatures. `val` is how everything *else* native enters a
typed module.

### 4.6 `emits` / events

Untouched as syntax. The checker gives each declared event a payload record
type inferred **from use**: every `emit Bumped (by = 1)` and every `e.by` in
an `event Bumped e:` handler unifies one payload type `({} (by Number))` per
event, per module (§ 8.3). `define-event "Searched" ([] (term String))` — the
typed form of `define-event` takes annotated field groups where the legacy
form took bare strings, and pre-fixes the payload; the legacy form keeps
working, inferred.

---

## 5. Matching ADTs: `match`

`match expr:` opens a block; each arm is either `pattern = body` (one line,
mirroring `cond:`'s arms) or `pattern:` + an indented body (multi-line, and
the form whose pattern is plain juxtaposition — the same list-plus-body the
`:` machinery already reads):

```owl
fun size t (Tree Number): Number
    match t:
        Leaf = 1
        (Node left value right) = (+ (size left) (size right) 1)

fun area s Shape: Number
    match s:
        Circle r:
            * 3.14159 (* r r)
        Rect a b:
            area-rect a b
        _:
            0
```

- **Patterns**: a lowercase word is a *variable* (`r`, `left`); bare `_` is
  the **wildcard**; an uppercase word is a *nullary constructor* (`Leaf`);
  `(Node left value right)` is a constructor with sub-patterns, nested
  arbitrarily. In a `= arm` a multi-item pattern must be that group — the
  reader already allows "a grouped call on the left of `=`", which is exactly
  how `cond:` arms parse — while a block arm may keep the pattern as bare
  juxtaposition (`Rect a b:` above). Number/string/`true`/`false` literals
  are constant patterns; a bare literal is neither a symbol nor a group, so
  literal patterns are written in the block form (`0:` + body), which the
  reader takes as a call-headed list without ever calling it.
- **Semantics**: leftmost matching arm; patterns are linear (rebinding a
  variable name twice in one pattern is an error) and irrefutable only at
  the top level via `_`. Variables bind at the arm's body type; constructor
  patterns require the scrutinee's type to be the constructor's parent type
  with fields/args unified, and bind the payload — **n-ary constructors are
  the only way in**, so a typed `p.x` on the matched value is never needed.
- **Exhaustiveness**: the checker computes it per scrutinee type — for a
  `data`, all constructors covered (wildcard or variable arms count as
  covering but then kill redundancy warnings); for literals against `Number`/
  `String`, a default arm is required; **partial match is a warning**, at
  runtime a no-arm match errors like a failed builtin ("match: no arm for
  value"). 
- **Typing**: all bodies must share the arm type; the whole `match` has it.
  `match` is therefore an expression, but only ever appears where one is
  allowed (§ 7.2: `x = match ...`, or as a def's last body form).
- No guards (a `when` inside the arm body does that job), no as-lists or
  nested list patterns (§ 12).

`match` is a `command`: it reads its block as syntax (rule 3) and compiles
to nested `index`/`=` tests plus a `cond:`-shape at expansion — or, once the
evaluator gets a fast path, a builtin; that's implementation, not design.

---

## 6. Inference

### 6.1 What the checker runs

Algorithm W over elaborated definitions, standard HM:

- **Types** are the grammar of § 2.1. A context Γ maps value names to type
  *schemes* (∀-quantified) or monotypes; a separate context Σ maps type
  constructor names to their declared arity and structure (§ 4), Φ records
  field types per record type and constructor signatures per `data`.
- **Quantification is implicit, per definition**: the free lowercase type
  variables appearing in one definition's annotations (parameters, result,
  defaults) are universally quantified for its scheme — `fun map f (-> a b)
  xs (List a): (List b)` has scheme `∀a b. (-> (-> a b) (List a) (List b))`.
  Nothing else generalizes implicitly; there is no `forall` keyword.
- **Application**: unify the argument types with a fresh instance of the
  callee's scheme, then the call's type is the scheme's result. Arity is
  exact (§ 2.1); a call with missing/extra arguments is an arity error
  before unification.
- **`match`**: instantiate the scrutinee type, then each arm pattern as § 5.
- **Records/constructors**: field access and option-pair checks consult
  Σ/Φ; construction unifies each pair value against the field's type.
- **Unification** is occurs-checked, nominal types match only same-name
  (unfolding aliases through their spine first), no subtyping anywhere.

### 6.2 Bindings: generalization, restricted

A `=`-bound name gets a scheme (generalization) **iff**

1. its RHS elaborates to a *value* — a `fun`/`lambda`/constant/constructor
   application/record literal/`nothing` — and
2. the name is **never assigned** with `set` anywhere the binding can be
   reached — in its own module, or through an `export` another module might
   `set` through (§ 8.1 keeps this precise: exports carry schemes, so the
   origin module must treat any exported name as potentially assigned and
   keep it monomorphic unless the export list excludes it).

Otherwise it keeps a monotype, frozen by its first unification. This is the
value restriction restated for owl's `=`/`set` pair: `round-trip state`
(`volume`, `clicks`, `dark` in the examples docs) is assigned, so it is
monomorphic, so `volume = 0.4` then `set volume "x"` is a type error — and
so `volume Number = 0.4` documents intent. `fun`-defined names and `val`s
always generalize (they are syntactic values; `set`-rebinding a `fun` name
disables that too by rule 2).

### 6.3 Recursion

A `fun`'s name is bound to its (fresh, unannotated-variables) type **before**
its body is checked — recursive calls unify against it. An unannotated
recursive `fun` whose argument types never meet a concrete use is
under-determined; the checker then asks for annotations at the header, the
usual HM limitation. Mutual recursion (a `runProgram` hoisting batch of
`fun`s) types as one letrec group: fresh monotypes, check bodies together,
generalize after.

### 6.4 Worked examples

```owl
fun compose f g x
    f (g x)
```
Inferred, annotations absent, in a typed module: `g x` says `g : (-> a b)`,
`f (g x)` says `f : (-> b c)`, result `c`:
`compose : ∀ a b c. (-> (-> b c) (-> a b) a c)`. A call `compose not is-empty
xs` pins `a` to whatever `xs` holds, `b` and `c` to `Boolean`.

```owl
fun member x xs (List a)
    ...
```
would *fail* as written: `member` compares `x` against the elements of `xs`,
and the `=` primitive rule (§ 7.1) admits concrete comparable types —
`Number`, `String`, `Boolean`, records/lists thereof — never an opaque type
variable. HM has no way to say "comparable" without classes (§ 12).

```owl
fun find pred xs (List a): (Optional a)
    for x (items xs):
        when (pred x):
            return (Some x)
    Nothing
```
`pred : (-> a Boolean)` from `pred x`; the result line fixes `(Optional a)`;
`a` stays a variable — `find is-empty list-of-lists` instantiates it to
`(List String)`. (No `return` exists today; the body-as-last-value idiom
rewrites this to a loop with a local — the point is the *typing*, the body
form is the existing language's problem; § 12 tracks the `return` question.)

### 6.5 Properties

Standard HM: **termination** (unification occurs-checked over a finite
signature built from § 4 declarations), **soundness** (checked program, no
type error at runtime from this layer: field access, option calls, constructor
arity, `set` assignments, `match` bindings all justified by Γ), **principality**
(each `fun` without a return annotation infers one most general type; an
annotated def is checked against the annotation, and the annotation itself is
a scheme by § 6.1). Lean mirrors these (§ 11).

---

## 7. Typing the forms that already exist

The existing language keeps its shape; what follows is how each form is
*checked*, mostly as ad-hoc rules over names the evaluator already binds —
a **rule table**, not signatures, because HM cannot state polymorphic
comparison or heterogeneous `index`.

### 7.1 Primitive rules

The arithmetic and logic primitives are typed by a **rule table** keyed by
the head symbol, not by `val` signatures — HM cannot write polymorphic
comparison or kind-dispatched `index`, and this is the language's entire
ad-hoc polymorphism. Formally the table is a function `primRule(name,
arg-types) → result-type`, consulted instead of unification. Its rows, in
words:

| head | rule |
|------|------|
| `+ - * /` | all operands `Number`, result `Number` |
| `< >` | operands same type, one of `Number`/`String`; result `Boolean` (`<=`/`>=` don't exist today; if added, they join this row) |
| `= <>` | operands unify; allowed for `Number`, `String`, `Boolean`, `Unit`, and records/lists of comparable types; result `Boolean` |
| `and or` | `Boolean` operands (short-circuit is a runtime matter, not a type one); `not` `Boolean → Boolean` |
| `concat` | `String` operands and result, n-ary (≥ 1) |
| `to-string` | any printable type → `String` |
| `length` | `String → Number`, `(List a) → Number` |
| `index` | dispatches on the target's static type: `(List a) Number a`; `String Number String`; record — field name must exist in the target's type, result the field's type (§ 7.5) |
| `items` | `(List a) → (Iter a)` |
| `append prepend pop pop-front insert slice` | list rules against `(List a)` |
| `char` | `Number → String` |
| `eval` | `Syntax → Dynamic` (§ 7.3, § 8) |
| `try` | `Dynamic`-flavoured: its result record is checked only through fields the code touches |

`(Iter a)` is a `data` with one constructor that only the loop forms
produce — nothing builds it by hand. `=` against `nothing` on an
optional-typed value is § 4.4's sugar, checked as the is-none test. `=` is
equality, never coercion.

This table is the whole "overloading" story: fixed names, one rule per head,
never inferred as a signature (§ 12 for why no classes).

### 7.2 Conditionals and blocks

`if`, `cond:`, `when`, `unless`, `do:` — **bodies unify**, exactly as the
runtime returns the last value of the taken branch: `if`'s then- and
else-sequences share one type; `cond:`'s arms share one type (and it must
end with a `true =` arm or have arms of type `Unit`, since a cond whose arms
all miss evaluates to `nothing`); `when`/`unless`/`do:` in **statement
position** (value unused) impose nothing on their body beyond being checked
and yield `Unit`, and in **value position** their body must be `Unit` — the
untaken path evaluates to `nothing`, so any other body type would be a lie
(`v = when c: e` wants an optional shape, and should be written as `if` with
both branches or bound through `match`). **All** conditions are `Boolean`:
owl's truthiness of arbitrary values (§ 12: `toBool` accepts anything that
isn't `nothing`/`false`) is the one semantic thing a typed module gives up —
`when volume:` becomes `when (is-any ...)`, mechanical across the examples.
A definition's body is a sequence; the last form's type is the definition's
(checked against the R2 annotation if present). Blocks are not lambdas
(§ 12's `return` question).

### 7.3 `fun`, `command`, `lambda`, slots

`fun`/`lambda` are the HM values (§ 6). **`command`** and
**`dynamic-command`** parameters bind *unexpanded syntax*: the checker types
them `Syntax`, a base type in name only — nothing outside a command body can
consume it. A command body is checked **once**, with its parameters as opaque
`Syntax`, and `eval` on one returns `Dynamic` (§ 7.1, § 8): the seam is the
price of hygienic macros, and it is where user `command`s live. (The control
forms are exempt by *name*, not by machinery: `when`, `if`, `cond` are Nim
builtins and `unless`, `and`, `or` are `base.owl` commands that `eval` their
arguments — the checker recognizes all of them and applies § 7.2's rules
directly rather than checking their definitions as opaque.) A typed module
may call other commands freely — it trusts them at the seam, and the trust is
confined to the `Dynamic` the seam hands back. `widget` expands to a `fun`
before checking (§ 22 of the examples doc: the generated code is ordinary
owl, so the checker checks *that*), with slot parameters `&body` typed
`(-> Unit)` by use.

### 7.4 Option pairs at calls

`button "ok" "OK" (width = Grow)` — the pairs in a call are **named
arguments**, checked against the callee's declared/defaulted parameter names
(the runtime's `CallShape` is exactly this, `objects.nim`): `(width = v)`
type-checks `v` against `width`'s type (default's inferred type in `fun`s,
declared in `val`s). Unknown key, missing required, duplicated key: errors.
(Typed code passes `Grow` and `(Fixed 220)` where untyped code passed the
`grow` symbol and a bare number — sizes are `Size` values, § 8.3; that is
the option-position face of rule 2.) A pair with no callee — a bare
`(x = 1)` in value position — is the runtime `Pair` kind and is not typed
in a typed module (§ 2.3): pairs are call syntax, not data. This rule is
why `run-app (title = "Notes")` needs zero new syntax to be checked.

### 7.5 Records and the dot

`{}` literals: closed structural types (§ 4.2). `a.b`: the dot folds to
`index` at read time — the checker types it by the static type of `a`: named
`record` field, `{...}` literal field (literal-only: the *expression's own*
fields), event payload § 4.6, theme-internal records (§ 8.2's `Dynamic` for
what `gui.nim` hands over). No field-exists-at-runtime hope: it is decided
statically or not typed.

### 7.6 State

`set x v`: `x`'s type is frozen by § 6.2; `v` must unify; `set` yields
`Unit`. `x = v` then `set x w` ⇒ `v ≅ w` (same type). Round-trips
(`set volume (number-field "vol" volume ...)`) therefore force the value's
type to agree with the widget's — which is the actual bug class this layer
catches in apps (§ 12's migration note).

---

## 8. Libraries and `Dynamic`

### 8.1 Enabling

`use types` at the top of a module opts it in: definitions are elaborated
against Σ/Φ/Γ built from its own `type`/`record`/`data`/`val` forms, its
imports' exported schemes, and the primitive rule table. Modules without
`use types` check **nothing** — they run as today, untyped, including ones
that *use* `gui` (which stays Nim-backed). Exports (`export: x = y`, `export
all`) carry checked schemes. Importing an *untyped* module into a typed one
binds its names at `Dynamic`.

### 8.2 `Dynamic`

One escape type: `Dynamic` unifies with anything in both directions (it is
the gradual seam, not a value constructible by owl source except at the
boundary: untyped imports, `eval`, `try`, Nim builtins that hand back theme
or event internals). It never *generalizes* and vanishes from inferred types
printed in errors. The formal core (§ 11) omits `Dynamic`; it is the
engineering layer around the proved system, exactly the way the docs'
`frame-error` and `event-log` records are today: shapes nobody promises.
Consequence: `gui.owl` needs `val` signatures to type-check against (§ 8.3)
but `gui.nim` itself stays as-is — `val` is the contract Nim code is
responsible for keeping, checked when possible (`reference-widgets.md` is
the source the signatures were harvested from).

### 8.3 The gui story

Typing the widget layer looks like:

```owl
; gui.owl
use types
data Size:
    Fixed Number
    Grow
    Fit
    Pct Number

val button id String label String (width Size) (height Size) (tab-index Number): Boolean
```

— and this is where the option machinery earns its keep: `button`'s real
signature carries ~10 options of distinct types (sizes, colors, tab index),
declared as the annotated pseudo-parameters above and checked at each call
site by name. The shapes of § 4.5 apply throughout: a **bare** annotated word
is a positional parameter, a **grouped** one an option (the runtime
`CallShape` already knows which, and the checker trusts it). A `widget
Counter id label n:` (§ 1 of the examples) checks directly: parameters
annotated or inferred, `emits` payload inferred (§ 4.6), body checked, and
`Counter "c" "Clicks" clicks` at call sites gets its named/positional check.
`run-app`, dialogs, `handle-events` follow the same `val`-plus-expansion
pattern. (`grow`/`fit` as bare symbols become the `Grow`/`Fit` constructors —
typed owl is where rule 2's case discipline pays for itself.)

---

## 9. Errors

Errors are `OwlError`s of a new kind `TypeError`, with source place, message
and the two types involved, in the existing render style (caret, file:line):

```
type error: number-field wants Number for value
    set volume (number-field "vol" volume (step = 0.05))
;                                            ^^^^^
;                                   got String, expected Number
```

and principality-adjacent reporting: on an `if` branch mismatch the error
names *both* branches; on an unbound uppercase word in a type it says
"no such type: Strng — did you mean String?"; a partial `match` says which
constructors are missing (`Rect`); a scheme-vs-use clash shows the origin
place of the frozen type. No new error UX is invented — same plumbing as
read/runtime errors, same `frame-error` surface.

---

## 10. Alternatives considered

1. **OCaml colons everywhere** (`x: Number = 100`, `(a: Number)`): familiar,
   but `:` is owl's *only* block punctuation and a mid-line colon either
   conflicts or needs whitespace rules; juxtaposition is already how the
   language says `f x y` and how the sketch in `typing.org` was written.
   R1/R2 are smaller reader changes than "colon means two things."
2. **The sketch's `List.(Int)`** (dot-application of type constructors):
   it *parses* today (`foldDots` → `(index List Int)`), which is tempting —
   but `.` already means "field of a value," and a type that looks like an
   index read is a formalization trap (two meanings, one fold). Juxtaposition
   `(List Int)` is one grammar for both worlds. The sketch itself survives
   whole — `a Int` parameters become `a Number`, `(b Int = 10)` becomes
   `(b Number = 10)` via R1, the return `: Int` becomes `: Number` via R2
   (§ 2.2's one number kind).
3. **Explicit `forall`/type-parameter clauses** (a `types a b` line à la
   `emits`): rejects the typo-as-variable hazard but adds a form and a line
   for every generic. The uppercase-must-resolve rule (with a "did you mean"
   diagnostic) covers typos; implicit quantification stays OCaml-like.
4. **Row polymorphism for anonymous records** (option-languages): the right
   long-term answer for structural widening, far heavier than this doc's
   rest (kinds with row kinds, subsumption); `val`'s option-parameter
   mechanism covers widgets instead. Deferred (§ 12).
5. **Curried multi-argument types**: rejected, § 2.1 — the runtime binds
   all parameters at once; pretending otherwise infers types the evaluator
   can't honor.
6. **A mandatory `Int`/`Float` split**: the runtime is `float64` everywhere;
   a static-only `Int` that erases would let `(- 1 2)` pass checks and lose
   meaning on big values. One `Number` now; revisit only if the runtime
   gains an integer kind.
7. **Typing by default with escapes everywhere**: rejected — the corpus is
   untyped and Nim-backed (`gui.nim`), per-module opt-in (§ 8.1) is how a
   small implementation grows into the language without a cliff.

---

## 11. Lean formalization plan

For the next step; what the design promises so the formalization can start
without re-deriving it:

- **Surface elaboration**: a reader-output `Expr` inductive mirroring
  `objects.nim`'s `Object` (constants, symbol, list, pair, record, command
  definitions) plus annotation nodes produced by R1/R2. `match`/`data`/
  `record`/`type`/`val` are pre-elaboration: their *syntax* as Expr + the
  elaborator's rewrite rules. (Lean's `inductive Expr` can stop *after*
  elaboration; both are fine, the doc defines the boundary.)
- **Type syntax**: `inductive Ty: | base : Base → Ty | var : Nat → Ty |
  construct : Name → List Ty → Ty | arrow : List Ty → Ty → Ty` — the arrow's
  first field is the argument spine, the second the return, so `arrow [] Tr`
  is the `(-> Tr)` thunk (§ 2.1). Record types ride `construct` with the name
  `{}` and `(field Type)` groups as the spine. `Scheme := ∃ vars, Ty` with
  quantification by free-variable set per § 6.1.
- **Contexts**: Γ (name → Scheme/mono), Σ (type constructor → arity + kind
  alias/data/record), Φ (constructor name → payload Ty list + parent; field
  name + type per record). Built from § 4 declarations by a well-formedness
  pass (distinct names, declared arity, no shadowing across the classes of
  § 4.3).
- **Unification + W**: `unify : Ty → Ty → M Subst`, occurs-checked, spine
  unfolding of aliases (§ 4.1); `infer : Γ → Expr → M (Subst × Ty)` per § 6,
  generalization gated by the § 6.2 value + never-assigned predicate (define
  `assigned : Expr → Name → Bool` syntactically).
- **Rule table** (§ 7.1): a function `primRule : Name → List Ty → M Ty`
  encoding the ad-hoc rules; it is the one non-algorithmic component — its
  correctness is stated as per-primitive soundness lemmas ("if the rule
  types `index l i`, `l` is a list/string/record of...").
- **Theorems**: progress/preservation for the checked fragment (runtime
  errors of the listed classes unreachable), principality for annotation-free
  `fun` inference, termination of `W` (via occurs-check + finite signature),
  soundness of `match` compilation to `cond` (the § 5 desugaring preserves
  the arm type).
- **Out of core, kept as flags**: `Dynamic` (gradual layer on top),
  `command`-body opacity (§ 7.3), event payload inference (§ 4.6 — module-
  local unification, a pass around W, not inside it).

---

## 12. Open questions

- **`return` / early exit**: `find` above wanted it; today the rewrite is
  a local + `set`. Keep the language's problem, not the types'.
- **Guards in `match`** (a block arm whose pattern is followed by a group
  boolean, `Node l v r (> v 0):` …): cheap syntactically — the juxtaposition
  already reads as a list — but interacts with exhaustiveness — defer.
- **Nested list patterns** (`(xs tail)` against `List`), record patterns
  (`Point (x = cx)`): each wants a decision about `[]` literal matching —
  defer until someone wants them.
- **Equality classes**: `member` (any comparable type) is exactly what HM
  without classes can't say; the `=` primitive rule covers direct use,
  user-defined generic equality needs a plan (first-class `->` of a `data`
  of comparators? probably fine for owl).
- **Functors/module parameters** (type params across `use`): out of scope,
  HM modules export schemes only.
- **`export all` + `set` interaction** (§ 6.2's never-assigned rule): pick
  the precise story when `use`/`live` reload semantics meet — hot reload
  re-checks, does a scheme of an exported `fun` survive a redefinition?
  (assume yes, check later).
- **Error recovery UX**: type errors are *not* runtime errors today;
  `owl run` on a typed module with type errors — refuse to load, or load
  with the failing definitions `Dynamic`? (refuse: it is the point.)
- **The `when volume:` truthiness** tax (§ 7.2): every `when <non-boolean>`
  in the corpus must gain an `is-any`/comparison. Mechanical but real
  migration work; the opt-in module order (§ 8.3: leaf utilities first, gui
  last) sequences it.
- **Structural vs. `Dynamic` theme**: `(theme).palette.accent` reaches into
  a Nim-provided record; either `gui.nim` grows a `val` for `theme`'s shape
  or it stays `Dynamic`. The reference-widgets table suggests the former.

---

*The design is deliberately boring where it can be: juxtaposition, case,
blocks. Everything expressive about owl's reader survives; the type layer is
only what the reader and evaluator already read, plus two legalized error
shapes and a checker. That is the version we expect to finish proving in
Lean.*
