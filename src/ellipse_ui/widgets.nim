## The standard widget set for the new (clay-based) UI system.
##
## Import this module for the whole set, or the individual fragments:
##
##   import ellipse_ui/widgets          ## everything
##   import ellipse_ui/widgets/checkboxes
##
## The pieces:
##
##   module         provides
##   -------------+----------------------------------------------------------
##   theme          `Theme` tokens + `activeTheme`, push/pop/`withTheme`
##   common         click edges, the focus/caret edit engine, the shared
##                  scaffold layer -- `container`/`item` brackets,
##                  `spacer`/`chevron`/`tickBox`/`textLine` parts,
##                  `fieldDecl`/`shadeDecl`/`toggleRowDecl`/`optionRowDecl`
##                  builders, the dropdown plumbing
##                  (`toggleDropdown`/`dropdownField`/`dropdownPanel`/
##                  `optionRow`) -- and `widget Labeled`
##   checkboxes     `checkbox`, `switch`
##   comboboxes     `comboBox` -- a single-choice dropdown
##   multiselects   `multiSelect` -- a checkable list over a bitmask
##   textfields     `textField`, `multilineField`
##   numberfields   `numberField`, `intNumberField`
##   headings       `heading`/`h1`..`h6`, `widget Section`
##   texts          `label`, `bodyText`, `caption`, `overline`, `badge`,
##                  `textLink`, `widget Prose`
##   editor         `editor` -- the full document area: scrollable,
##                  painted selection, click/drag caret, undo history
##   tabs           `widget TabbedView`, `tabStrip`, `activeTab`,
##                  `setActiveTab`
##   cards          `widget Card`, `widget StatCard`, `widget CardRow`
##   scrollbars     `scrollbar` -- floating draggable bars for clip
##                  containers, `scrollPanel` -- a framed clip container
##                  with its bar attached, `ScrollbarStyle`
##
## Immediate-mode contract: pass the current value in, store the return
## value back -- `checked = checkbox(id, "Wifi", checked)`. Transient state
## (which field has the caret, which dropdown is open) lives in the widget
## modules -- the dropdown slot in `common` -- keyed by element id, like
## `ui.menu` already does.

import ./widgets/[common, checkboxes, comboboxes, multiselects, textfields,
                  numberfields, headings, texts, editor, tabs, cards, scrollbars]

export common, checkboxes, comboboxes, multiselects, textfields,
       numberfields, headings, texts, editor, tabs, cards, scrollbars
