## Кодогенерация HIR -> C11 (одна единица трансляции).

import std/strutils
import types, symbols, sema, hir

proc cType(t: Type): string

proc resultSuffix(t: Type): string =
  case t.kind
  of tyInt: "i64"
  of tyBool: "bool"
  of tyChar: "u8"
  of tyRune: "u32"
  of tyPointer: "ptr"
  of tyString: "string"
  of tyPtr: "ptr"
  of tyObject: "obj_" & cSanitize(t.cname)
  else: "x"

proc resultName(t: Type): string =
  if t.elem.kind == tyVoid:
    "cvn_error"
  elif t.elem.kind == tyString:
    "cvn_result_string"
  else:
    "cvn_result_" & resultSuffix(t.elem)

proc cType(t: Type): string =
  case t.kind
  of tyVoid: "void"
  of tyInt: "int64_t"
  of tyBool: "bool"
  of tyChar: "uint8_t"
  of tyRune: "uint32_t"
  of tyPointer: "void *"
  of tyString: "cvn_string"
  of tyPtr:
    if t.elem.kind == tyObject:
      "struct " & t.elem.cname & " *"
    else:
      cType(t.elem) & " *"
  of tyObject: t.cname
  of tyResult: resultName(t)
  of tyError: "cvn_error"
  of tyErrorCode: "int32_t"
  else: "void"

proc cStringLit(s: string): string =
  result = "\""
  for c in s:
    result.add "\\x" & toHex(ord(c), 2)
  result.add "\""

proc fieldC(name: string): string =
  cSanitize(name)

proc pathText(root: string; path: seq[string]; rootPtr: bool): string =
  if path.len == 0:
    return (if rootPtr: "*" & root else: root)
  result = root
  result.add(if rootPtr: "->" else: ".")
  for i, p in path:
    if i > 0:
      result.add "."
    result.add fieldC(p)

proc paramList(hp: HirProc): string =
  if hp.paramCount == 0:
    return "void"
  for i in 0 ..< hp.paramCount:
    if i > 0:
      result.add ", "
    result.add cType(hp.slotTypes[i]) & " v" & $i

proc binOp(op: string): string =
  case op
  of "and": "&&"
  of "or": "||"
  else: op

proc localName(slot: int): string =
  "v" & $slot

