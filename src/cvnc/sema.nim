## Семантический анализ: имена, типы, импорты, профиль, builtin deinit.

import std/[tables, strutils, algorithm]
import diag, ast, types, symbols, options

type
  Program* = ref object
    modules*: seq[ModuleInfo]
    entry*: ModuleInfo
    syms*: seq[Symbol]
    procs*: seq[Symbol]
    objectTypes*: seq[Type]
    entryMain*: Symbol
    strings*: seq[string]
    opts*: BuildOptions

  Sema = ref object
    prog: Program
    curMod: ModuleInfo
    procSym: Symbol
    scopes: seq[Scope]
    inDefer: int
    builtins: Table[string, Type]
    builtinDeinit: Symbol
    builtinAssert: Symbol
    builtinPanic: Symbol
    builtinSizes: Table[string, Symbol]
    builtinCreate: Symbol
    builtinDestroy: Symbol
    typeCache: Table[string, Type]
    procCache: Table[string, Symbol]
    pending: seq[Symbol]
    typeEnv: Table[string, Type]
    monoDepth: int
    loopDepth: int
    controlDepth: int
    autoTryDepth: int
    preserveResult: int

proc addSym(s: Sema; sym: Symbol): int =
  sym.id = s.prog.syms.len
  s.prog.syms.add sym
  sym.id

proc makeBuiltins(): Table[string, Type] =
  result = initTable[string, Type]()
  result["void"] = newType(tyVoid, "void")
  result["int"] = newType(tyInt, "int")
  result["bool"] = newType(tyBool, "bool")
  result["char"] = newType(tyChar, "char")
  result["string"] = newType(tyString, "string")
  result["Rune"] = newType(tyRune, "Rune")
  result["ErrorCode"] = newType(tyErrorCode, "ErrorCode")
  result["pointer"] = newType(tyPointer, "pointer")

proc errorCodeFor(name: string): int32 =
  case name
  of "OutOfMemory", "outOfMemory": 1'i32
  of "NoAllocator", "noAllocator": 2'i32
  of "Invalid", "invalid", "invalidArgument": 3'i32
  of "BadAlignment", "badAlignment": 4'i32
  of "Bounds", "bounds": 5'i32
  of "Io", "io": 6'i32
  of "Eof", "eof": 7'i32
  of "Cancelled", "cancelled": 8'i32
  of "Task", "task": 9'i32
  of "Closed", "closed": 10'i32
  of "WouldBlock", "wouldBlock": 11'i32
  else: -1'i32

proc push(s: Sema) =
  s.scopes.add newScope(s.scopes[^1])

proc pop(s: Sema) =
  s.scopes.setLen(s.scopes.len - 1)

proc define(s: Sema; sym: Symbol) =
  s.scopes[^1].define(sym)

proc lookup(s: Sema; name: string): Symbol =
  for i in countdown(s.scopes.len - 1, 0):
    let sym = s.scopes[i].lookup(name)
    if sym != nil:
      return sym
  nil

proc sanitizeIdent(s: string): string =
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      result.add c
    else:
      result.add '_'

proc procCName(m: ModuleInfo; name: string): string =
  "cvn_m_" & sanitizeIdent(m.path) & "_" & sanitizeIdent(name)

proc pragmaVal(pragmas: seq[AstNode]; name: string): string =
  for p in pragmas:
    if p.pragmaName == name:
      return p.pragmaValue

proc hasPragma(pragmas: seq[AstNode]; name: string): bool =
  for p in pragmas:
    if p.pragmaName == name:
      return true

proc addHeader(m: ModuleInfo; value: string) =
  if value.len > 0 and value notin m.headers:
    m.headers.add value

proc validatePragmas(s: Sema; pragmas: seq[AstNode]; allowed: seq[string];
                     where: string) =
  for p in pragmas:
    if p.pragmaName notin allowed:
      fail("E-PRAGMA-UNSUPPORTED", s.curMod.file, p.line, p.col,
           "прагма '{" & p.pragmaName & ".}' у " & where &
           " не поддерживается в v0.1",
           "допустимы: " & allowed.join(", "))

proc typeFromNode(s: Sema; n: AstNode): Type

proc instantiateType(s: Sema; tmpl: Symbol; args: seq[Type];
                     where: AstNode): Type

proc resolveFieldsInto(s: Sema; t: Type; fieldNodes: seq[AstNode];
                       where: AstNode)

proc typeFromNode(s: Sema; n: AstNode): Type =
  case n.kind
  of nkTypeName:
    if s.typeEnv.hasKey(n.typeName):
      return s.typeEnv[n.typeName]
    if s.builtins.hasKey(n.typeName):
      return s.builtins[n.typeName]
    let sym = s.curMod.scope.lookup(n.typeName)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.line, n.col,
           "неизвестный тип: " & n.typeName)
    if sym.kind != skType:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "'" & n.typeName & "' не является типом")
    if sym.typ.isGeneric:
      fail("E-GENERIC-NEEDS-ARGS", s.curMod.file, n.line, n.col,
           "generic-типу '" & n.typeName & "' нужны аргументы типа",
           "например: " & n.typeName & "[int]")
    sym.typ
  of nkTypeApply:
    let sym = s.curMod.scope.lookup(n.appliedName)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.line, n.col,
           "неизвестный тип: " & n.appliedName)
    if sym.kind != skType:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "'" & n.appliedName & "' не является типом")
    if not sym.typ.isGeneric:
      fail("E-GENERIC-NOT-GENERIC", s.curMod.file, n.line, n.col,
           "'" & n.appliedName & "' не является generic-типом")
    if n.appliedArgs.len != sym.typ.genericParams.len:
      fail("E-GENERIC-ARG-COUNT", s.curMod.file, n.line, n.col,
           "тип '" & n.appliedName & "' ожидает " &
           $sym.typ.genericParams.len & " аргумент(ов), получено " &
           $n.appliedArgs.len)
    var args: seq[Type]
    for a in n.appliedArgs:
      args.add s.typeFromNode(a)
    s.instantiateType(sym, args, n)
  of nkPtrType:
    let inner = s.typeFromNode(n.elemType)
    let t = newType(tyPtr)
    t.elem = inner
    t
  of nkResultType:
    let inner = s.typeFromNode(n.elemType)
    let t = newType(tyResult)
    t.elem = inner
    t
  else:
    fail("E-PARSE", s.curMod.file, n.line, n.col, "ожидался тип")

proc findModule(s: Sema; path: string): ModuleInfo =
  for m in s.prog.modules:
    if m.path == path:
      return m
  nil

proc instantiateType(s: Sema; tmpl: Symbol; args: seq[Type];
                     where: AstNode): Type =
  if not tmpl.typ.isGeneric:
    fail("E-GENERIC-NOT-GENERIC", s.curMod.file, where.line, where.col,
         "'" & tmpl.name & "' не является generic-типом")
  if args.len != tmpl.typ.genericParams.len:
    fail("E-GENERIC-ARG-COUNT", s.curMod.file, where.line, where.col,
         "тип '" & tmpl.name & "' ожидает " &
         $tmpl.typ.genericParams.len & " аргумент(ов), получено " &
         $args.len)
  let key = $tmpl.id & "|" & typeArgsKey(args)
  if s.typeCache.hasKey(key):
    return s.typeCache[key]
  var names: seq[string]
  for a in args:
    names.add typeName(a)
  let t = newType(tyObject, tmpl.name & "[" & names.join(", ") & "]")
  t.ownerModule = tmpl.modulePath
  t.templateId = tmpl.id
  t.typeArgs = args
  t.declLine = where.line
  t.declCol = where.col
  t.declFile = s.curMod.file
  t.cname = "cvn_m_" & cSanitize(tmpl.modulePath) & "_" &
            cSanitize(tmpl.name) & "_g_" & cSanitize(typeArgsKey(args))
  s.typeCache[key] = t
  let owner = s.findModule(tmpl.modulePath)
  if owner == nil:
    fail("E-INTERNAL", s.curMod.file, where.line, where.col,
         "модуль шаблона не найден: " & tmpl.modulePath)
  let oldMod = s.curMod
  let oldEnv = s.typeEnv
  s.curMod = owner
  var env = initTable[string, Type]()
  for i, p in tmpl.typ.genericParams:
    env[p] = args[i]
  s.typeEnv = env
  s.resolveFieldsInto(t, tmpl.node.typeFields, where)
  s.curMod = oldMod
  s.typeEnv = oldEnv
  s.prog.objectTypes.add t
  t

