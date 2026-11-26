## Понижение AST -> HIR: try, defer, builtin deinit, литералы.

import std/tables
import std/algorithm
import diag, ast, types, symbols, sema, hir

type
  Lower = ref object
    prog: Program
    procSym: Symbol
    slots: seq[Type]
    symSlots: Table[int, int]
    instrs: seq[HirInstr]
    cleanups: seq[seq[seq[HirInstr]]]
    labelSeq: int
    curFile: string

proc newSlot(l: Lower; t: Type): int =
  result = l.slots.len
  l.slots.add t

proc emit(l: Lower; ins: HirInstr) =
  l.instrs.add ins

proc newLabel(l: Lower): int =
  result = l.labelSeq
  inc l.labelSeq

proc emitCleanups(l: Lower) =
  for i in countdown(l.cleanups.len - 1, 0):
    # LIFO по блокам defer, но инструкции внутри блока — в исходном порядке
    for k in countdown(l.cleanups[i].len - 1, 0):
      for ins in l.cleanups[i][k]:
        l.instrs.add ins

proc internString(l: Lower; s: string): int =
  for i, x in l.prog.strings:
    if x == s:
      return i
  l.prog.strings.add s
  l.prog.strings.len - 1

proc withLabel(ins: HirInstr; label: int): HirInstr =
  result = ins
  result.label = label

proc lowerExpr(l: Lower; n: AstNode): int
proc lowerStmt(l: Lower; n: AstNode)
proc lowerPath(l: Lower; n: AstNode): tuple[slot: int, rootPtr: bool,
                                            path: seq[string]]

proc lowerPath(l: Lower; n: AstNode): tuple[slot: int, rootPtr: bool,
                                            path: seq[string]] =
  case n.kind
  of nkIdent:
    let sym = l.prog.syms[n.symId]
    let slot = l.symSlots[n.symId]
    var rootPtr = sym.byRef
    if l.slots[slot].kind == tyPtr:
      rootPtr = true
    (slot, rootPtr, newSeq[string]())
  of nkDeref:
    (l.lowerExpr(n.derefObj), true, newSeq[string]())
  of nkField:
    if n.obj.typ != nil and n.obj.typ.kind == tyPtr:
      (l.lowerExpr(n.obj), true, @[n.fieldName])
    else:
      var r = l.lowerPath(n.obj)
      r.path.add n.fieldName
      r
  else:
    fail("E-INTERNAL", l.prog.entry.file, n.line, n.col,
         "выражение не является lvalue")

