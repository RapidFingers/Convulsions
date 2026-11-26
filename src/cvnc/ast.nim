## AST Convulsions (подмножество MVP).

import std/strutils
import types

type
  NodeKind* = enum
    nkModule, nkPragma, nkFromImport, nkTypeDecl, nkProcDecl, nkParam,
    nkBlock, nkLet, nkVar, nkDefer, nkReturn, nkDiscard, nkCall, nkField,
    nkIdent, nkIntLit, nkStrLit, nkCharLit, nkUnary, nkBinary, nkTry,
    nkTypeName, nkPtrType, nkResultType, nkFieldDecl, nkNamedField, nkAssign

  AstNode* = ref object
    line*: int
    col*: int
    typ*: Type
    symId*: int
    convTo*: Type
    typeRef*: Type
    case kind*: NodeKind
    of nkIdent:
      name*: string
    of nkTypeName:
      typeName*: string
    of nkIntLit:
      intVal*: int64
    of nkCharLit:
      charVal*: int
    of nkStrLit:
      strVal*: string
    of nkUnary, nkBinary:
      op*: string
      a*: AstNode
      b*: AstNode
    of nkTry:
      operand*: AstNode
    of nkField:
      obj*: AstNode
      fieldName*: string
    of nkCall:
      callee*: AstNode
      args*: seq[AstNode]
    of nkPragma:
      pragmaName*: string
      pragmaValue*: string
    of nkFromImport:
      modulePath*: string
      names*: seq[string]
    of nkTypeDecl:
      declName*: string
      exportedDecl*: bool
      importedDecl*: bool
      cNameDecl*: string
      declPragmas*: seq[AstNode]
      typeFields*: seq[AstNode]
    of nkParam:
      paramName*: string
      paramVar*: bool
      paramTypeNode*: AstNode
    of nkProcDecl:
      procName*: string
      exportedProc*: bool
      params*: seq[AstNode]
      retTypeNode*: AstNode
      body*: AstNode
      procPragmas*: seq[AstNode]
    of nkLet, nkVar:
      varName*: string
      varTypeNode*: AstNode
      init*: AstNode
    of nkModule, nkBlock:
      stmts*: seq[AstNode]
    of nkDefer:
      deferBody*: AstNode
    of nkReturn, nkDiscard:
      value*: AstNode
    of nkPtrType, nkResultType:
      elemType*: AstNode
    of nkFieldDecl:
      declFieldName*: string
      declFieldExported*: bool
      declFieldType*: AstNode
    of nkNamedField:
      namedName*: string
      namedValue*: AstNode
    of nkAssign:
      lhs*: AstNode
      rhs*: AstNode

proc newNode*(kind: NodeKind; line, col: int): AstNode =
  AstNode(kind: kind, line: line, col: col)

proc add*(n: AstNode; child: AstNode) =
  n.stmts.add child

proc dumpAst*(n: AstNode; indent = 0): string =
  if n.isNil:
    return ""
  let pad = repeat(' ', indent * 2)
  result = pad & $n.kind
  case n.kind
  of nkIdent: result.add " " & n.name
  of nkTypeName: result.add " " & n.typeName
  of nkIntLit: result.add " " & $n.intVal
  of nkCharLit: result.add " '" & $n.charVal & "'"
  of nkStrLit: result.add " " & repr(n.strVal)
  of nkPragma: result.add " " & n.pragmaName & "=" & n.pragmaValue
  of nkFromImport: result.add " " & n.modulePath
  of nkTypeDecl: result.add " " & n.declName
  of nkFieldDecl: result.add " " & n.declFieldName
  of nkNamedField: result.add " " & n.namedName
  of nkAssign: result.add " ="
  of nkProcDecl: result.add " " & n.procName
  of nkField: result.add " ." & n.fieldName
  of nkBinary, nkUnary: result.add " " & n.op
  else: discard
  result.add "\n"
  case n.kind
  of nkModule, nkBlock:
    for s in n.stmts:
      result.add dumpAst(s, indent + 1)
  of nkProcDecl:
    for p in n.params:
      result.add dumpAst(p, indent + 1)
    result.add dumpAst(n.retTypeNode, indent + 1)
    result.add dumpAst(n.body, indent + 1)
  of nkDefer:
    result.add dumpAst(n.deferBody, indent + 1)
  of nkReturn, nkDiscard:
    result.add dumpAst(n.value, indent + 1)
  of nkCall:
    result.add dumpAst(n.callee, indent + 1)
    for a in n.args:
      result.add dumpAst(a, indent + 1)
  of nkField:
    result.add dumpAst(n.obj, indent + 1)
  of nkTypeDecl:
    for f in n.typeFields:
      result.add dumpAst(f, indent + 1)
  of nkTry:
    result.add dumpAst(n.operand, indent + 1)
  of nkBinary, nkUnary:
    result.add dumpAst(n.a, indent + 1)
    result.add dumpAst(n.b, indent + 1)
  of nkLet, nkVar:
    result.add dumpAst(n.init, indent + 1)
  of nkParam:
    result.add dumpAst(n.paramTypeNode, indent + 1)
  of nkPtrType, nkResultType:
    result.add dumpAst(n.elemType, indent + 1)
  of nkFieldDecl:
    result.add dumpAst(n.declFieldType, indent + 1)
  of nkNamedField:
    result.add dumpAst(n.namedValue, indent + 1)
  of nkAssign:
    result.add dumpAst(n.lhs, indent + 1)
    result.add dumpAst(n.rhs, indent + 1)
  else: discard
