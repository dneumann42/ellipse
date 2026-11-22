import std/[os, algorithm, strutils]
import owl/[settings, serde]

type
  LanguageMode* = object
    name*: string
    extensions*: seq[string]
    keywords*: seq[string]
    symbols*: seq[string]
    types*, builtins*, literals*: seq[string]
    lineComments*, stringDelimiters*: seq[string]
  LanguageRegistry* = object
    languages*: seq[LanguageMode]

proc readLanguage(path, source: string): LanguageMode =
  try:
    decode(evaluate(settingsLibrary(), settingsRoot(), path, source), result)
    if result.name.len == 0:
      raise newException(ValueError, "mode name is required")
    for ext in result.extensions.mitems:
      ext = ext.strip(chars = {'.'}).toLowerAscii()
      if ext.len == 0: raise newException(ValueError, "empty extension")
    for delimiter in result.stringDelimiters.mitems:
      if delimiter == "double-quote": delimiter = "\""
      elif delimiter == "single-quote": delimiter = "'"
  except CatchableError as e:
    raise newException(ValueError, path & ": " & e.msg)

const
  builtinLanguagesDirectory* = currentSourcePath().parentDir / "modes"
  nimModePath = builtinLanguagesDirectory / "nim" / "mode.owl"
  nimModeSource = staticRead(nimModePath)

proc builtinLanguages*(): LanguageRegistry =
  ## Available in installed apps without a modes directory.
  var registry {.threadvar.}: LanguageRegistry
  if registry.languages.len == 0:
    registry.languages.add readLanguage(nimModePath, nimModeSource)
  registry

proc loadLanguages*(directory: string): LanguageRegistry =
  var paths: seq[string]
  if not dirExists(directory):
    raise newException(IOError, "Mode directory does not exist: " & directory)
  for path in walkDirRec(directory):
    if path.endsWith(".owl"): paths.add path
  paths.sort()
  for path in paths:
    let mode = readLanguage(path, readFile(path))
    for existing in result.languages:
      if existing.name == mode.name:
        raise newException(ValueError, path & ": duplicate mode: " & mode.name)
    result.languages.add mode

proc languageFor*(registry: LanguageRegistry, path: string): LanguageMode =
  let ext = splitFile(path).ext.strip(chars = {'.'}).toLowerAscii()
  for mode in registry.languages:
    if ext in mode.extensions: return mode
  LanguageMode(name: "Plain Text")