proc lowerExpr(l: Lower; n: AstNode): int =
  case n.kind
  of nkIntLit:
    result = l.newSlot(n.typ)
    var ins = newInstr(hiConstInt)
    ins.dst = result
    ins.imm = n.intVal
    l.emit(ins)
  of nkCharLit:
    result = l.newSlot(n.typ)
    var ins = newInstr(hiConstInt)
    ins.dst = result
    ins.imm = int64(n.charVal)
    l.emit(ins)
  of nkStrLit:
    result = l.newSlot(n.typ)
    var ins = newInstr(hiConstStr)
    ins.dst = result
    ins.strIdx = l.internString(n.strVal)
    l.emit(ins)
  of nkIdent:
    if not l.symSlots.hasKey(n.symId):
      fail("E-INTERNAL", l.prog.entry.file, n.line, n.col,
           "нет слота для символа")
    let sym = l.prog.syms[n.symId]
    if sym.byRef:
      result = l.newSlot(sym.typ)
      var ins = newInstr(hiLoadPtr)
      ins.dst = result
      ins.a = l.symSlots[n.symId]
      l.emit(ins)
    else:
      result = l.symSlots[n.symId]
  of nkField:
    if n.obj.typ != nil and n.obj.typ.kind == tyString and
       n.fieldName == "len":
      let a = l.lowerExpr(n.obj)
      result = l.newSlot(n.typ)
      var ins = newInstr(hiStrLen)
      ins.dst = result
      ins.a = a
      l.emit(ins)
    else:
      let r = l.lowerPath(n)
      result = l.newSlot(n.typ)
      var ins = newInstr(hiPathGet)
      ins.dst = result
      ins.a = r.slot
      ins.rootPtr = r.rootPtr
      ins.path = r.path
      l.emit(ins)
  of nkDeref:
    let p = l.lowerExpr(n.derefObj)
    result = l.newSlot(n.typ)
    var ins = newInstr(hiLoadPtr)
    ins.dst = result
    ins.a = p
    l.emit(ins)
  of nkUnary:
    let a = l.lowerExpr(n.a)
    result = l.newSlot(n.typ)
    var ins = newInstr(hiUnary)
    ins.dst = result
    ins.a = a
    ins.symId = -1
    ins.args = @[]
    ins.imm = 0
    case n.op
    of "not": ins.imm = 1
    of "-": ins.imm = 2
    of "+": ins.imm = 3
    else: ins.imm = 0
    l.emit(ins)
  of nkBinary:
    let a = l.lowerExpr(n.a)
    let b = l.lowerExpr(n.b)
    result = l.newSlot(n.typ)
    var ins = newInstr(hiBinary)
    ins.dst = result
    ins.a = a
    ins.b = b
    ins.text = n.op
    ins.imm = 0
    l.emit(ins)
  of nkCall:
    if n.convTo != nil:
      let a = l.lowerExpr(n.args[0])
      result = l.newSlot(n.typ)
      var ins = newInstr(hiConv)
      ins.dst = result
      ins.a = a
      ins.convType = n.convTo
      l.emit(ins)
      return
    let callee = l.prog.syms[n.symId]
    if callee.kind == skType:
      let t = n.typeRef
      result = l.newSlot(t)
      var init = newInstr(hiObjInit)
      init.dst = result
      init.typeRef = t
      l.emit(init)
      for a in n.args:
        let v = l.lowerExpr(a.namedValue)
        var st = newInstr(hiPathSet)
        st.a = result
        st.b = v
        st.path = @[a.namedName]
        st.rootPtr = false
        l.emit(st)
      return
    if callee.builtin in ["sizeof", "alignof", "offsetof"]:
      result = l.newSlot(n.typ)
      var ins = newInstr(
        case callee.builtin
        of "sizeof": hiSizeof
        of "alignof": hiAlignof
        else: hiOffsetof)
      ins.dst = result
      ins.typeRef = n.typeRef
      if callee.builtin == "offsetof":
        ins.text = n.args[1].name
      l.emit(ins)
      return
    if callee.builtin == "create":
      let a = l.lowerExpr(n.args[0])
      result = l.newSlot(n.typ)
      var ins = newInstr(hiObjCreate)
      ins.dst = result
      ins.a = a
      ins.typeRef = n.typeRef
      if n.args.len > 1:
        ins.b = l.lowerExpr(n.args[1])
      l.emit(ins)
      return
    if callee.builtin == "destroy":
      let a = l.lowerExpr(n.args[0])
      let p = l.lowerExpr(n.args[1])
      var ins = newInstr(hiObjDestroy)
      ins.a = a
      ins.b = p
      ins.typeRef = n.typeRef
      l.emit(ins)
      return -1
    if callee.builtin == "deinit":
      let r = l.lowerPath(n.args[0])
      var ins = newInstr(hiPathDeinit)
      ins.a = r.slot
      ins.rootPtr = r.rootPtr
      ins.path = r.path
      l.emit(ins)
      return -1
    if callee.builtin == "assert":
      let cond = l.lowerExpr(n.args[0])
      var ins = newInstr(hiAssert)
      ins.a = cond
      ins.where = l.curFile & ":" & $n.line
      if n.args.len == 2:
        ins.text = n.args[1].strVal
      l.emit(ins)
      return -1
    var argSlots: seq[int]
    for i, a in n.args:
      let isVar = i < callee.paramVars.len and callee.paramVars[i]
      if isVar:
        if a.kind == nkIdent and l.prog.syms[a.symId].byRef:
          argSlots.add l.symSlots[a.symId]
        elif a.kind == nkDeref:
          argSlots.add l.lowerExpr(a.derefObj)
        else:
          let r = l.lowerPath(a)
          let ps = l.newSlot(ptrTo(a.typ))
          var ad = newInstr(hiPathAddr)
          ad.dst = ps
          ad.a = r.slot
          ad.rootPtr = r.rootPtr
          ad.path = r.path
          l.emit(ad)
          argSlots.add ps
      else:
        if a.kind == nkIdent and l.prog.syms[a.symId].byRef:
          let sym = l.prog.syms[a.symId]
          let s = l.newSlot(sym.typ)
          var ld = newInstr(hiLoadPtr)
          ld.dst = s
          ld.a = l.symSlots[a.symId]
          l.emit(ld)
          argSlots.add s
        else:
          argSlots.add l.lowerExpr(a)
    var dst = -1
    if n.typ.kind != tyVoid:
      dst = l.newSlot(n.typ)
    var ins = newInstr(hiCall)
    ins.dst = dst
    ins.symId = callee.id
    ins.args = argSlots
    l.emit(ins)
    result = dst
  of nkTry:
    let src = l.lowerExpr(n.operand)
    let errL = l.newLabel()
    let contL = l.newLabel()
    var chk = newInstr(hiCheckResult)
    chk.a = src
    chk.label = errL
    l.emit(chk)
    var dst = -1
    if n.typ.kind != tyVoid:
      dst = l.newSlot(n.typ)
      var ext = newInstr(hiExtractOk)
      ext.dst = dst
      ext.a = src
      l.emit(ext)
    var j = newInstr(hiJmp)
    j.label = contL
    l.emit(j)
    l.emit(newInstr(hiLabel).withLabel(errL))
    l.emitCleanups()
    var re = newInstr(hiRetErrFrom)
    re.a = src
    l.emit(re)
    l.emit(newInstr(hiLabel).withLabel(contL))
    result = dst
  else:
    fail("E-INTERNAL", l.prog.entry.file, n.line, n.col,
         "выражение не понижено: " & $n.kind)