proc fieldIndex(t: Type; name: string): int =
  if t.isNil:
    return -1
  for i, f in t.fields:
    if f.name == name:
      return i
  -1

proc fieldVisible(s: Sema; t: Type; f: Field): bool =
  f.exported or t.ownerModule == s.curMod.path

proc isAllocatorType(t: Type): bool =
  t != nil and t.kind == tyObject and t.opaque and
    t.cname == "cvn_allocator"

proc ptrResultType(t: Type): Type =
  let p = newType(tyPtr)
  p.elem = t
  let r = newType(tyResult)
  r.elem = p
  r

proc taskType(t: Type): Type =
  let r = newType(tyTask)
  r.elem = t
  r

proc resultOfTask(t: Type): Type =
  let r = newType(tyResult)
  r.elem = t.elem
  r

proc typeFromName(s: Sema; n: AstNode; what: string): Type =
  if n.kind == nkTypeApply:
    return s.typeFromNode(n)
  if n.kind != nkIdent:
    fail("E-TYPE", s.curMod.file, n.line, n.col,
         what & ": ожидалось имя типа")
  if s.builtins.hasKey(n.name):
    return s.builtins[n.name]
  let sym = s.lookup(n.name)
  if sym == nil or sym.kind != skType:
    fail("E-TYPE", s.curMod.file, n.line, n.col,
         what & ": неизвестный тип " & n.name)
  if sym.typ.isGeneric:
    fail("E-GENERIC-NEEDS-ARGS", s.curMod.file, n.line, n.col,
         what & ": generic-типу '" & n.name & "' нужны аргументы",
         "например: " & n.name & "[int]")
  sym.typ

proc declareTypeShell(s: Sema; n: AstNode) =
  if s.curMod.scope.hasOwn(n.declName):
    fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
         "повторное объявление: " & n.declName)
  s.validatePragmas(n.declPragmas, @["importc", "header"], "типа")
  let importC = pragmaVal(n.declPragmas, "importc")
  let t = newType(tyObject, n.declName)
  t.ownerModule = s.curMod.path
  t.declLine = n.line
  t.declCol = n.col
  t.declFile = s.curMod.file
  if n.genericParams.len > 0:
    if importC.len > 0:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "importc-тип не может быть generic")
    t.isGeneric = true
    t.genericParams = n.genericParams
    t.cname = "cvn_m_" & cSanitize(s.curMod.path) & "_" &
              cSanitize(n.declName) & "_g_template"
  elif importC.len > 0:
    t.cname = importC
    t.opaque = true
    n.importedDecl = true
    n.cNameDecl = importC
  else:
    t.cname = "cvn_m_" & cSanitize(s.curMod.path) & "_" &
              cSanitize(n.declName)
  let sym = Symbol(kind: skType, name: n.declName, typ: t, node: n,
                   exported: n.exportedDecl, modulePath: s.curMod.path,
                   isGeneric: n.genericParams.len > 0,
                   genericParams: n.genericParams)
  discard s.addSym(sym)
  t.templateId = sym.id
  s.curMod.scope.define(sym)
  if n.exportedDecl:
    s.curMod.addExport(sym)
  n.symId = sym.id
  s.curMod.addHeader(pragmaVal(n.declPragmas, "header"))
  if not t.opaque and not t.isGeneric:
    s.prog.objectTypes.add t

proc resolveFieldsInto(s: Sema; t: Type; fieldNodes: seq[AstNode];
                       where: AstNode) =
  if fieldNodes.len == 0:
    fail("E-TYPE", s.curMod.file, where.line, where.col,
         "пустой object запрещён",
         "объект без полей не имеет C-представления; добавьте поле")
  var seen = initTable[string, bool]()
  for fn in fieldNodes:
    let key = cSanitize(fn.declFieldName)
    if seen.hasKey(key):
      fail("E-DUP-FIELD", s.curMod.file, fn.line, fn.col,
           "повторяющееся поле: " & fn.declFieldName)
    seen[key] = true
    let ft = s.typeFromNode(fn.declFieldType)
    if ft.kind in {tyVoid, tyResult}:
      fail("E-TYPE", s.curMod.file, fn.line, fn.col,
           "поле '" & fn.declFieldName & "' не может иметь тип " & typeName(ft))
    t.fields.add Field(name: fn.declFieldName, typ: ft,
                       exported: fn.declFieldExported)

proc resolveTypeFields(s: Sema; n: AstNode) =
  let sym = s.prog.syms[n.symId]
  let t = sym.typ
  if t.opaque or t.isGeneric:
    return
  s.resolveFieldsInto(t, n.typeFields, n)

proc declareProc(s: Sema; n: AstNode) =
  if s.curMod.scope.hasOwn(n.procName):
    fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
         "повторное объявление: " & n.procName)
  s.validatePragmas(n.procPragmas,
                    @["importc", "cdecl", "header", "propagate"], "процедуры")
  let wantPropagate = hasPragma(n.procPragmas, "propagate")
  if n.genericParams.len > 0:
    if pragmaVal(n.procPragmas, "importc").len > 0:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "generic-процедура не может быть importc")
    if n.body == nil:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "generic-процедура должна иметь тело")
    let ptype = newType(tyProc)
    let sym = Symbol(kind: skProc, name: n.procName, typ: ptype, node: n,
                     exported: n.exportedProc, modulePath: s.curMod.path,
                     isGeneric: true, genericParams: n.genericParams,
                     propagate: wantPropagate)
    for p in n.params:
      sym.paramNames.add p.paramName
      sym.paramVars.add p.paramVar
    discard s.addSym(sym)
    n.symId = sym.id
    s.curMod.scope.define(sym)
    if n.exportedProc:
      s.curMod.addExport(sym)
    return
  var params: seq[Type]
  var pnames: seq[string]
  var pvars: seq[bool]
  for p in n.params:
    let pt = s.typeFromNode(p.paramTypeNode)
    if p.paramVar and pt.kind == tyPtr:
      fail("E-UNSUPPORTED", s.curMod.file, p.line, p.col,
           "var-параметр типа ptr T не поддерживается в v0.5",
           "передавайте ptr T по значению")
    params.add pt
    pnames.add p.paramName
    pvars.add p.paramVar
  let ret = s.typeFromNode(n.retTypeNode)
  let ptype = newType(tyProc)
  ptype.params = params
  ptype.ret = ret

  let importName = pragmaVal(n.procPragmas, "importc")
  let isExternal = importName.len > 0
  if isExternal and wantPropagate:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "{.propagate.} несовместима с importc")
  if isExternal and n.body != nil:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "importc-процедура не может иметь тело")
  if not isExternal and n.body == nil:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "процедура без тела требует {.importc.}",
         "импорт C-функции помечается {.importc: \"name\", cdecl.}")

  let sym = Symbol(kind: skProc, name: n.procName, typ: ptype, node: n,
                   exported: n.exportedProc, external: isExternal,
                   modulePath: s.curMod.path,
                   cname: (if isExternal: importName
                           else: procCName(s.curMod, n.procName)),
                   propagate: wantPropagate)
  sym.paramNames = pnames
  sym.paramVars = pvars
  sym.typeEnv = initTable[string, Type]()
  discard s.addSym(sym)
  n.symId = sym.id
  s.curMod.scope.define(sym)
  if n.exportedProc:
    s.curMod.addExport(sym)
  s.prog.procs.add sym
  s.curMod.addHeader(pragmaVal(n.procPragmas, "header"))

  var seen = initTable[string, bool]()
  for p in n.params:
    if seen.hasKey(p.paramName):
      fail("E-DUP-SYMBOL", s.curMod.file, p.line, p.col,
           "повторяющийся параметр: " & p.paramName)
    seen[p.paramName] = true
    let psym = Symbol(kind: skParam, name: p.paramName,
                      typ: s.typeFromNode(p.paramTypeNode), node: p,
                      byRef: p.paramVar)
    discard s.addSym(psym)
    p.symId = psym.id
    sym.paramSyms.add psym

