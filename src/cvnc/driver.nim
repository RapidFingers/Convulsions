## Драйвер: пайплайн, вызов cc, временный каталог.

import std/[os, osproc, streams, strutils, tempfiles]
import diag, options, modules, sema, lower, cgen, hir, ast

const exeSuffix = when defined(windows): ".exe" else: ""

proc probeCC(cand: string): bool =
  try:
    let p = startProcess(cand, args = @["--version"],
                         options = {poUsePath, poStdErrToStdOut})
    discard p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    result = code == 0
  except OSError:
    result = false

proc findCC(explicit: string): string =
  var cands: seq[string]
  if explicit.len > 0:
    cands = @[explicit]
  elif existsEnv("CC"):
    cands = @[getEnv("CC")]
  else:
    cands = @["gcc", "clang", "cc"]
  for c in cands:
    if probeCC(c):
      return c
  fail("E-CC-NOT-FOUND", "", 0, 0, "C-компилятор не найден",
       "укажите --cc=<cmd> или установите gcc в PATH")

proc runCC(cc: string; args: seq[string]): tuple[code: int, output: string] =
  try:
    let p = startProcess(cc, args = args,
                         options = {poUsePath, poStdErrToStdOut})
    result.output = p.outputStream.readAll()
    result.code = p.waitForExit()
    p.close()
  except OSError:
    fail("E-CC-NOT-FOUND", "", 0, 0, "не удалось запустить C-компилятор: " & cc)

proc build*(opts: BuildOptions): string =
  let mods = loadProgram(opts.entry, opts)
  if opts.dumpAst:
    for m in mods:
      echo "=== ", m.path, " (", m.file, ") ==="
      echo dumpAst(m.ast)
  let prog = analyze(mods, opts)
  let hirs = lowerProgram(prog)
  if opts.dumpHir:
    for hp in hirs:
      echo dumpHir(hp)
  let csrc = emitC(prog, hirs)

  let tmp = createTempDir("cvn-", "")
  try:
    let cfile = tmp / "main.c"
    writeFile(cfile, csrc)
    if opts.emitCDir.len > 0:
      createDir(opts.emitCDir)
      writeFile(opts.emitCDir / "main.c", csrc)

    var outPath = opts.outFile
    if outPath.len == 0:
      outPath = extractFilename(opts.entry)
      if outPath.toLowerAscii.endsWith(".conv"):
        outPath.setLen(outPath.len - 5)
      outPath.add exeSuffix
    let outAbs = absolutePath(outPath)
    let outDir = parentDir(outAbs)
    if outDir.len > 0 and not dirExists(outDir):
      createDir(outDir)

    let runtimeDir = absolutePath(opts.runtimePath)
    if not fileExists(runtimeDir / "cvnrt.c") or
       not fileExists(runtimeDir / "cvnrt_alloc.c") or
       not fileExists(runtimeDir / "cvnrt_fiber.c") or
       not fileExists(runtimeDir / "cvnrt_net.c") or
       not fileExists(runtimeDir / "cvnrt_channel.c"):
      fail("E-IO", opts.entry, 0, 0,
           "рантайм не найден: " & runtimeDir,
           "укажите --runtime-path=<dir>")
    let cc = findCC(opts.cc)
    var args = @["-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I", runtimeDir]
    if opts.cflags.len > 0:
      for f in opts.cflags.splitWhitespace():
        if f.len > 0:
          args.add f
    args.add @["-o", outAbs, absolutePath(cfile), runtimeDir / "cvnrt.c",
               runtimeDir / "cvnrt_alloc.c", runtimeDir / "cvnrt_fiber.c",
               runtimeDir / "cvnrt_net.c", runtimeDir / "cvnrt_channel.c"]
    when defined(windows):
      args.add "-lws2_32"
    else:
      args.add "-pthread"

    let r = runCC(cc, args)
    if r.code != 0:
      let shown = if r.output.len > 4000: r.output[0 ..< 4000] else: r.output
      fail("E-CC-FAILED", opts.entry, 0, 0,
           "cc завершился с кодом " & $r.code, shown)
    result = outPath
  finally:
    if opts.keepTemp:
      stderr.writeLine "cvn: временный каталог сохранён: " & tmp
    else:
      removeDir(tmp)

proc runMain*(opts: BuildOptions; progArgs: seq[string]): int =
  let exe = build(opts)
  var runExe = absolutePath(exe)
  if not fileExists(runExe) and fileExists(runExe & exeSuffix):
    runExe.add exeSuffix
  let p = startProcess(runExe, args = progArgs,
                       options = {poParentStreams, poUsePath})
  result = p.waitForExit()
  p.close()
