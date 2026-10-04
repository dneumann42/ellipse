type
  Palette* = object
    primary* = rgb(52, 56, 72)
    bgColor* = rgb(12, 12, 16)
    panelBg* = rgb(28, 30, 38)
    panelBorder* = rgb(60, 64, 78)
    textColor* = rgb(230, 232, 238)

  Theme* = object
    palette: Palette
  
