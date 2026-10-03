## Pure Nim Cassowary constraint solver based on Kiwi.
##
## Vendored Nimony port of kiwiberry (https://github.com/elcritch/kiwiberry).
## Upstream kiwiberry is pure Nim 2. This copy adapts it to the Nimony 0.6
## subset:
##   - Exception objects replaced by ErrorCode aliases (see errors fragment).
##   - The `'ks` numeric literal is dropped; int/float64 converters to
##     KiwiScalar take its place (`240'ks` -> `240`).
##   - Union typeclass DSL generics replaced with generated concrete overloads.
##   - No `lent` return types; accessors return by value.
##
## Implementation notes: the parts are `include`d (not imported) into this
## single module on purpose. Nimony binds an identifier for every exported
## module alias, so `import kiwiberry` would steal the names `solver`,
## `constraints`, `errors`, ... and break `var solver = initSolver()`.
## Include-order below is dependency order; fragments must not import each
## other. `import kiwiberry/scalars` directly is not supported in this fork.

include kiwiberry/[validation, scalars, strengths, variables]
include kiwiberry/internal/[symbols, assocmaps, cellmaps, rows]
include kiwiberry/[expressions, constraints, errors, solver]