proc instantiateProc(s: Sema; tmpl: Symbol; args: seq[Type];
                     bindings: Table[string, Type];
                     callNode: AstNode): Symbol =
  if not tmpl.isGeneric:
    fail("E-GENERIC-NOT-GENERIC", s.curMod.file, callNode.line,
         callNode.col, "'" & tmpl.name & "' не является generic-процедурой")
  if args.len != tmpl.genericParams.len:
    fail("E-GENERIC-ARG-COUNT", s.curMod.file, callNode.line,
         callNode.col, "generic-процедура '" & tmpl.name & "' ожидает " &
         $tmpl.genericParams.len & " аргумент(ов) типа")
  if s.monoDepth + 1 > 64:
    fail("E-MONO-DEPTH", s.curMod.file, callNode.line, callNode.col,
         "превышена глубина мономорфизации (64) для '" & tmpl.name & "'")
  let key = $tmpl.id & "|" & typeArgsKey(args)
  if s.procCache.hasKey(key):
    return s.procCache[key]
  let owner = s.findModule(tmpl.modulePath)
  if owner == nil:
    fail("E-INTERNAL", s.curMod.file, callNode.line, callNode.col,
         "модуль шаблона не найден: " & tmpl.modulePath)
  let clone = cloneAst(tmpl.node)
  let oldMod = s.curMod
  let oldEnv = s.typeEnv
  s.curMod = owner
  s.typeEnv = bindings
  let ptype = newType(tyProc)
  for p in clone.params:
    ptype.params.add s.typeFromNode(p.paramTypeNode)
  ptype.ret = s.typeFromNode(clone.retTypeNode)
  let inst = Symbol(kind: skProc, name: tmpl.name,
                    cname: procCName(owner, tmpl.name) & "_g_" &
                           cSanitize(typeArgsKey(args)),
                    typ: ptype, node: clone, exported: false,
                    modulePath: tmpl.modulePath,
                    paramNames: tmpl.paramNames, paramVars: tmpl.paramVars,
                    templateId: tmpl.id, typeArgs: args,
                    monoDepth: s.monoDepth + 1, typeEnv: bindings,
                    propagate: tmpl.propagate)
  discard s.addSym(inst)
  for i, p in clone.params:
    let psym = Symbol(kind: skParam, name: p.paramName,
                      typ: ptype.params[i], node: p,
                      byRef: p.paramVar)
    discard s.addSym(psym)
    p.symId = psym.id
    inst.paramSyms.add psym
  s.curMod = oldMod
  s.typeEnv = oldEnv
  s.procCache[key] = inst
  s.prog.procs.add inst
  s.pending.add inst
  inst

proc setupModule(s: Sema; m: ModuleInfo) =
  s.curMod = m
  m.scope = newScope(nil)
  for imp in m.importNodes:
    let child = m.imported[imp.modulePath]
    if imp.importAll:
      var names: seq[string]
      for name in child.exports.keys:
        names.add name
      names.sort()
      for name in names:
        if m.scope.hasOwn(name):
          fail("E-DUP-SYMBOL", m.file, imp.line, imp.col,
               "имя '" & name & "' уже импортировано или объявлено",
               "import " & imp.modulePath & " вносит все экспорты; " &
               "конфликтующие имена импортируйте выборочно через from")
        m.scope.define(child.exports[name])
    else:
      for name in imp.names:
        if child.exports.hasKey(name):
          let sym = child.exports[name]
          if m.scope.hasOwn(name):
            fail("E-DUP-SYMBOL", m.file, imp.line, imp.col,
                 "имя '" & name & "' уже импортировано")
          m.scope.define(sym)
        elif child.scope != nil and child.scope.hasOwn(name):
          fail("E-PRIVATE", m.file, imp.line, imp.col,
               "имя '" & name & "' не экспортируется модулем " & imp.modulePath,
               "экспорт помечается '*' в объявлении")
        else:
          fail("E-UNDEF", m.file, imp.line, imp.col,
               "модуль '" & imp.modulePath & "' не экспортирует '" & name & "'")
  for stmt in m.ast.stmts:
    if stmt.kind == nkTypeDecl:
      s.declareTypeShell(stmt)
  for stmt in m.ast.stmts:
    if stmt.kind == nkTypeDecl:
      s.resolveTypeFields(stmt)
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl:
      s.declareProc(stmt)

proc addressable(n: AstNode): bool =
  if n.isNil:
    return false
  case n.kind
  of nkIdent: true
  of nkField: addressable(n.obj)
  of nkDeref: true
  else: false

proc lvalueRoot(n: AstNode): AstNode =
  var cur = n
  while cur != nil and (cur.kind == nkField or cur.kind == nkDeref):
    if cur.kind == nkField:
      cur = cur.obj
    else:
      cur = cur.derefObj
  if cur != nil and cur.kind == nkIdent:
    return cur
  nil

proc isMutableLvalue(s: Sema; n: AstNode): bool =
  if n.isNil:
    return false
  case n.kind
  of nkIdent:
    if n.symId < 0 or n.symId >= s.prog.syms.len:
      return false
    let sym = s.prog.syms[n.symId]
    sym.kind == skVar or (sym.kind == skParam and sym.byRef)
  of nkField:
    if n.obj.typ != nil and n.obj.typ.kind == tyPtr:
      true
    else:
      s.isMutableLvalue(n.obj)
  of nkDeref:
    true
  else:
    false

proc sameOrCoerce(a, b: Type): bool =
  if sameType(a, b):
    return true
  if b.kind == tyString and a.kind == tyString:
    return true
  false

proc analExpr(s: Sema; n: AstNode): Type
proc analExprRaw(s: Sema; n: AstNode): Type
proc analStmt(s: Sema; n: AstNode)
proc analTryBlock(s: Sema; n: AstNode): Type
proc analCatch(s: Sema; n: AstNode): Type

proc astHasParam(n: AstNode; params: seq[string]): bool =
  if n.isNil:
    return false
  case n.kind
  of nkTypeName:
    n.typeName in params
  of nkTypeApply:
    if n.appliedName in params:
      true
    else:
      for a in n.appliedArgs:
        if astHasParam(a, params):
          return true
      false
  of nkPtrType, nkResultType:
    astHasParam(n.elemType, params)
  else:
    false

proc matchTypeNode(s: Sema; ast: AstNode; arg: Type; params: seq[string];
                   bindings: var Table[string, Type]): bool =
  if ast.isNil or arg.isNil:
    return false
  case ast.kind
  of nkTypeName:
    if ast.typeName in params:
      if bindings.hasKey(ast.typeName):
        return sameType(bindings[ast.typeName], arg)
      bindings[ast.typeName] = arg
      true
    else:
      sameType(s.typeFromNode(ast), arg)
  of nkPtrType:
    arg.kind == tyPtr and
      s.matchTypeNode(ast.elemType, arg.elem, params, bindings)
  of nkResultType:
    arg.kind == tyResult and
      s.matchTypeNode(ast.elemType, arg.elem, params, bindings)
  of nkTypeApply:
    if astHasParam(ast, params):
      let sym = s.curMod.scope.lookup(ast.appliedName)
      if sym == nil or sym.kind != skType or not sym.typ.isGeneric:
        return false
      if arg.kind != tyObject or arg.templateId != sym.id or
         arg.typeArgs.len != ast.appliedArgs.len:
        return false
      for i in 0 ..< ast.appliedArgs.len:
        if not s.matchTypeNode(ast.appliedArgs[i], arg.typeArgs[i],
                               params, bindings):
          return false
      true
    else:
      sameType(s.typeFromNode(ast), arg)
  else:
    false

