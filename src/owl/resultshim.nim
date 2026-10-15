
type
  Result*[T, E] = object
    okFlag*: bool
    val*: T
    errVal*: E

func ok*[T, E](v: sink T): Result[T, E] =
  Result[T, E](okFlag: true, val: v)

func err*[T, E](e: sink E): Result[T, E] =
  Result[T, E](okFlag: false, errVal: e)

func isOk*[T, E](r: Result[T, E]): bool = r.okFlag

func isErr*[T, E](r: Result[T, E]): bool = not r.okFlag

func get*[T, E](r: Result[T, E]; default: sink T): T =
  if r.okFlag: r.val else: default

func error*[T, E](r: Result[T, E]; default: sink E): E =
  if r.okFlag: default else: r.errVal
