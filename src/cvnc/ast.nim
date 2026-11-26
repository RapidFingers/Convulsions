## AST Convulsions (подмножество MVP).

import std/strutils
import types

type
  NodeKind* = enum
    nkModule, nkPragma, nkFromImport, nkTypeDecl, nkProcDecl, nkParam,
    nkBlock, nkLet, nkVar, nkDefer, nkReturn, nkDiscard, nkCall, nkField,
    nkIdent, nkIntLit, nkStrLit, nkCharLit, nkUnary, nkBinary, nkTry,
    nkTypeName, nkPtrType, nkResultType, nkFieldDecl, nkNamedField, nkAssign,
    nkDeref, nkTypeApply, nkSpawn, nkAwait, nkBoolLit, nkIf, nkWhile,
    nkBreak, nkContinue

  AstNode* = ref object
    line*: int
    col*: int
    typ*: Type
    symId*: int
    convTo*: Type
    typeRef*: Type
    genericParams*: seq[string]
    case kind*: NodeKind
    of nkIdent:
      name*: string
    of nkTypeName:
      typeName*: string
    of nkTypeApply:
      appliedName*: string
      appliedArgs*: seq[AstNode]
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
      genericArgs*: seq[AstNode]
    of nkPragma:
      pragmaName*: string
      pragmaValue*: string
    of nkFromImport:
      modulePath*: string
      names*: seq[string]
      importAll*: bool
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
    of nkDeref:
      derefObj*: AstNode
    of nkSpawn:
      spawnCall*: AstNode
    of nkAwait:
      awaitTask*: AstNode
    of nkBoolLit:
      boolVal*: bool
    of nkIf:
      cond*: AstNode
      thenBody*: AstNode
      elseBody*: AstNode
    of nkWhile:
      whileCond*: AstNode
      whileBody*: AstNode
    of nkBreak, nkContinue:
      discard

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
  of nkTypeApply: result.add " " & n.appliedName & "[" & $n.appliedArgs.len & "]"
  of nkIntLit: result.add " " & $n.intVal
  of nkCharLit: result.add " '" & $n.charVal & "'"
  of nkStrLit: result.add " " & repr(n.strVal)
  of nkPragma: result.add " " & n.pragmaName & "=" & n.pragmaValue
  of nkFromImport:
    result.add " " & n.modulePath
    if n.importAll: result.add " *"
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
  of nkDeref:
    result.add dumpAst(n.derefObj, indent + 1)
  of nkSpawn:
    result.add dumpAst(n.spawnCall, indent + 1)
  of nkAwait:
    result.add dumpAst(n.awaitTask, indent + 1)
  of nkBoolLit:
    result.add(if n.boolVal: " true" else: " false")
  of nkIf:
    result.add dumpAst(n.cond, indent + 1)
    result.add dumpAst(n.thenBody, indent + 1)
    result.add dumpAst(n.elseBody, indent + 1)
  of nkWhile:
    result.add dumpAst(n.whileCond, indent + 1)
    result.add dumpAst(n.whileBody, indent + 1)
  of nkTypeApply:
    for a in n.appliedArgs:
      result.add dumpAst(a, indent + 1)
  else: discard

proc cloneAst*(n: AstNode): AstNode =
  if n.isNil:
    return nil
  result = newNode(n.kind, n.line, n.col)
  result.symId = -1
  result.genericParams = n.genericParams
  case n.kind
  of nkIdent: result.name = n.name
  of nkTypeName: result.typeName = n.typeName
  of nkTypeApply:
    result.appliedName = n.appliedName
    for a in n.appliedArgs:
      result.appliedArgs.add cloneAst(a)
  of nkIntLit: result.intVal = n.intVal
  of nkCharLit: result.charVal = n.charVal
  of nkStrLit: result.strVal = n.strVal
  of nkUnary, nkBinary:
    result.op = n.op
    result.a = cloneAst(n.a)
    result.b = cloneAst(n.b)
  of nkTry:
    result.operand = cloneAst(n.operand)
  of nkField:
    result.obj = cloneAst(n.obj)
    result.fieldName = n.fieldName
  of nkCall:
    result.callee = cloneAst(n.callee)
    for a in n.args:
      result.args.add cloneAst(a)
    for a in n.genericArgs:
      result.genericArgs.add cloneAst(a)
  of nkPragma:
    result.pragmaName = n.pragmaName
    result.pragmaValue = n.pragmaValue
  of nkFromImport:
    result.modulePath = n.modulePath
    result.names = n.names
    result.importAll = n.importAll
  of nkTypeDecl:
    result.declName = n.declName
    result.exportedDecl = n.exportedDecl
    result.importedDecl = n.importedDecl
    result.cNameDecl = n.cNameDecl
    result.genericParams = n.genericParams
    for p in n.declPragmas:
      result.declPragmas.add cloneAst(p)
    for f in n.typeFields:
      result.typeFields.add cloneAst(f)
  of nkParam:
    result.paramName = n.paramName
    result.paramVar = n.paramVar
    result.paramTypeNode = cloneAst(n.paramTypeNode)
  of nkProcDecl:
    result.procName = n.procName
    result.exportedProc = n.exportedProc
    result.genericParams = n.genericParams
    for p in n.params:
      result.params.add cloneAst(p)
    result.retTypeNode = cloneAst(n.retTypeNode)
    result.body = cloneAst(n.body)
    for p in n.procPragmas:
      result.procPragmas.add cloneAst(p)
  of nkLet, nkVar:
    result.varName = n.varName
    result.varTypeNode = cloneAst(n.varTypeNode)
    result.init = cloneAst(n.init)
  of nkModule, nkBlock:
    for s in n.stmts:
      result.stmts.add cloneAst(s)
  of nkDefer:
    result.deferBody = cloneAst(n.deferBody)
  of nkReturn, nkDiscard:
    result.value = cloneAst(n.value)
  of nkPtrType, nkResultType:
    result.elemType = cloneAst(n.elemType)
  of nkFieldDecl:
    result.declFieldName = n.declFieldName
    result.declFieldExported = n.declFieldExported
    result.declFieldType = cloneAst(n.declFieldType)
  of nkNamedField:
    result.namedName = n.namedName
    result.namedValue = cloneAst(n.namedValue)
  of nkAssign:
    result.lhs = cloneAst(n.lhs)
    result.rhs = cloneAst(n.rhs)
  of nkDeref:
    result.derefObj = cloneAst(n.derefObj)
  of nkSpawn:
    result.spawnCall = cloneAst(n.spawnCall)
  of nkAwait:
    result.awaitTask = cloneAst(n.awaitTask)
  of nkBoolLit:
    result.boolVal = n.boolVal
  of nkIf:
    result.cond = cloneAst(n.cond)
    result.thenBody = cloneAst(n.thenBody)
    result.elseBody = cloneAst(n.elseBody)
  of nkWhile:
    result.whileCond = cloneAst(n.whileCond)
    result.whileBody = cloneAst(n.whileBody)
  of nkBreak, nkContinue:
    discard