proc inferBindings(s: Sema; tmpl: Symbol; args: seq[AstNode];
                   explicit: seq[AstNode];
                   callNode: AstNode): Table[string, Type] =
  result = initTable[string, Type]()
  if explicit.len > 0:
    if explicit.len != tmpl.genericParams.len:
      fail("E-GENERIC-ARG-COUNT", s.curMod.file, callNode.line,
           callNode.col, "generic-процедура '" & tmpl.name & "' ожидает " &
           $tmpl.genericParams.len & " аргумент(ов) типа, получено " &
           $explicit.len)
    for i, p in tmpl.genericParams:
      result[p] = s.typeFromNode(explicit[i])
    return
  if args.len != tmpl.node.params.len:
    fail("E-ARG-COUNT", s.curMod.file, callNode.line, callNode.col,
         "процедура '" & tmpl.name & "' ожидает " &
         $tmpl.node.params.len & " аргументов, а получила " & $args.len)
  for i, a in args:
    let at = s.analExpr(a)
    if not s.matchTypeNode(tmpl.node.params[i].paramTypeNode, at,
                           tmpl.genericParams, result):
      fail("E-TYPE", s.curMod.file, a.line, a.col,
           "аргумент " & $(i + 1) & " для '" & tmpl.name &
           "': не удалось сопоставить " & typeName(at) & " с параметром")
  var missing: seq[string]
  for p in tmpl.genericParams:
    if not result.hasKey(p):
      missing.add p
  if missing.len > 0:
    fail("E-GENERIC-CANNOT-INFER", s.curMod.file, callNode.line,
         callNode.col, "не удалось вывести параметры типа: " &
         missing.join(", "),
         "укажите их явно: " & tmpl.name & "[" & missing.join(", ") & "]")

proc inferCtorBindings(s: Sema; tmpl: Symbol; args: seq[AstNode];
                       callNode: AstNode): Table[string, Type] =
  result = initTable[string, Type]()
  var seen = initTable[string, bool]()
  for a in args:
    if a.kind != nkNamedField:
      fail("E-UNSUPPORTED", s.curMod.file, a.line, a.col,
           "generic-конструктор принимает только поля 'field: value'")
    if seen.hasKey(a.namedName):
      fail("E-DUP-FIELD", s.curMod.file, a.line, a.col,
           "поле " & a.namedName & " задано дважды")
    seen[a.namedName] = true
    var fieldNode: AstNode = nil
    for fn in tmpl.node.typeFields:
      if fn.declFieldName == a.namedName:
        fieldNode = fn
        break
    if fieldNode == nil:
      fail("E-FIELD", s.curMod.file, a.line, a.col,
           "у типа " & tmpl.name & " нет поля " & a.namedName)
    let vt = s.analExpr(a.namedValue)
    if not s.matchTypeNode(fieldNode.declFieldType, vt, tmpl.genericParams,
                           result):
      fail("E-TYPE", s.curMod.file, a.namedValue.line,
           a.namedValue.col, "поле " & a.namedName &
           ": не удалось сопоставить " & typeName(vt) & " с параметром")
  var missing: seq[string]
  for p in tmpl.genericParams:
    if not result.hasKey(p):
      missing.add p
  if missing.len > 0:
    fail("E-GENERIC-CANNOT-INFER", s.curMod.file, callNode.line,
         callNode.col, "не удалось вывести параметры типа: " &
         missing.join(", "),
         "укажите их явно: " & tmpl.name & "[...]")

proc checkCall(s: Sema; sym: Symbol; args: seq[AstNode]; n: AstNode) =
  let ptype = sym.typ
  if args.len != ptype.params.len:
    fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
         "процедура '" & sym.name & "' ожидает " & $ptype.params.len &
         " аргументов, а получила " & $args.len)
  for i in 0 ..< args.len:
    let at = s.analExpr(args[i])
    if not sameOrCoerce(at, ptype.params[i]):
      fail("E-TYPE", s.curMod.file, args[i].line, args[i].col,
           "аргумент " & $(i + 1) & " для '" & sym.name & "': ожидался " &
           typeName(ptype.params[i]) & ", получен " & typeName(at))
    if sym.paramVars.len > i and sym.paramVars[i] and
       not s.isMutableLvalue(args[i]):
      let r = lvalueRoot(args[i])
      var code = "E-NOT-ADDRESSABLE"
      var msg = "var-параметр требует изменяемое адресуемое выражение"
      if r != nil and r.symId >= 0 and r.symId < s.prog.syms.len:
        let rs = s.prog.syms[r.symId]
        if rs.kind == skLet or (rs.kind == skParam and not rs.byRef):
          code = "E-IMMUTABLE"
          msg = "нельзя передать неизменяемое значение в var-параметр"
      fail(code, s.curMod.file, args[i].line, args[i].col, msg)

