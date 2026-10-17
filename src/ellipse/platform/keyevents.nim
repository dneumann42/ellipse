## The keyboard events the UI reads (`platform.keyEvents`), shared by the
## SDL window and the terminal input decoder.

type
  KeyEventKind* = enum
    ## What a `KeyEvent` carries. Printable input arrives as `kevText`:
    ## the composed string, layout, Shift, CapsLock and AltGr applied. The
    ## rest are the named keys the UI edits and navigates with. Ctrl/Alt
    ## held on any printable key makes a chord instead: `kevLetter` with
    ## `ch` the key's *unshifted* char -- the lowered letter, the digit,
    ## '-', '=', '/', '[', ... (Shift travels in `shift`). `kevNone` marks
    ## ignored keys and never enters the queue.
    kevNone, kevText, kevLetter, kevBackspace, kevDelete, kevLeft, kevRight,
    kevUp, kevDown, kevHome, kevEnd, kevEnter, kevEscape,
    kevPageUp, kevPageDown,
    kevF1, kevF2, kevF3, kevF4, kevF5, kevF6,
    kevF7, kevF8, kevF9, kevF10, kevF11, kevF12,
    kevTab,   ## Tab / Shift+Tab: focus traversal (see `ellipse_ui/focus`)
    kevInsert

  KeyEvent* = object
    kind*: KeyEventKind
    shift*: bool
    ctrl*: bool
    alt*: bool
    ch*: char          ## kevLetter only: the chord's unshifted char
    text*: string      ## kevText only: the composed string of one keypress
