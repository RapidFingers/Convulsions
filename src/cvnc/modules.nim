## Загрузка модулей: поиск, парсинг, порядок зависимостей, циклы.

import std/[os, strutils, tables]
import diag, ast, parser, lexer, symbols, options

type
  Loader = object
    opts: BuildOptions
    cache: Table[string, ModuleInfo]   # абсолютный путь -> модуль
    state: Table[string, int]          # 1 = в процессе, 2 = готов
    order: seq[ModuleInfo]

proc moduleRelPath(name: string): string =
  name.replace("/", $DirSep) & ".conv"

proc resolveModuleFile(name, fromFile: string;
                       searchPaths: seq[string]): string =
  let rel = moduleRelPath(name)
  for root in searchPaths:
    let cand = root / rel
    if fileExists(cand):
      return absolutePath(cand)
  let near = fromFile.parentDir / rel
  if fileExists(near):
    return absolutePath(near)

proc entryModuleName(entry: string): string =
  let abs = absolutePath(entry)
  let stem = abs.changeFileExt("")
  let cwd = getCurrentDir()
  if stem.startsWith(cwd):
    result = stem[cwd.len .. ^1].strip(chars = {'/', '\\'})
  else:
    result = extractFilename(stem)
  result = result.replace('\\', '/')

proc loadFile(l: var Loader; file, moduleName: string): ModuleInfo =
  if l.state.getOrDefault(file, 0) == 1:
    fail("E-IMPORT-CYCLE", file, 0, 0,
         "циклический импорт: модуль '" & moduleName & "' уже загружается",
         "разорвите цикл через таблицу колбэков или интерфейс")
  if l.state.getOrDefault(file, 0) == 2:
    return l.cache[file]

  l.state[file] = 1
  var m = ModuleInfo(path: moduleName, file: file, profile: "kernel",
                     headers: @[], exports: initTable[string, Symbol](),
                     importNodes: @[], imported: initTable[string, ModuleInfo]())
  let src = readFile(file)
  let toks = lex(src, file)
  m.ast = parseModule(toks, file)

  for stmt in m.ast.stmts:
    case stmt.kind
    of nkPragma:
      case stmt.pragmaName
      of "profile":
        if stmt.pragmaValue == "user":
          fail("E-PROFILE-CONFLICT", file, stmt.line, stmt.col,
               "профиль user не поддерживается в v0.1 (будет в v0.8)",
               "соберите модуль с {.profile: kernel.}")
        elif stmt.pragmaValue != "kernel":
          fail("E-PROFILE-CONFLICT", file, stmt.line, stmt.col,
               "неизвестный профиль: " & stmt.pragmaValue)
        m.profile = stmt.pragmaValue
      of "header":
        m.headers.add stmt.pragmaValue
      else:
        fail("E-PRAGMA-UNSUPPORTED", file, stmt.line, stmt.col,
             "прагма модуля '{" & stmt.pragmaName & ".}' не поддерживается в v0.1",
             "в v0.1 допустимы только {.profile.} и {.header.}")
    of nkFromImport:
      let childFile = resolveModuleFile(stmt.modulePath, file, l.opts.searchPaths)
      if childFile.len == 0:
        fail("E-IMPORT-NOT-FOUND", file, stmt.line, stmt.col,
             "модуль '" & stmt.modulePath & "' не найден",
             "пути поиска: " & l.opts.searchPaths.join(", "))
      let child = l.loadFile(childFile, stmt.modulePath)
      m.imported[stmt.modulePath] = child
      m.importNodes.add stmt
    else:
      discard

  l.state[file] = 2
  l.cache[file] = m
  l.order.add m
  result = m

proc loadProgram*(entry: string; opts: BuildOptions): seq[ModuleInfo] =
  if not fileExists(entry):
    fail("E-IO", entry, 0, 0, "входной файл не найден: " & entry)
  var l = Loader(opts: opts, cache: initTable[string, ModuleInfo](),
                 state: initTable[string, int](), order: @[])
  let absEntry = absolutePath(entry)
  let name = entryModuleName(entry)
  let main = l.loadFile(absEntry, name)
  main.isEntry = true
  result = l.order