proc emitInstr(acc: var string; prog: Program; hp: HirProc; sym: Symbol;
               ins: HirInstr) =
  let ret = sym.typ.ret
  case ins.op
  of hiLabel:
    acc.add "L" & $ins.label & ": ;\n"
  of hiJmp:
    acc.add "  goto L" & $ins.label & ";\n"
  of hiConstInt:
    acc.add "  " & localName(ins.dst) & " = INT64_C(" & $ins.imm & ");\n"
  of hiConstStr:
    acc.add "  " & localName(ins.dst) & " = cvn_slit_" & $ins.strIdx & ";\n"
  of hiCall:
    let callee = prog.syms[ins.symId]
    var call = callee.cname & "("
    for i, a in ins.args:
      if i > 0:
        call.add ", "
      call.add localName(a)
    call.add ")"
    if ins.dst >= 0:
      acc.add "  " & localName(ins.dst) & " = " & call & ";\n"
    else:
      acc.add "  " & call & ";\n"
  of hiDeinit:
    acc.add "  cvn_str_deinit(&" & localName(ins.a) & ");\n"
  of hiCheckResult:
    let st = hp.slotTypes[ins.a]
    if st.elem.kind == tyVoid:
      acc.add "  if (" & localName(ins.a) & ".code != 0) goto L" &
              $ins.label & ";\n"
    else:
      acc.add "  if (" & localName(ins.a) & ".tag != 0) goto L" &
              $ins.label & ";\n"
  of hiExtractOk:
    acc.add "  " & localName(ins.dst) & " = " & localName(ins.a) &
            ".u.ok;\n"
  of hiMov:
    acc.add "  " & localName(ins.dst) & " = " & localName(ins.a) & ";\n"
  of hiBinary:
    acc.add "  " & localName(ins.dst) & " = (" & localName(ins.a) & " " &
            binOp(ins.text) & " " & localName(ins.b) & ");\n"
  of hiUnary:
    case ins.imm
    of 1:
      acc.add "  " & localName(ins.dst) & " = !" & localName(ins.a) & ";\n"
    of 2:
      acc.add "  " & localName(ins.dst) & " = -" & localName(ins.a) & ";\n"
    of 3:
      acc.add "  " & localName(ins.dst) & " = " & localName(ins.a) & ";\n"
    else:
      discard
  of hiConv:
    acc.add "  " & localName(ins.dst) & " = (" & cType(ins.convType) & ")" &
            localName(ins.a) & ";\n"
  of hiStrLen:
    acc.add "  " & localName(ins.dst) & " = " & localName(ins.a) & ".len;\n"
  of hiAssert:
    acc.add "  if (!" & localName(ins.a) & ") cvn_rt_assert_fail(" &
            cStringLit(ins.where) & ", " & cStringLit(ins.text) & ");\n"
  of hiPathGet:
    acc.add "  " & localName(ins.dst) & " = " &
            pathText(localName(ins.a), ins.path, ins.rootPtr) & ";\n"
  of hiPathSet:
    acc.add "  " & pathText(localName(ins.a), ins.path, ins.rootPtr) &
            " = " & localName(ins.b) & ";\n"
  of hiPathAddr:
    if ins.path.len == 0 and not ins.rootPtr:
      acc.add "  " & localName(ins.dst) & " = &" & localName(ins.a) & ";\n"
    elif ins.path.len == 0 and ins.rootPtr:
      acc.add "  " & localName(ins.dst) & " = " & localName(ins.a) & ";\n"
    else:
      acc.add "  " & localName(ins.dst) & " = &" &
              pathText(localName(ins.a), ins.path, ins.rootPtr) & ";\n"
  of hiPathDeinit:
    if ins.path.len == 0 and ins.rootPtr:
      acc.add "  cvn_str_deinit(" & localName(ins.a) & ");\n"
    else:
      acc.add "  cvn_str_deinit(&" &
              pathText(localName(ins.a), ins.path, ins.rootPtr) & ");\n"
  of hiLoadPtr:
    acc.add "  " & localName(ins.dst) & " = *" & localName(ins.a) & ";\n"
  of hiStorePtr:
    acc.add "  *" & localName(ins.a) & " = " & localName(ins.b) & ";\n"
  of hiObjInit:
    acc.add "  " & localName(ins.dst) & " = cvn_new_" &
            ins.typeRef.cname & "();\n"
  of hiObjCreate:
    acc.add "  " & localName(ins.dst) & " = cvn_alloc_aligned(" &
            localName(ins.a) & ", (int64_t)sizeof(" &
            cType(ins.typeRef) & "), (int64_t)_Alignof(" &
            cType(ins.typeRef) & "));\n"
    acc.add "  if (" & localName(ins.dst) & ".tag == 0) {\n"
    acc.add "    *(" & cType(ins.typeRef) & " *)" &
            localName(ins.dst) & ".u.ok = "
    if ins.b >= 0:
      acc.add localName(ins.b) & ";\n"
    else:
      acc.add "cvn_new_" & ins.typeRef.cname & "();\n"
    acc.add "  }\n"
  of hiObjDestroy:
    acc.add "  cvn_free_bytes(" & localName(ins.a) & ", " &
            localName(ins.b) & ", (int64_t)sizeof(" &
            cType(ins.typeRef) & "));\n"
  of hiSizeof:
    acc.add "  " & localName(ins.dst) & " = (int64_t)sizeof(" &
            cType(ins.typeRef) & ");\n"
  of hiAlignof:
    acc.add "  " & localName(ins.dst) & " = (int64_t)_Alignof(" &
            cType(ins.typeRef) & ");\n"
  of hiOffsetof:
    acc.add "  " & localName(ins.dst) & " = (int64_t)offsetof(" &
            cType(ins.typeRef) & ", " & fieldC(ins.text) & ");\n"
  of hiRet:
    if ret.kind == tyVoid:
      acc.add "  return;\n"
    elif ins.a >= 0:
      acc.add "  return " & localName(ins.a) & ";\n"
    else:
      acc.add "  return ret;\n"
  of hiRetVal:
    acc.add "  ret.tag = 0;\n"
    acc.add "  ret.u.ok = " & localName(ins.a) & ";\n"
    acc.add "  return ret;\n"
  of hiRetErrFrom:
    let srcT = hp.slotTypes[ins.a]
    let errExpr =
      if srcT.kind == tyResult and srcT.elem.kind == tyVoid:
        localName(ins.a)
      else:
        localName(ins.a) & ".u.err"
    if ret.kind == tyResult and ret.elem.kind == tyVoid:
      acc.add "  ret = " & errExpr & ";\n"
    else:
      acc.add "  ret.tag = 1;\n"
      acc.add "  ret.u.err = " & errExpr & ";\n"
    acc.add "  return ret;\n"
  of hiNop:
    discard