proc capture(l: Lower; body: AstNode): seq[HirInstr] =
  let saved = l.instrs
  l.instrs = @[]
  var empty: seq[seq[HirInstr]] = @[]
  l.cleanups.add empty
  l.lowerStmt(body)
  l.cleanups.setLen(l.cleanups.len - 1)
  result = l.instrs
  l.instrs = saved

proc lowerStmt(l: Lower; n: AstNode) =
  case n.kind
  of nkBlock:
    for st in n.stmts:
      l.lowerStmt(st)
  of nkLet, nkVar:
    let src = l.lowerExpr(n.init)
    let dst = l.newSlot(n.typ)
    var ins = newInstr(hiMov)
    ins.dst = dst
    ins.a = src
    l.emit(ins)
    l.symSlots[n.symId] = dst
  of nkDefer:
    let bodyInstrs = l.capture(n.deferBody)
    l.cleanups[^1].add bodyInstrs
  of nkReturn:
    l.emitCleanups()
    if n.value != nil:
      let v = l.lowerExpr(n.value)
      if l.procSym.typ.ret.kind == tyResult:
        var ins = newInstr(hiRetVal)
        ins.a = v
        l.emit(ins)
      else:
        var ins = newInstr(hiRet)
        ins.a = v
        l.emit(ins)
    else:
      l.emit(newInstr(hiRet))
  of nkDiscard:
    discard l.lowerExpr(n.value)
  of nkAssign:
    if n.lhs.kind == nkIdent:
      let sym = l.prog.syms[n.lhs.symId]
      let v = l.lowerExpr(n.rhs)
      if sym.byRef:
        var ins = newInstr(hiStorePtr)
        ins.a = l.symSlots[n.lhs.symId]
        ins.b = v
        l.emit(ins)
      else:
        var ins = newInstr(hiMov)
        ins.dst = l.symSlots[n.lhs.symId]
        ins.a = v
        l.emit(ins)
    elif n.lhs.kind == nkField:
      let r = l.lowerPath(n.lhs)
      let v = l.lowerExpr(n.rhs)
      var ins = newInstr(hiPathSet)
      ins.a = r.slot
      ins.b = v
      ins.rootPtr = r.rootPtr
      ins.path = r.path
      l.emit(ins)
    elif n.lhs.kind == nkDeref:
      let p = l.lowerExpr(n.lhs.derefObj)
      let v = l.lowerExpr(n.rhs)
      var ins = newInstr(hiStorePtr)
      ins.a = p
      ins.b = v
      l.emit(ins)
    else:
      fail("E-INTERNAL", l.prog.entry.file, n.line, n.col,
           "некорректный lhs присваивания")
  else:
    discard l.lowerExpr(n)

proc lowerProc(l: Lower; sym: Symbol): HirProc =
  l.procSym = sym
  l.curFile = sym.modulePath
  for m in l.prog.modules:
    if m.path == sym.modulePath:
      l.curFile = m.file
  l.slots = @[]
  l.symSlots = initTable[int, int]()
  l.instrs = @[]
  var empty: seq[seq[HirInstr]] = @[]
  l.cleanups = @[empty]
  l.labelSeq = 0

  for ps in sym.paramSyms:
    let slot =
      if ps.byRef: l.newSlot(ptrTo(ps.typ))
      else: l.newSlot(ps.typ)
    l.symSlots[ps.id] = slot

  l.lowerStmt(sym.node.body)
  l.emitCleanups()
  l.emit(newInstr(hiRet))

  result.symId = sym.id
  result.slotTypes = l.slots
  result.paramCount = sym.paramSyms.len
  result.labelCount = l.labelSeq
  result.instrs = l.instrs

proc lowerProgram*(prog: Program): seq[HirProc] =
  var l = Lower(prog: prog)
  for sym in prog.procs:
    if sym.external:
      continue
    result.add l.lowerProc(sym)
