import clay
import ../ui

import ./common

widget Card(title: string, actions: proc(): void, body: proc(): void):
  let t = activeTheme
  container(col(width = grow(), height = fit(), gap = t.metrics.gapCard,
      padding = padAll(t.metrics.padCard))
    .bg(t.palette.panelBg)
    .border(t.metrics.borderHairline, t.palette.panelBorder)
    .corner(t.radii.card)):
    if title.len > 0:
      container(row(width = grow(), height = fit(), gap = 8,
          alignY = centerY)):
        textElement(title, TextConfig(fontSize: t.text.cardTitle,
          color: t.palette.textColor))
        spacer()
        actions()
    body()

widget StatCard(label: string, value: string, hint: string):
  let t = activeTheme
  container(col(width = grow(), height = fit(), gap = t.metrics.gapList,
      padding = padAll(t.metrics.padStat), alignX = centerX)
    .bg(t.palette.panelBg)
    .border(t.metrics.borderHairline, t.palette.panelBorder)
    .corner(t.radii.card)):
    textElement(label, TextConfig(fontSize: t.text.statLabel, color: t.palette.dimColor))
    textElement(value, TextConfig(fontSize: t.text.statValue, color: t.palette.textColor))
    if hint.len > 0:
      textElement(hint, TextConfig(fontSize: t.text.statHint, color: t.palette.labelColor))

widget CardRow(body: proc(): void):
  container(row(width = grow(), height = fit(),
      gap = activeTheme.metrics.gapCardRow)):
    body()
