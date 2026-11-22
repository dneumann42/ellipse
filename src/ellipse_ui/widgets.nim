## The standard widget set for the clay-based UI system. Import this module
## for the whole set, or the individual fragments. See
## `documentation/nim-tutorial.md` §6 (The widget set) and
## `documentation/reference-widgets.md` for the full signature tables.

{.push gcsafe.}


import ./widgets/[common, checkboxes, comboboxes, multiselects, textfields,
                  numberfields, datetimepickers, headings, texts, editor, ropeEditor, tabs, cards, scrollbars, tables, charts]

export common, checkboxes, comboboxes, multiselects, textfields,
       numberfields, datetimepickers, headings, texts, editor, ropeEditor, tabs, cards, scrollbars, tables, charts

import ./[ropes, languages]
export ropes, languages
