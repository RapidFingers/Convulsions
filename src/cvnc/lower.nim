## Понижение AST -> HIR: try, defer, builtin deinit, литералы.

import std/tables
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

proc lowerExpr(l: Lower; n: AstNode): int =
  case n.kind
  of nkIntLit:
    result = l.newSlot(n.typ)
    var ins = newInstr(hiConstInt)
    ins.dst = result
    ins.imm = n.intVal
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
    result = l.symSlots[n.symId]
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
    let callee = l.prog.syms[n.symId]
    if callee.builtin == "deinit":
      let a = l.lowerExpr(n.args[0])
      var ins = newInstr(hiDeinit)
      ins.a = a
      l.emit(ins)
      return -1
    var argSlots: seq[int]
    for a in n.args:
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
      var ins = newInstr(hiRetVal)
      ins.a = v
      l.emit(ins)
    else:
      l.emit(newInstr(hiRet))
  of nkDiscard:
    discard l.lowerExpr(n.value)
  else:
    discard l.lowerExpr(n)

proc lowerProc(l: Lower; sym: Symbol): HirProc =
  l.procSym = sym
  l.slots = @[]
  l.symSlots = initTable[int, int]()
  l.instrs = @[]
  var empty: seq[seq[HirInstr]] = @[]
  l.cleanups = @[empty]
  l.labelSeq = 0

  for ps in sym.paramSyms:
    let slot = l.newSlot(ps.typ)
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