proc analCall(s: Sema; n: AstNode): Type =
  if n.callee.kind == nkField:
    let fld = n.callee
    let objType = s.analExpr(fld.obj)
    if isAllocatorType(objType) and fld.fieldName in ["create", "destroy"]:
      if fld.fieldName == "create":
        if n.args.len notin {1, 2}:
          fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
               "create ожидает 'create(T)' или 'create(T, value)'")
        if n.args[0].kind notin {nkIdent, nkTypeApply}:
          fail("E-TYPE", s.curMod.file, n.args[0].line, n.args[0].col,
               "create: первым аргументом должно быть имя типа")
        let t = s.typeFromName(n.args[0], "create")
        if t.kind != tyObject or t.opaque:
          fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
               "create поддерживает только object с полями",
               "примитивы и импортированные opaque-типы — позже")
        var valueNode: AstNode = nil
        if n.args.len == 2:
          valueNode = n.args[1]
          let vt = s.analExpr(valueNode)
          if not sameType(vt, t):
            fail("E-TYPE", s.curMod.file, valueNode.line, valueNode.col,
                 "create(" & t.name & ", value): ожидался " & typeName(t) &
                 ", получен " & typeName(vt))
        n.typeRef = t
        n.symId = s.builtinCreate.id
        n.typ = ptrResultType(t)
        n.args = @[fld.obj]
        if valueNode != nil:
          n.args.add valueNode
        return n.typ
      else:
        if n.args.len != 1:
          fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
               "destroy ожидает ровно один аргумент")
        let argNode = n.args[0]
        let at = s.analExpr(argNode)
        if at.kind != tyPtr or at.elem.kind != tyObject or at.elem.opaque:
          fail("E-TYPE", s.curMod.file, argNode.line, argNode.col,
               "destroy принимает ptr T, где T — object с полями")
        n.typeRef = at.elem
        n.symId = s.builtinDestroy.id
        n.typ = s.builtins["void"]
        n.args = @[fld.obj, argNode]
        return n.typ
    if fld.fieldName == "deinit":
      if objType.kind != tyString:
        fail("E-UNSUPPORTED", s.curMod.file, fld.line, fld.col,
             "deinit в v0.1 поддерживается только для string",
             "seq и пользовательские типы — в v0.2")
      if not addressable(fld.obj):
        fail("E-NOT-ADDRESSABLE", s.curMod.file, fld.line, fld.col,
             "deinit требует адресуемое значение")
      n.args = @[fld.obj]
      n.symId = s.builtinDeinit.id
      n.typ = s.builtins["void"]
      return n.typ
    if objType.kind == tyObject and fieldIndex(objType, fld.fieldName) >= 0:
      fail("E-TYPE", s.curMod.file, fld.line, fld.col,
           "поле '" & fld.fieldName & "' не является процедурой")
    let sym = s.lookup(fld.fieldName)
    if sym == nil or sym.kind != skProc:
      fail("E-UNDEF", s.curMod.file, fld.line, fld.col,
           "нет процедуры '" & fld.fieldName & "' для UFCS-вызова")
    var args = @[fld.obj]
    for a in n.args:
      args.add a
    n.args = args
    var target = sym
    if sym.isGeneric:
      let bindings = s.inferBindings(sym, args, n.genericArgs, n)
      var targs: seq[Type]
      for p in sym.genericParams:
        targs.add bindings[p]
      target = s.instantiateProc(sym, targs, bindings, n)
    elif n.genericArgs.len > 0:
      fail("E-GENERIC-NOT-GENERIC", s.curMod.file, n.line, n.col,
           "'" & sym.name & "' не является generic-процедурой")
    n.symId = target.id
    s.checkCall(target, args, n)
    n.typ = target.typ.ret
    return n.typ
  elif n.callee.kind == nkIdent:
    let cname = n.callee.name
    if cname in ["sizeof", "alignof", "offsetof"] and s.lookup(cname).isNil:
      let want = if cname == "offsetof": 2 else: 1
      if n.args.len != want:
        fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
             cname & " ожидает " & $want & " аргумент(а)")
      let t = s.typeFromName(n.args[0], cname)
      n.typeRef = t
      if cname == "offsetof":
        if n.args[1].kind != nkIdent:
          fail("E-TYPE", s.curMod.file, n.args[1].line, n.args[1].col,
               "offsetof: вторым аргументом должно быть имя поля")
        if t.kind != tyObject or t.opaque:
          fail("E-TYPE", s.curMod.file, n.args[0].line, n.args[0].col,
               "offsetof применим только к object с полями")
        if fieldIndex(t, n.args[1].name) < 0:
          fail("E-FIELD", s.curMod.file, n.args[1].line, n.args[1].col,
               "offsetof: нет поля " & n.args[1].name)
      n.symId = s.builtinSizes[cname].id
      n.typ = s.builtins["int"]
      return n.typ
    let ctorSym = s.lookup(cname)
    if ctorSym != nil and ctorSym.kind == skType:
      var t = ctorSym.typ
      if t.isGeneric:
        var targs: seq[Type]
        if n.genericArgs.len > 0:
          if n.genericArgs.len != t.genericParams.len:
            fail("E-GENERIC-ARG-COUNT", s.curMod.file, n.line, n.col,
                 "тип '" & t.name & "' ожидает " &
                 $t.genericParams.len & " аргумент(ов) типа, получено " &
                 $n.genericArgs.len)
          for a in n.genericArgs:
            targs.add s.typeFromNode(a)
        else:
          let bindings = s.inferCtorBindings(ctorSym, n.args, n)
          for p in t.genericParams:
            targs.add bindings[p]
        t = s.instantiateType(ctorSym, targs, n)
      elif n.genericArgs.len > 0:
        fail("E-GENERIC-NOT-GENERIC", s.curMod.file, n.line, n.col,
             "'" & t.name & "' не является generic-типом")
      if t.opaque:
        fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
             "непрозрачный {.importc.}-тип нельзя конструировать",
             "создавайте его C-функцией")
      n.typeRef = t
      n.symId = ctorSym.id
      n.typ = t
      var seen = initTable[string, bool]()
      for a in n.args:
        if a.kind != nkNamedField:
          fail("E-UNSUPPORTED", s.curMod.file, a.line, a.col,
               "конструктор объекта принимает только поля 'field: value'",
               "позиционные аргументы в v0.3 не поддерживаются")
        let idx = fieldIndex(t, a.namedName)
        if idx < 0:
          fail("E-FIELD", s.curMod.file, a.line, a.col,
               "у типа " & t.name & " нет поля " & a.namedName)
        let fld = t.fields[idx]
        if not s.fieldVisible(t, fld):
          fail("E-PRIVATE", s.curMod.file, a.line, a.col,
               "поле " & a.namedName & " не экспортируется")
        if seen.hasKey(a.namedName):
          fail("E-DUP-FIELD", s.curMod.file, a.line, a.col,
               "поле " & a.namedName & " задано дважды")
        seen[a.namedName] = true
        let at = s.analExpr(a.namedValue)
        if not sameType(at, fld.typ):
          fail("E-TYPE", s.curMod.file, a.namedValue.line,
               a.namedValue.col,
               "поле " & a.namedName & ": ожидался " & typeName(fld.typ) &
               ", получен " & typeName(at))
      return t
    if cname in ["int", "char", "Rune"] and s.lookup(cname).isNil:
      if n.args.len != 1:
        fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
             "преобразование " & cname & " ожидает ровно 1 аргумент")
      let st = s.analExpr(n.args[0])
      let target = s.builtins[cname]
      let ok = sameType(st, target) or
               (st.kind == tyChar and target.kind in {tyRune, tyInt}) or
               (st.kind == tyRune and target.kind == tyInt)
      if not ok:
        if st.kind == tyInt and target.kind == tyRune:
          fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
               "Rune(int) запрещён: нужен проверяемый rune(x)",
               "используйте try rune(0x...): !Rune")
        if st.kind == tyInt and target.kind == tyChar:
          fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
               "char(int) не поддерживается в v0.2",
               "используйте char-литерал или b\"...\"")
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "нельзя преобразовать " & typeName(st) & " в " & cname)
      n.convTo = target
      n.typ = target
      n.symId = -1
      return n.typ
    if cname == "assert" and s.lookup(cname).isNil:
      if n.args.len notin {1, 2}:
        fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
             "assert ожидает 1 или 2 аргумента")
      let ct = s.analExpr(n.args[0])
      if ct.kind != tyBool:
        fail("E-TYPE", s.curMod.file, n.args[0].line, n.args[0].col,
             "assert требует bool, получен " & typeName(ct))
      if n.args.len == 2 and n.args[1].kind != nkStrLit:
        fail("E-UNSUPPORTED", s.curMod.file, n.args[1].line, n.args[1].col,
             "assert: сообщение обязано быть строковым литералом",
             "вычисляемые сообщения — в v0.2")
      n.symId = s.builtinAssert.id
      n.typ = s.builtins["void"]
      return n.typ
    if cname == "panic" and s.lookup(cname).isNil:
      if n.args.len != 1:
        fail("E-ARG-COUNT", s.curMod.file, n.line, n.col,
             "panic ожидает одно сообщение")
      let ct = s.analExpr(n.args[0])
      if ct.kind != tyString:
        fail("E-TYPE", s.curMod.file, n.args[0].line, n.args[0].col,
             "panic требует string, получен " & typeName(ct))
      n.symId = s.builtinPanic.id
      n.typ = s.builtins["void"]
      return n.typ
    let sym = s.lookup(cname)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.callee.line, n.callee.col,
           "неизвестная процедура: " & cname)
    if sym.kind == skBuiltin:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "builtin можно вызывать только методом (x.deinit())")
    if sym.kind != skProc:
      fail("E-TYPE", s.curMod.file, n.callee.line, n.callee.col,
           "'" & n.callee.name & "' не является процедурой")
    var target = sym
    if sym.isGeneric:
      let bindings = s.inferBindings(sym, n.args, n.genericArgs, n)
      var targs: seq[Type]
      for p in sym.genericParams:
        targs.add bindings[p]
      target = s.instantiateProc(sym, targs, bindings, n)
    elif n.genericArgs.len > 0:
      fail("E-GENERIC-NOT-GENERIC", s.curMod.file, n.line, n.col,
           "'" & sym.name & "' не является generic-процедурой")
    n.symId = target.id
    s.checkCall(target, n.args, n)
    n.typ = target.typ.ret
    return n.typ
  else:
    fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
         "вызов произвольного выражения не поддерживается в v0.1 (v0.2)")

