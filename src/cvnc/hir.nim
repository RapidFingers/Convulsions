## HIR: линейные инструкции со слотами и метками (достаточно для MVP).

import types

type
  HirOp* = enum
    hiLabel, hiJmp, hiConstInt, hiConstStr, hiCall, hiDeinit, hiCheckResult,
    hiExtractOk, hiMov, hiBinary, hiUnary, hiRet, hiRetVal, hiRetErrFrom,
    hiConv, hiStrLen, hiAssert, hiPathGet, hiPathSet, hiPathAddr,
    hiPathDeinit, hiLoadPtr, hiStorePtr, hiObjInit, hiObjCreate,
    hiObjDestroy, hiSizeof, hiAlignof, hiOffsetof, hiNop

  HirInstr* = object
    op*: HirOp
    dst*: int
    a*: int
    b*: int
    symId*: int
    imm*: int64
    strIdx*: int
    label*: int
    text*: string
    where*: string
    convType*: Type
    typeRef*: Type
    rootPtr*: bool
    path*: seq[string]
    args*: seq[int]

  HirProc* = object
    symId*: int
    slotTypes*: seq[Type]
    paramCount*: int
    labelCount*: int
    instrs*: seq[HirInstr]

proc newInstr*(op: HirOp): HirInstr =
  HirInstr(op: op, dst: -1, a: -1, b: -1, symId: -1, strIdx: -1, label: -1,
           args: @[])

proc dumpHir*(hp: HirProc): string =
  result = "proc #" & $hp.symId & " slots=" & $hp.slotTypes.len & "\n"
  for ins in hp.instrs:
    result.add "  " & $ins.op
    if ins.dst >= 0: result.add " dst=v" & $ins.dst
    if ins.a >= 0: result.add " a=v" & $ins.a
    if ins.b >= 0: result.add " b=v" & $ins.b
    if ins.symId >= 0: result.add " sym=#" & $ins.symId
    if ins.strIdx >= 0: result.add " str=" & $ins.strIdx
    if ins.label >= 0: result.add " L" & $ins.label
    if ins.imm != 0: result.add " imm=" & $ins.imm
    if ins.args.len > 0:
      result.add " args=["
      for i, a in ins.args:
        if i > 0: result.add ","
        result.add "v" & $a
      result.add "]"
    result.add "\n"