proc emitProc(acc: var string; prog: Program; hp: HirProc) =
  let sym = prog.syms[hp.symId]
  let ret = sym.typ.ret
  acc.add cType(ret) & " " & sym.cname & "(" & paramList(hp) & ") {\n"
  if ret.kind != tyVoid:
    acc.add "  " & cType(ret) & " ret = {0};\n"
  for i in hp.paramCount ..< hp.slotTypes.len:
    acc.add "  " & cType(hp.slotTypes[i]) & " v" & $i & " = {0};\n"
  for i in 0 ..< hp.slotTypes.len:
    acc.add "  (void)v" & $i & ";\n"
  for ins in hp.instrs:
    emitInstr(acc, prog, hp, sym, ins)
  if ret.kind == tyVoid:
    acc.add "  return;\n"
  else:
    acc.add "  return ret;\n"
  acc.add "}\n\n"

proc emitC*(prog: Program; hirs: seq[HirProc]): string =
  var acc = "/* generated by cvn 0.5 (kernel MVP) */\n"
  var includes = @["<stdint.h>", "<stddef.h>", "<stdbool.h>", "<string.h>"]
  for m in prog.modules:
    for h in m.headers:
      if h notin includes:
        includes.add h
  if "<cvnrt.h>" notin includes:
    includes.add "<cvnrt.h>"
  for inc in includes:
    acc.add "#include " & inc & "\n"
  acc.add "\n"

  # Объекты: forward-декларации, определения, zero/new.
  for t in prog.objectTypes:
    acc.add "struct " & t.cname & ";\n"
    acc.add "typedef struct " & t.cname & " " & t.cname & ";\n"
  if prog.objectTypes.len > 0:
    acc.add "\n"
  for t in prog.objectTypes:
    acc.add "struct " & t.cname & " {\n"
    for f in t.fields:
      acc.add "  " & cType(f.typ) & " " & fieldC(f.name) & ";\n"
    acc.add "};\n"
  if prog.objectTypes.len > 0:
    acc.add "\n"
  for t in prog.objectTypes:
    acc.add "static void cvn_zero_" & t.cname & "(" & t.cname & " *p);\n"
    acc.add "static " & t.cname & " cvn_new_" & t.cname & "(void);\n"
  if prog.objectTypes.len > 0:
    acc.add "\n"
  for t in prog.objectTypes:
    acc.add "static void cvn_zero_" & t.cname & "(" & t.cname & " *p) {\n"
    acc.add "  memset(p, 0, sizeof *p);\n"
    for f in t.fields:
      if f.typ.kind == tyString:
        acc.add "  p->" & fieldC(f.name) & " = cvn_str_empty;\n"
      elif f.typ.kind == tyObject and not f.typ.opaque:
        acc.add "  cvn_zero_" & f.typ.cname & "(&p->" & fieldC(f.name) &
                ");\n"
    acc.add "}\n"
    acc.add "static " & t.cname & " cvn_new_" & t.cname & "(void) {\n"
    acc.add "  " & t.cname & " t;\n"
    acc.add "  cvn_zero_" & t.cname & "(&t);\n"
    acc.add "  return t;\n"
    acc.add "}\n\n"

  var resultNames: seq[string]
  var resultElems: seq[Type]
  for hp in hirs:
    for t in hp.slotTypes:
      if t.kind == tyResult and
         t.elem.kind notin {tyVoid, tyString, tyRune, tyInt, tyPtr}:
        let nm = resultName(t)
        if nm notin resultNames:
          resultNames.add nm
          resultElems.add t.elem
  for i in 0 ..< resultNames.len:
    acc.add "typedef struct { uint32_t tag; uint32_t _pad; union { " &
            cType(resultElems[i]) & " ok; cvn_error err; } u; } " &
            resultNames[i] & ";\n"
  if resultNames.len > 0:
    acc.add "\n"

  for i, s in prog.strings:
    acc.add "static cvn_string cvn_slit_" & $i & " = {" & cStringLit(s) &
            ", " & $s.len & ", " & $(s.len + 1) & ", {NULL, NULL}};\n"
  if prog.strings.len > 0:
    acc.add "\n"

  for hp in hirs:
    let sym = prog.syms[hp.symId]
    acc.add cType(sym.typ.ret) & " " & sym.cname & "(" & paramList(hp) &
            ");\n"
  acc.add "\n"

  for hp in hirs:
    emitProc(acc, prog, hp)

  acc.add "int main(void) {\n"
  acc.add "  cvn_rt_init();\n"
  acc.add "  cvn_error e = " & prog.entryMain.cname & "();\n"
  acc.add "  if (e.code != 0) { cvn_rt_report_error(e); return 1; }\n"
  acc.add "  return 0;\n"
  acc.add "}\n"
  result = acc