proc analExprRaw(s: Sema; n: AstNode): Type =
  case n.kind
  of nkIntLit:
    n.typ = s.builtins["int"]
  of nkStrLit:
    n.typ = s.builtins["string"]
  of nkCharLit:
    n.typ = s.builtins["char"]
  of nkBoolLit:
    n.typ = s.builtins["bool"]
  of nkIdent:
    let sym = s.lookup(n.name)
    if sym == nil:
      fail("E-UNDEF", s.curMod.file, n.line, n.col, "неизвестное имя: " & n.name)
    if sym.kind == skProc and sym.isGeneric:
      fail("E-GENERIC-VALUE", s.curMod.file, n.line, n.col,
           "generic-процедура '" & n.name & "' не существует без конкретизации",
           "вызовите её с аргументами или укажите [T]")
    if sym.kind in {skProc, skBuiltin}:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "процедура как значение не поддерживается в v0.1 (v0.3)")
    if sym.kind == skType:
      if sym.typ.isGeneric:
        fail("E-GENERIC-NEEDS-ARGS", s.curMod.file, n.line, n.col,
             "generic-типу '" & n.name & "' нужны аргументы типа")
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "тип '" & n.name & "' использован как значение")
    n.symId = sym.id
    n.typ = sym.typ
  of nkTypeApply:
    fail("E-GENERIC-VALUE", s.curMod.file, n.line, n.col,
         "generic-тип '" & n.appliedName & "' использован как значение")
  of nkSpawn:
    let call = n.spawnCall
    if call.kind != nkCall:
      fail("E-SPAWN-CALL", s.curMod.file, n.line, n.col,
           "spawn принимает только вызов процедуры",
           "например: spawn f(args)")
    inc s.preserveResult
    let rt = s.analExpr(call)
    dec s.preserveResult
    if call.symId < 0 or call.symId >= s.prog.syms.len:
      fail("E-SPAWN-CALL", s.curMod.file, n.line, n.col,
           "spawn не может вызвать это выражение")
    let callee = s.prog.syms[call.symId]
    if callee.kind != skProc:
      fail("E-SPAWN-CALL", s.curMod.file, n.line, n.col,
           "spawn принимает только процедуру, не конструктор/builtin")
    for v in callee.paramVars:
      if v:
        fail("E-SPAWN-VAR", s.curMod.file, n.line, n.col,
             "нельзя spawn-ить процедуру с var-параметром",
             "аргументы задачи копируются по значению")
    if rt.kind != tyResult:
      fail("E-SPAWN-RET", s.curMod.file, n.line, n.col,
           "spawn требует процедуру, возвращающую !T; получено " &
           typeName(rt))
    n.typeRef = rt
    n.typ = taskType(rt.elem)
  of nkAwait:
    let t = s.analExpr(n.awaitTask)
    if t.kind != tyTask:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "await ожидает Task[T], получен " & typeName(t))
    n.typ = resultOfTask(t)
    n.typeRef = n.typ
  of nkUnary:
    let t = s.analExpr(n.a)
    case n.op
    of "-", "+":
      if t.kind != tyInt:
        fail("E-TYPE", s.curMod.file, n.line, n.col, "унарный '-' требует int")
      n.typ = t
    of "not":
      if t.kind != tyBool:
        fail("E-TYPE", s.curMod.file, n.line, n.col, "'not' требует bool")
      n.typ = t
    else:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "унарный оператор '" & n.op & "' не поддерживается в v0.1")
  of nkBinary:
    let ta = s.analExpr(n.a)
    let tb = s.analExpr(n.b)
    case n.op
    of "+", "-", "*", "/", "%":
      if ta.kind != tyInt or tb.kind != tyInt:
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "арифметика требует int, получено " & typeName(ta) & " и " &
             typeName(tb))
      n.typ = ta
    of "==", "!=", "<", "<=", ">", ">=":
      if not sameType(ta, tb):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "сравнение разных типов: " & typeName(ta) & " и " & typeName(tb))
      if ta.kind notin {tyInt, tyBool, tyChar, tyRune, tyPtr, tyPointer}:
        fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
             "сравнение типа " & typeName(ta) & " не поддерживается в v0.3",
             "строки и объекты — в v0.4")
      n.typ = s.builtins["bool"]
    of "and", "or":
      if ta.kind != tyBool or tb.kind != tyBool:
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "'" & n.op & "' требует bool")
      n.typ = s.builtins["bool"]
    else:
      fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
           "оператор '" & n.op & "' не поддерживается в v0.1")
  of nkTryBlock:
    discard s.analTryBlock(n)
    result = n.typ
  of nkCatch:
    discard s.analCatch(n)
    result = n.typ
  of nkPropagate:
    n.typ = s.builtins["void"]
    n.diverges = true
    result = n.typ
  of nkTry:
    inc s.preserveResult
    let t = s.analExpr(n.operand)
    dec s.preserveResult
    if t.kind != tyResult:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "try применяется только к !T, получен " & typeName(t))
    if s.procSym.isNil or s.procSym.typ.ret.kind != tyResult:
      fail("E-TRY-NO-RESULT", s.curMod.file, n.line, n.col,
           "try требует, чтобы процедура возвращала !T")
    n.typ = t.elem
  of nkCall:
    discard s.analCall(n)
  of nkField:
    if n.obj.kind == nkIdent and n.obj.name == "error" and
       s.lookup("error") == nil:
      let code = errorCodeFor(n.fieldName)
      if code >= 0:
        fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
             "error." & n.fieldName & " допустим только в паттернах catch:",
             "например: catch: error." & n.fieldName & " => ...")
    let ot = s.analExpr(n.obj)
    if ot.kind == tyString and n.fieldName == "len":
      n.typ = s.builtins["int"]
    elif ot.kind == tyPtr and ot.elem.kind == tyObject:
      if ot.elem.opaque:
        fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
             "поля непрозрачного импортированного типа недоступны")
      let idx = fieldIndex(ot.elem, n.fieldName)
      if idx < 0:
        fail("E-FIELD", s.curMod.file, n.line, n.col,
             "у типа " & ot.elem.name & " нет поля " & n.fieldName)
      let fld = ot.elem.fields[idx]
      if not s.fieldVisible(ot.elem, fld):
        fail("E-PRIVATE", s.curMod.file, n.line, n.col,
             "поле " & n.fieldName & " не экспортируется")
      n.typ = fld.typ
    elif ot.kind == tyObject:
      if ot.opaque:
        fail("E-UNSUPPORTED", s.curMod.file, n.line, n.col,
             "поля непрозрачного импортированного типа недоступны")
      let idx = fieldIndex(ot, n.fieldName)
      if idx < 0:
        fail("E-FIELD", s.curMod.file, n.line, n.col,
             "у типа " & ot.name & " нет поля " & n.fieldName)
      let fld = ot.fields[idx]
      if not s.fieldVisible(ot, fld):
        fail("E-PRIVATE", s.curMod.file, n.line, n.col,
             "поле " & n.fieldName & " не экспортируется")
      n.typ = fld.typ
    else:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "у типа " & typeName(ot) & " нет полей")
  of nkDeref:
    let ot = s.analExpr(n.derefObj)
    if ot.kind != tyPtr:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "p[] применимо только к ptr T, получен " & typeName(ot))
    n.typ = ot.elem
  else:
    fail("E-PARSE", s.curMod.file, n.line, n.col, "неожиданный узел выражения")
  n.typ

proc analExpr(s: Sema; n: AstNode): Type =
  let t = s.analExprRaw(n)
  n.typ = t
  if s.autoTryDepth > 0 and s.preserveResult == 0 and t.kind == tyResult:
    n.autoTry = true
    n.autoResultType = t
    n.typ = t.elem
    return t.elem
  t

