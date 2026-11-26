## cvn — компилятор Convulsions (kernel MVP).

import std/[os, strutils]
import cvnc/[diag, options, driver]

const Version = "0.3.0"

proc usage() =
  echo """cvn """ & Version & """ — Convulsions compiler (kernel MVP)

Usage:
  cvn build <entry.conv> [-o <bin>] [--emit-c=DIR] [--cc=CMD]
                         [--cflags=FLAGS] [--path=DIR{;DIR}]
                         [--runtime-path=DIR] [--profile=kernel]
                         [--dump-ast] [--dump-hir] [--keep-temp]
  cvn run <entry.conv> [-- <args>]
  cvn version

Only the kernel profile and the native (C11) backend are implemented in v0.1.
"""

proc needValue(argv: seq[string]; i: var int; flag: string): string =
  if i + 1 >= argv.len:
    fail("E-CLI", "", 0, 0, "флаг " & flag & " требует значения")
  inc i
  argv[i]

proc parseCli(argv: seq[string]): tuple[cmd: string, opts: BuildOptions,
                                        progArgs: seq[string]] =
  if argv.len == 0:
    fail("E-CLI", "", 0, 0, "не указана команда (build, run, version)")
  result.cmd = argv[0]
  result.opts.profile = "kernel"
  result.opts.searchPaths = defaultSearchPaths()
  result.opts.runtimePath = defaultRuntimePath()
  var i = 1
  while i < argv.len:
    let a = argv[i]
    if a == "--":
      for k in i + 1 ..< argv.len:
        result.progArgs.add argv[k]
      break
    elif a == "-o" or a == "--out":
      result.opts.outFile = needValue(argv, i, a)
    elif a.startsWith("--out="):
      result.opts.outFile = a["--out=".len .. ^1]
    elif a.startsWith("--emit-c="):
      result.opts.emitCDir = a["--emit-c=".len .. ^1]
    elif a == "--emit-c":
      result.opts.emitCDir = needValue(argv, i, a)
    elif a.startsWith("--cc="):
      result.opts.cc = a["--cc=".len .. ^1]
    elif a == "--cc":
      result.opts.cc = needValue(argv, i, a)
    elif a.startsWith("--cflags="):
      result.opts.cflags = a["--cflags=".len .. ^1]
    elif a == "--cflags":
      result.opts.cflags = needValue(argv, i, a)
    elif a.startsWith("--path="):
      result.opts.searchPaths = splitPaths(a["--path=".len .. ^1])
    elif a == "--path":
      result.opts.searchPaths = splitPaths(needValue(argv, i, a))
    elif a.startsWith("--runtime-path="):
      result.opts.runtimePath = a["--runtime-path=".len .. ^1]
    elif a == "--runtime-path":
      result.opts.runtimePath = needValue(argv, i, a)
    elif a.startsWith("--profile="):
      result.opts.profile = a["--profile=".len .. ^1]
    elif a == "--profile":
      result.opts.profile = needValue(argv, i, a)
    elif a == "--dump-ast":
      result.opts.dumpAst = true
    elif a == "--dump-hir":
      result.opts.dumpHir = true
    elif a == "--keep-temp":
      result.opts.keepTemp = true
    elif a.startsWith("-"):
      fail("E-CLI", "", 0, 0, "неизвестный флаг: " & a)
    else:
      if result.opts.entry.len == 0:
        result.opts.entry = a
      else:
        result.progArgs.add a
    inc i

proc realMain(argv: seq[string]): int =
  let cmd = if argv.len > 0: argv[0] else: ""
  if cmd in ["version", "--version", "-v"]:
    echo "cvn " & Version
    return 0
  if cmd in ["help", "--help", "-h"] or argv.len == 0:
    usage()
    return 0
  if cmd notin ["build", "run"]:
    stderr.writeLine "cvn: неизвестная команда: " & cmd
    usage()
    return 2

  let parsed = parseCli(argv)
  var opts = parsed.opts
  if opts.entry.len == 0:
    fail("E-CLI", "", 0, 0, "не указан входной файл")
  if opts.profile != "kernel":
    fail("E-PROFILE-CONFLICT", "", 0, 0,
         "профиль " & opts.profile & " не поддерживается в v0.1",
         "в 0.1 реализован только kernel (user — v0.8)")

  if parsed.cmd == "build":
    discard build(opts)
    return 0
  else:
    return runMain(opts, parsed.progArgs)

proc main() =
  try:
    quit(realMain(commandLineParams()))
  except CvnError as e:
    stderr.writeLine render(e)
    quit(1)
  except CatchableError as e:
    stderr.writeLine "error[E-INTERNAL]: " & e.msg
    quit(2)

main()
