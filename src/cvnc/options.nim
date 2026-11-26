## Опции сборки и пути по умолчанию.

import std/[os, strutils]

type
  BuildOptions* = object
    entry*: string
    outFile*: string
    emitCDir*: string
    cc*: string
    cflags*: string
    runtimePath*: string
    profile*: string
    searchPaths*: seq[string]
    dumpAst*: bool
    dumpHir*: bool
    keepTemp*: bool
    workers*: int
    stackKb*: int

proc defaultSearchPaths*(): seq[string] =
  let app = getAppDir()
  for cand in [app / "stdlib", app / ".." / "stdlib"]:
    if dirExists(cand):
      result.add cand
  if result.len == 0:
    result.add "stdlib"

proc defaultRuntimePath*(): string =
  let app = getAppDir()
  for cand in [app / "runtime", app / ".." / "runtime"]:
    if fileExists(cand / "cvnrt.h"):
      return cand
  "runtime"

proc splitPaths*(s: string): seq[string] =
  for p in s.split(PathSep):
    if p.len > 0:
      result.add p