proc analStmt(s: Sema; n: AstNode) =
  case n.kind
  of nkBlock:
    s.push()
    for st in n.stmts:
      s.analStmt(st)
    s.pop()
  of nkLet, nkVar:
    let initType = s.analExpr(n.init)
    var typ = initType
    if n.varTypeNode != nil:
      typ = s.typeFromNode(n.varTypeNode)
      if not sameType(initType, typ):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "инициализатор типа " & typeName(initType) & " не совпадает с " &
             typeName(typ))
    if typ.kind == tyVoid:
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "нельзя объявить переменную типа void")
    let kind = if n.kind == nkLet: skLet else: skVar
    let sym = Symbol(kind: kind, name: n.varName, typ: typ, node: n)
    discard s.addSym(sym)
    if s.scopes[^1].hasOwn(n.varName):
      fail("E-DUP-SYMBOL", s.curMod.file, n.line, n.col,
           "повторное объявление: " & n.varName)
    s.define(sym)
    n.symId = sym.id
    n.typ = typ
  of nkIf:
    let condType = s.analExpr(n.cond)
    if condType.kind != tyBool:
      fail("E-TYPE", s.curMod.file, n.cond.line, n.cond.col,
           "if требует bool, получен " & typeName(condType))
    inc s.controlDepth
    s.analStmt(n.thenBody)
    if n.elseBody != nil:
      s.analStmt(n.elseBody)
    dec s.controlDepth
    n.typ = s.builtins["void"]
  of nkWhile:
    let condType = s.analExpr(n.whileCond)
    if condType.kind != tyBool:
      fail("E-TYPE", s.curMod.file, n.whileCond.line, n.whileCond.col,
           "while требует bool, получен " & typeName(condType))
    inc s.loopDepth
    inc s.controlDepth
    s.analStmt(n.whileBody)
    dec s.controlDepth
    dec s.loopDepth
    n.typ = s.builtins["void"]
  of nkBreak, nkContinue:
    if s.loopDepth == 0:
      fail("E-LOOP-CONTROL", s.curMod.file, n.line, n.col,
           (if n.kind == nkBreak: "break" else: "continue") &
           " допустим только внутри while")
    n.typ = s.builtins["void"]
  of nkDefer:
    if s.controlDepth > 0:
      fail("E-DEFER-CONTROL", s.curMod.file, n.line, n.col,
           "defer внутри if/while не поддерживается",
           "вынесите defer на уровень процедуры")
    inc s.inDefer
    s.analStmt(n.deferBody)
    dec s.inDefer
    n.typ = s.builtins["void"]
  of nkErrdefer:
    if s.controlDepth > 0:
      fail("E-DEFER-CONTROL", s.curMod.file, n.line, n.col,
           "errdefer внутри if/while не поддерживается",
           "вынесите errdefer на уровень процедуры")
    inc s.inDefer
    s.analStmt(n.edBody)
    dec s.inDefer
    n.typ = s.builtins["void"]
  of nkAssign:
    let lt = s.analExpr(n.lhs)
    let rt = s.analExpr(n.rhs)
    if not sameType(lt, rt):
      fail("E-TYPE", s.curMod.file, n.line, n.col,
           "присваивание " & typeName(rt) & " в " & typeName(lt))
    if not s.isMutableLvalue(n.lhs):
      let r = lvalueRoot(n.lhs)
      var code = "E-NOT-ADDRESSABLE"
      var msg = "слева от '=' должно быть изменяемое место"
      if r != nil and r.symId >= 0 and r.symId < s.prog.syms.len:
        let rs = s.prog.syms[r.symId]
        if rs.kind in {skLet, skParam} and not rs.byRef:
          code = "E-IMMUTABLE"
          msg = "нельзя изменять неизменяемое значение: " & rs.name
      fail(code, s.curMod.file, n.line, n.col, msg)
    n.typ = s.builtins["void"]
  of nkReturn:
    if s.inDefer > 0:
      fail("E-DEFER-CTRL", s.curMod.file, n.line, n.col,
           "return внутри defer запрещён")
    let ret = s.procSym.typ.ret
    if ret.kind == tyResult:
      if ret.elem.kind == tyVoid:
        if n.value != nil:
          fail("E-TYPE", s.curMod.file, n.line, n.col,
               "функция !void не возвращает значение")
      else:
        if n.value == nil:
          fail("E-MISSING-RETURN", s.curMod.file, n.line, n.col,
               "нужно вернуть значение типа " & typeName(ret.elem))
        inc s.preserveResult
        let vt = s.analExpr(n.value)
        dec s.preserveResult
        if not sameType(vt, ret.elem) and not sameType(vt, ret):
          fail("E-TYPE", s.curMod.file, n.line, n.col,
               "возвращается " & typeName(vt) & ", ожидался " &
               typeName(ret.elem) & " или " & typeName(ret))
    else:
      if n.value == nil:
        fail("E-MISSING-RETURN", s.curMod.file, n.line, n.col,
             "нужно вернуть значение типа " & typeName(ret))
      inc s.preserveResult
      let vt = s.analExpr(n.value)
      dec s.preserveResult
      if not sameType(vt, ret):
        fail("E-TYPE", s.curMod.file, n.line, n.col,
             "возвращается " & typeName(vt) & ", ожидался " & typeName(ret))
    n.typ = s.builtins["void"]
  of nkDiscard:
    let t = s.analExpr(n.value)
    if t.kind == tyResult:
      fail("E-UNHANDLED-RESULT", s.curMod.file, n.line, n.col,
           "discard не обрабатывает !T; используйте try или catch:",
           "catch: будет в v0.2")
    n.typ = s.builtins["void"]
  else:
    let t = s.analExpr(n)
    if t.kind == tyResult:
      fail("E-UNHANDLED-RESULT", s.curMod.file, n.line, n.col,
           "результат !T не обработан: используйте try")
    if t.kind != tyVoid:
      fail("E-DISCARD-REQUIRED", s.curMod.file, n.line, n.col,
           "значение типа " & typeName(t) & " не использовано; нужен discard")

proc isValueExprKind(k: NodeKind): bool =
  k in {nkIdent, nkIntLit, nkStrLit, nkCharLit, nkBoolLit, nkCall, nkField,
        nkUnary, nkBinary, nkTry, nkTryBlock, nkCatch, nkAwait, nkSpawn,
        nkDeref}

proc analTryBlock(s: Sema; n: AstNode): Type =
  if s.procSym.isNil or s.procSym.typ.ret.kind != tyResult:
    fail("E-TRY-NO-RESULT", s.curMod.file, n.line, n.col,
         "try: требует, чтобы процедура возвращала !T")
  let body = n.tryBody
  s.push()
  inc s.autoTryDepth
  var lastType = s.builtins["void"]
  if body.kind == nkBlock:
    for i, st in body.stmts:
      let last = i == body.stmts.len - 1
      if last and isValueExprKind(st.kind):
        lastType = s.analExpr(st)
      else:
        s.analStmt(st)
        if last:
          lastType = s.builtins["void"]
  dec s.autoTryDepth
  s.pop()
  n.typ = lastType
  result = lastType

proc isPanicCall(s: Sema; n: AstNode): bool =
  n.kind == nkCall and n.symId >= 0 and n.symId < s.prog.syms.len and
    s.prog.syms[n.symId].builtin == "panic"

