## Durable widget state shared by every UI app's whole-process hot reload.
## Register values once in the module that owns them. Stable element IDs
## identify widget instances; frame caches, callbacks and handles stay local.
{.push gcsafe.}

import std/[json, jsonutils]
export json

type
  UiReloadCommit = proc() {.closure.}
  UiReloadHook = object
    key: string
    save: proc(): JsonNode {.closure.}
    prepare: proc(value: JsonNode): UiReloadCommit {.closure.}

var uiReloadHooks {.threadvar.}: seq[UiReloadHook]

proc registerUiState*[T](key: string; read: proc(): T {.closure.};
                         apply: proc(value: T) {.closure.}) =
  ## Objects evolve by field name: new fields keep their defaults, removed
  ## fields and unregistered participants are ignored. Register before launch.
  for hook in uiReloadHooks:
    if hook.key == key:
      raise newException(ValueError, "duplicate UI reload key: " & key)
  uiReloadHooks.add UiReloadHook(key: key,
    save: proc(): JsonNode = toJson(read()),
    prepare: proc(value: JsonNode): UiReloadCommit =
      # Decode a fresh copy before overlaying saved fields: staging must
      # never mutate a live sequence or reference owned by another hook.
      var staged = jsonTo(toJson(read()), T)
      fromJson(staged, value,
               Joptions(allowMissingKeys: true, allowExtraKeys: true))
      result = proc() = apply(staged))

template persistUiState*(key: string; state: untyped) =
  ## The registered value must outlive the app. Tuple lvalues may group
  ## related fields while leaving input edges and frame counters transient.
  registerUiState(key, proc(): typeof(state) = state,
                  proc(value: typeof(state)) = state = value)

proc saveUiState*(): JsonNode =
  result = newJObject()
  for hook in uiReloadHooks:
    result[hook.key] = hook.save()

proc restoreUiState*(saved: JsonNode) =
  if saved.kind != JObject:
    raise newException(ValueError, "invalid UI reload archive")
  var commits: seq[UiReloadCommit]
  for hook in uiReloadHooks:
    if saved.hasKey(hook.key):
      commits.add hook.prepare(saved[hook.key])
  # No state changes until all participants have decoded successfully.
  for commit in commits:
    commit()
