## Typed duration, clock time, date, and recurrence controls.
import std/[strutils, times]
import clay
import ../ui
import ./[comboboxes, common, numberfields]

type
  DurationUnit* = enum
    seconds = "Seconds", minutes = "Minutes", hours = "Hours", days = "Days"
  DurationValue* = object
    amount*: range[1..99999] = 1
    unit*: DurationUnit
  TimeOfDay* = object
    hour*: range[0..23]
    minute*: range[0..59]
  CalendarDate* = object
    year*: range[1970..9999] = 1970
    month*: Month = mJan
    day*: range[1..31] = 1
  CalendarPattern* = object
    case
    of Daily:
      discard
    of BusinessDays:
      discard
    of Weekly:
      weekday*: WeekDay
    of SpecificDate:
      date*: CalendarDate

  CalendarSchedule* = object
    pattern*: CalendarPattern
    time*: TimeOfDay

func twoDigits*(value: int): string =
  align($value, 2, '0')

widget durationPicker(id: ElementId, value: DurationValue, tabIndex = 0) -> DurationValue:
  result = value
  const presets = [1, 5, 10, 15, 30, 45, 60]
  let selected = presets.find(int(value.amount)) + 1
  container(row(width = grow(), gap = 8, alignY = centerY)):
    result.amount = int(numberField(localId("duration-amount", id.id), value.amount.float,
      minVal = 1, maxVal = 99999, whole = true, width = fixedPx(132), tabIndex = tabIndex))
    result.unit = DurationUnit(comboBox(localId("duration-unit", id.id),
      @[$seconds, $minutes, $hours, $days], ord(value.unit), width = fixedPx(120),
      tabIndex = tabIndex))
    let preset = comboBox(localId("duration-preset", id.id),
      @["Quick pick", "Use 1", "Use 5", "Use 10", "Use 15", "Use 30", "Use 45", "Use 60"], selected,
      width = fixedPx(120), tabIndex = tabIndex)
    if preset > 0 and preset != selected:
      result.amount = presets[preset - 1]

func timeOptions(last: int): seq[string] =
  for value in 0 .. last:
    result.add twoDigits(value)

widget timePicker(id: ElementId, value: TimeOfDay, tabIndex = 0) -> TimeOfDay:
  result = value
  container(row(width = grow(), gap = 8, alignY = centerY)):
    result.hour = comboBox(localId("clock-hour", id.id), timeOptions(23),
      value.hour, width = fixedPx(82), tabIndex = tabIndex)
    text(":", activeTheme.text.control)
    result.minute = comboBox(localId("clock-minute", id.id), timeOptions(59),
      value.minute, width = fixedPx(82), tabIndex = tabIndex)
    text("24-hour time", activeTheme.text.caption, activeTheme.palette.dimColor)

func monthOptions(): seq[string] =
  for month in Month:
    result.add $month

func weekdayOptions(): seq[string] =
  for day in WeekDay:
    result.add $day

widget datePicker(id: ElementId, value: CalendarDate, tabIndex = 0) -> CalendarDate:
  result = value
  let theme = activeTheme
  container(col(width = grow(), gap = 5)):
    container(row(width = grow(), gap = 8)):
      result.month = Month(comboBox(localId("date-month", id.id), monthOptions(),
        ord(value.month) - 1, tabIndex = tabIndex) + 1)
      result.year = int(numberField(localId("date-year", id.id), value.year.float,
        minVal = 1970, maxVal = 9999, whole = true, width = fixedPx(132), tabIndex = tabIndex))
    let dayCount = getDaysInMonth(result.month, result.year)
    result.day = min(int(result.day), dayCount)
    let first = ord(getDayOfWeek(1, result.month, result.year))
    container(row(width = grow(), gap = 4)):
      for label in ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]:
        container(row(width = grow(), alignX = centerX)):
          text(label, theme.text.caption, theme.palette.dimColor)
    for week in 0 .. (first + dayCount - 1) div 7:
      container(row(width = grow(), gap = 4)):
        for column in 0 .. 6:
          let day = week * 7 + column - first + 1
          if day in 1 .. dayCount:
            let dayId = localIdWithIndex("date-day", day.uint32, id.id)
            let selected = day == result.day
            if button(dayId, (if selected: "[" & $day & "]" else: $day),
                width = grow(), height = fixedPx(30), fontSize = theme.text.caption,
                tabIndex = tabIndex):
              result.day = day
          else:
            spacer()
    text($result.month & " " & $result.day & ", " & $result.year,
      theme.text.caption, theme.palette.accent)

func patternIndex(pattern: CalendarPattern): int =
  case pattern
  of Daily(): 0
  of BusinessDays(): 1
  of Weekly(_): 2
  of SpecificDate(_): 3

func selectedWeekday(pattern: CalendarPattern): WeekDay =
  case pattern
  of Weekly(day): day
  else: dMon

proc selectedDate(pattern: CalendarPattern): CalendarDate =
  case pattern
  of SpecificDate(date): date
  else:
    let today = now()
    CalendarDate(year: today.year, month: today.month, day: today.monthday)

func `==`*(left, right: CalendarPattern): bool =
  if left.patternIndex() != right.patternIndex():
    return false
  case left
  of Weekly(day): day == right.selectedWeekday()
  of SpecificDate(date):
    case right
    of SpecificDate(other): date == other
    else: false
  else: true

widget calendarPicker(id: ElementId, value: CalendarSchedule, tabIndex = 0) -> CalendarSchedule:
  result = value
  container(col(width = grow(), gap = 7)):
    let pattern = comboBox(localId("calendar-frequency", id.id),
      @["Every day", "Monday to Friday", "Once a week", "On a specific date"],
      value.pattern.patternIndex(), tabIndex = tabIndex)
    case pattern
    of 1:
      result.pattern = BusinessDays()
    of 2:
      let day = WeekDay(comboBox(localId("calendar-weekday", id.id), weekdayOptions(),
        ord(value.pattern.selectedWeekday()), tabIndex = tabIndex))
      result.pattern = Weekly(weekday: day)
    of 3:
      let picked = datePicker(localId("calendar-date", id.id), value.pattern.selectedDate(), tabIndex)
      result.pattern = SpecificDate(date: picked)
    else:
      result.pattern = Daily()
    result.time = timePicker(localId("calendar-time", id.id), value.time, tabIndex)