proc analCatch(s: Sema; n: AstNode): Type =
  inc s.preserveResult
  let t = s.analExpr(n.catchOperand)
  dec s.preserveResult
  if t.kind != tyResult:
    fail("E-TYPE", s.curMod.file, n.catchOperand.line, n.catchOperand.col,
         "catch применяется только к !T, получен " & typeName(t))
  let elem = t.elem
  var seen: seq[int32]
  var hasElse = false
  for i, arm in n.catchArms:
    if arm.isElse:
      if i != n.catchArms.len - 1:
        fail("E-CATCH-ELSE", s.curMod.file, arm.line, arm.col,
             "else должен быть последней веткой catch")
      hasElse = true
    else:
      let code = errorCodeFor(arm.patternName)
      if code < 0:
        fail("E-ERROR-CODE", s.curMod.file, arm.line, arm.col,
             "неизвестный код ошибки: error." & arm.patternName)
      if code in seen:
        fail("E-DUP-CATCH", s.curMod.file, arm.line, arm.col,
             "повторный паттерн error." & arm.patternName)
      seen.add code
      arm.errorCode = code
    let act = arm.action
    if act.kind == nkPropagate:
      if s.procSym.isNil or s.procSym.typ.ret.kind != tyResult:
        fail("E-CATCH-PROPAGATE", s.curMod.file, act.line, act.col,
             "else => propagate допустим только в функции, возвращающей !T")
      act.typ = s.builtins["void"]
      act.diverges = true
    elif act.kind in {nkBreak, nkContinue}:
      s.analStmt(act)
      act.diverges = true
    else:
      let at = s.analExpr(act)
      if isPanicCall(s, act):
        act.diverges = true
      elif elem.kind == tyVoid:
        if at.kind != tyVoid:
          fail("E-TYPE", s.curMod.file, act.line, act.col,
               "ветка catch для !void должна давать void")
      else:
        if not sameType(at, elem):
          fail("E-TYPE", s.curMod.file, act.line, act.col,
               "ветка catch даёт " & typeName(at) & ", ожидался " &
               typeName(elem))
  if not hasElse and (s.procSym.isNil or
                      s.procSym.typ.ret.kind != tyResult):
    fail("E-CATCH-COVERAGE", s.curMod.file, n.line, n.col,
         "catch без else в функции без !T не покрывает все ошибки",
         "добавьте else => panic(...) или верните !T")
  n.typ = elem
  result = elem

proc analyzeProcBody(s: Sema; sym: Symbol) =
  let m = s.findModule(sym.modulePath)
  if m == nil:
    fail("E-INTERNAL", s.prog.entry.file, sym.node.line, sym.node.col,
         "модуль процедуры не найден: " & sym.modulePath)
  s.curMod = m
  s.procSym = sym
  s.typeEnv = sym.typeEnv
  s.scopes = @[newScope(m.scope)]
  for i, p in sym.node.params:
    let ps = sym.paramSyms[i]
    if s.scopes[^1].hasOwn(ps.name):
      fail("E-DUP-SYMBOL", m.file, p.line, p.col,
           "повторяющийся параметр: " & ps.name)
    s.scopes[^1].define(ps)
  s.inDefer = 0
  s.loopDepth = 0
  s.controlDepth = 0
  s.autoTryDepth = 0
  s.preserveResult = 0
  let oldDepth = s.monoDepth
  s.monoDepth = sym.monoDepth
  if sym.propagate:
    if sym.typ.ret.kind != tyResult:
      fail("E-PROPAGATE-RET", m.file, sym.node.line, sym.node.col,
           "{.propagate.} требует процедуру, возвращающую !T")
    s.autoTryDepth = 1
  s.analStmt(sym.node.body)
  s.autoTryDepth = 0
  s.monoDepth = oldDepth

proc analyzeModuleBodies(s: Sema; m: ModuleInfo) =
  s.curMod = m
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl and stmt.body != nil:
      let sym = s.prog.syms[stmt.symId]
      if sym.isGeneric:
        continue
      s.analyzeProcBody(sym)

proc findMain(s: Sema) =
  let m = s.prog.entry
  var sym: Symbol = nil
  for stmt in m.ast.stmts:
    if stmt.kind == nkProcDecl and stmt.procName == "main":
      sym = s.prog.syms[stmt.symId]
  if sym.isNil:
    fail("E-MAIN-MISSING", m.file, 1, 1,
         "во входном модуле нет 'proc main'")
  if sym.typ.params.len != 0:
    fail("E-MAIN-MISSING", m.file, sym.node.line, sym.node.col,
         "main не должен принимать параметры")
  if sym.typ.ret.kind != tyResult or sym.typ.ret.elem.kind != tyVoid:
    fail("E-MAIN-MISSING", m.file, sym.node.line, sym.node.col,
         "main должен иметь тип '!void'")
  s.prog.entryMain = sym

proc computeTypeOrder(s: Sema) =
  var state = initTable[string, int]()
  var order: seq[Type]
  let all = s.prog.objectTypes

  proc visit(t: Type) =
    if t.opaque or t.isGeneric:
      return
    let key = t.cname
    let st = state.getOrDefault(key, 0)
    if st == 1:
      fail("E-TYPE", t.declFile, t.declLine, t.declCol,
           "циклическая вложенность объектов по значению: " & t.name,
           "разорвите цикл полем ptr " & t.name)
    if st == 2:
      return
    state[key] = 1
    for fld in t.fields:
      if fld.typ.kind == tyObject and not fld.typ.opaque and
         not fld.typ.isGeneric:
        visit(fld.typ)
    state[key] = 2
    order.add t

  for t in all:
    visit(t)
  s.prog.objectTypes = order

proc analyze*(modules: seq[ModuleInfo]; opts: BuildOptions): Program =
  let prog = Program(modules: modules, opts: opts, syms: @[], procs: @[],
                     objectTypes: @[], strings: @[])
  var s = Sema(prog: prog, builtins: makeBuiltins(),
               builtinSizes: initTable[string, Symbol](),
               typeCache: initTable[string, Type](),
               procCache: initTable[string, Symbol](),
               pending: @[],
               typeEnv: initTable[string, Type](), monoDepth: 0)
  let deinitType = newType(tyProc)
  deinitType.params = @[s.builtins["string"]]
  deinitType.ret = s.builtins["void"]
  let deinitSym = Symbol(kind: skBuiltin, name: "deinit", cname: "cvn_str_deinit",
                         typ: deinitType, builtin: "deinit")
  s.builtinDeinit = deinitSym
  discard s.addSym(deinitSym)

  let assertType = newType(tyProc)
  assertType.params = @[s.builtins["bool"]]
  assertType.ret = s.builtins["void"]
  let assertSym = Symbol(kind: skBuiltin, name: "assert",
                         cname: "cvn_rt_assert_fail", typ: assertType,
                         builtin: "assert")
  s.builtinAssert = assertSym
  discard s.addSym(assertSym)

  let panicType = newType(tyProc)
  panicType.params = @[s.builtins["string"]]
  panicType.ret = s.builtins["void"]
  let panicSym = Symbol(kind: skBuiltin, name: "panic",
                        cname: "cvn_panic", typ: panicType,
                        builtin: "panic")
  s.builtinPanic = panicSym
  discard s.addSym(panicSym)

  for nm in ["sizeof", "alignof", "offsetof"]:
    let ty = newType(tyProc)
    ty.params = @[s.builtins["int"]]
    ty.ret = s.builtins["int"]
    let sym = Symbol(kind: skBuiltin, name: nm, typ: ty, builtin: nm)
    discard s.addSym(sym)
    s.builtinSizes[nm] = sym

  for nm in ["create", "destroy"]:
    let ty = newType(tyProc)
    ty.ret = s.builtins["void"]
    let sym = Symbol(kind: skBuiltin, name: nm, typ: ty, builtin: nm)
    discard s.addSym(sym)
    if nm == "create":
      s.builtinCreate = sym
    else:
      s.builtinDestroy = sym

  for m in modules:
    if m.isEntry:
      prog.entry = m
    s.setupModule(m)
  for m in modules:
    s.analyzeModuleBodies(m)
  var pi = 0
  while pi < s.pending.len:
    let sym = s.pending[pi]
    inc pi
    s.analyzeProcBody(sym)
  s.computeTypeOrder()
  s.findMain()
  prog
