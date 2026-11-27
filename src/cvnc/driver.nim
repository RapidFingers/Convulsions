## Драйвер: пайплайн, вызов cc, временный каталог.

import std/[os, osproc, streams, strutils, tempfiles]
import diag, options, modules, sema, lower, cgen, hir, ast, progress

const exeSuffix = when defined(windows): ".exe" else: ""

proc probeCC(cand: string): bool =
  progress.verbose("проверка cc: " & cand)
  try:
    let p = startProcess(cand, args = @["--version"],
                         options = {poUsePath, poStdErrToStdOut})
    discard p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    result = code == 0
  except OSError:
    result = false
  progress.verbose("cc " & cand & ": " & (if result: "ok" else: "не найден"))

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
      progress.verbose("cc найден: " & c)
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
  progress.header("сборка " & opts.entry)
  progress.verbose("entry: " & absolutePath(opts.entry))
  progress.verbose("профиль: " & opts.profile & ", бэкенд: C11")
  progress.verbose("runtime path: " & absolutePath(opts.runtimePath))
  progress.verbose("search paths: " & opts.searchPaths.join(";"))

  progress.stage("импорт модулей")
  let mods = loadProgram(opts.entry, opts)
  progress.stageDone("модулей: " & $mods.len)
  for m in mods:
    progress.verbose("модуль: " & (if m.path.len > 0: m.path else: "<entry>") &
                     " (" & m.file & ")")

  if opts.dumpAst:
    for m in mods:
      echo "=== ", m.path, " (", m.file, ") ==="
      echo dumpAst(m.ast)

  progress.stage("семантический анализ")
  let prog = analyze(mods, opts)
  progress.stageDone("процедур: " & $prog.procs.len & ", типов: " &
                     $prog.objectTypes.len)
  progress.verbose("символов: " & $prog.syms.len)

  progress.stage("понижение в HIR")
  let hirs = lowerProgram(prog)
  var instrCount = 0
  for hp in hirs:
    instrCount += hp.instrs.len
  progress.stageDone("процедур: " & $hirs.len & ", инструкций: " &
                     $instrCount)
  if opts.dumpHir:
    for hp in hirs:
      echo dumpHir(hp)

  progress.stage("генерация C")
  let csrc = emitC(prog, hirs)
  progress.stageDone("C: " & formatFloat(float(csrc.len) / 1024.0,
                                         ffDecimal, 1) & " КиБ, строк: " &
                     $csrc.splitLines.len)

  progress.stage("подготовка")
  let tmp = createTempDir("cvn-", "")
  try:
    let cfile = tmp / "main.c"
    writeFile(cfile, csrc)
    if opts.emitCDir.len > 0:
      createDir(opts.emitCDir)
      writeFile(opts.emitCDir / "main.c", csrc)
      progress.verbose("emit-c: " & absolutePath(opts.emitCDir / "main.c"))

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
    progress.stageDone("runtime: " & runtimeDir & ", файлов: 5",
                       @["временный каталог: " & tmp,
                         "результат: " & outAbs])

    progress.stage("компиляция C")
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
    progress.verbose("команда cc: " & cc & " " & args.join(" "))

    let r = runCC(cc, args)
    if r.code != 0:
      let shown = if r.output.len > 4000: r.output[0 ..< 4000] else: r.output
      fail("E-CC-FAILED", opts.entry, 0, 0,
           "cc завершился с кодом " & $r.code, shown)
    progress.stageDone(cc)
    progress.success("готово: " & outPath)
    result = outPath
  finally:
    if opts.keepTemp:
      progress.info("временный каталог сохранён: " & tmp)
    else:
      removeDir(tmp)

proc runMain*(opts: BuildOptions; progArgs: seq[string]): int =
  let exe = build(opts)
  var runExe = absolutePath(exe)
  if not fileExists(runExe) and fileExists(runExe & exeSuffix):
    runExe.add exeSuffix
  progress.info("запуск: " & runExe)
  let p = startProcess(runExe, args = progArgs,
                       options = {poParentStreams, poUsePath})
  result = p.waitForExit()
  p.close()
  progress.verbose("код возврата: " & $result)

