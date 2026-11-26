## Рекурсивный спуск для подмножества MVP (README §3.2 плана).

import std/strutils
import diag, token, ast

type
  Parser = object
    toks: seq[Token]
    pos: int
    path: string

proc cur(p: Parser): Token =
  p.toks[min(p.pos, p.toks.len - 1)]

proc peek(p: Parser; n = 1): Token =
  p.toks[min(p.pos + n, p.toks.len - 1)]

proc advance(p: var Parser): Token =
  result = p.cur
  if p.pos < p.toks.len - 1:
    inc p.pos

proc failTok(p: Parser; code, msg: string; hint = "") {.noreturn.} =
  fail(code, p.path, p.cur.line, p.cur.col, msg, hint)

proc at*(p: Parser; kind: TokenKind): bool =
  p.cur.kind == kind

proc atKw*(p: Parser; kw: Keyword): bool =
  p.cur.kind == tkKeyword and p.cur.kw == kw

proc atOp*(p: Parser; text: string): bool =
  p.cur.kind == tkOperator and p.cur.text == text

proc accept(p: var Parser; kind: TokenKind): bool =
  if p.at(kind):
    discard p.advance()
    true
  else:
    false

proc acceptKw(p: var Parser; kw: Keyword): bool =
  if p.atKw(kw):
    discard p.advance()
    true
  else:
    false

proc expect(p: var Parser; kind: TokenKind; what: string): Token =
  if not p.at(kind):
    p.failTok("E-PARSE", "ожидался " & what & ", а получено '" & p.cur.text & "'")
  p.advance()

proc expectKw(p: var Parser; kw: Keyword; what: string): Token =
  if not p.atKw(kw):
    p.failTok("E-PARSE", "ожидался " & what)
  p.advance()

proc expectOp(p: var Parser; text: string): Token =
  if not p.atOp(text):
    p.failTok("E-PARSE", "ожидался оператор '" & text & "'")
  p.advance()

proc skipNewlines(p: var Parser) =
  while p.at(tkNewline):
    discard p.advance()

proc unsupported(p: Parser; what, version: string) {.noreturn.} =
  p.failTok("E-UNSUPPORTED",
            what & " не поддерживается в v0.5 (будет в " & version & ")",
            "см. README и docs/MVP.md")

proc versionFor(kw: Keyword): string =
  case kw
  of kwIf, kwElif, kwElse, kwWhile, kwFor, kwBreak, kwContinue, kwBlock,
     kwCase, kwOf, kwDo, kwYield, kwCatch, kwErrdefer, kwThrow, kwFunc,
     kwIterator, kwConst, kwImport, kwInclude, kwExport, kwWhen, kwEnum,
     kwUnion, kwDistinct, kwTuple, kwObject, kwTrue, kwFalse, kwIn, kwNotin,
     kwIs, kwIsnot, kwAs, kwCast, kwAddr, kwXor:
    "v0.2"
  of kwTemplate, kwConcept:
    "v0.3"
  of kwShared:
    "v0.4"
  of kwAsm:
    "v0.5"
  of kwSpawn, kwAwait:
    "v0.6"
  of kwClass, kwInterface, kwRef, kwWeak, kwNil:
    "v0.8"
  else:
    "v0.2"

proc parsePragmaBlock(p: var Parser): seq[AstNode] =
  discard p.expect(tkPragmaOpen, "{.")
  while true:
    if not p.at(tkIdent):
      p.failTok("E-PARSE", "ожидалось имя прагмы")
    let nt = p.cur
    let name = nt.text
    discard p.advance()
    var value = ""
    if p.at(tkColon):
      discard p.advance()
      if p.cur.kind in {tkIdent, tkStringLit, tkIntLit, tkKeyword, tkOperator}:
        value = p.cur.text
        discard p.advance()
      else:
        p.failTok("E-PARSE", "ожидалось значение прагмы")
    var n = newNode(nkPragma, nt.line, nt.col)
    n.pragmaName = name
    n.pragmaValue = value
    result.add n
    if p.at(tkComma):
      discard p.advance()
      continue
    break
  discard p.expect(tkPragmaClose, ".}")

proc parseModulePath(p: var Parser): string =
  if not p.at(tkIdent):
    p.failTok("E-PARSE", "ожидался путь модуля")
  result = p.cur.text
  discard p.advance()
  while p.atOp("/"):
    discard p.advance()
    if not p.at(tkIdent):
      p.failTok("E-PARSE", "ожидался сегмент пути модуля")
    result.add "/" & p.cur.text
    discard p.advance()

proc parseFromImport(p: var Parser): AstNode =
  let start = p.cur
  discard p.advance() # from
  let path = p.parseModulePath()
  discard p.expectKw(kwImport, "import")
  var names: seq[string]
  while true:
    if not p.at(tkIdent):
      p.failTok("E-PARSE", "ожидалось имя для импорта")
    names.add p.cur.text
    discard p.advance()
    if p.at(tkComma):
      discard p.advance()
      continue
    break
  result = newNode(nkFromImport, start.line, start.col)
  result.modulePath = path
  result.names = names

proc parseImport(p: var Parser): AstNode =
  let start = p.cur
  discard p.advance() # import
  let path = p.parseModulePath()
  result = newNode(nkFromImport, start.line, start.col)
  result.modulePath = path
  result.names = @[]
  result.importAll = true

proc parseTypeExpr(p: var Parser): AstNode
proc parseStmt(p: var Parser): AstNode

proc parseTypeBody(p: var Parser): AstNode =
  if not p.at(tkIdent):
    p.failTok("E-PARSE", "ожидалось имя типа")
  let nt = p.cur
  let name = nt.text
  discard p.advance()
  let exported = p.accept(tkStar)
  var pragmas: seq[AstNode]
  while p.at(tkPragmaOpen):
    pragmas.add p.parsePragmaBlock()
  discard p.expectOp("=")
  discard p.expectKw(kwObject, "object")
  while p.at(tkPragmaOpen):
    pragmas.add p.parsePragmaBlock()
  var fields: seq[AstNode]
  var hasFields = false
  if p.at(tkColon):
    discard p.advance()
    hasFields = true
  elif p.at(tkNewline) and p.peek(1).kind == tkIndent and
       p.peek(2).kind == tkIdent:
    discard p.advance()
    discard p.expect(tkIndent, "поля object")
    hasFields = true
  if hasFields:
    p.skipNewlines()
    while not p.at(tkDedent) and not p.at(tkEof):
      var names: seq[tuple[name: string, exported: bool, line, col: int]]
      while true:
        if not p.at(tkIdent):
          p.failTok("E-PARSE", "ожидалось имя поля")
        let ft = p.cur
        discard p.advance()
        let fexp = p.accept(tkStar)
        names.add (ft.text, fexp, ft.line, ft.col)
        if p.at(tkComma):
          discard p.advance()
          continue
        break
      discard p.expect(tkColon, ":")
      let ftyp = p.parseTypeExpr()
      for nm in names:
        var f = newNode(nkFieldDecl, nm.line, nm.col)
        f.declFieldName = nm.name
        f.declFieldExported = nm.exported
        f.declFieldType = ftyp
        fields.add f
      if p.cur.kind notin {tkNewline, tkDedent, tkEof}:
        p.failTok("E-PARSE", "ожидался конец строки с полем")
      p.skipNewlines()
    discard p.expect(tkDedent, "конец полей object")
  result = newNode(nkTypeDecl, nt.line, nt.col)
  result.declName = name
  result.exportedDecl = exported
  result.declPragmas = pragmas
  result.typeFields = fields

proc parseTypeSection(p: var Parser): seq[AstNode] =
  discard p.advance() # type
  if p.at(tkNewline):
    discard p.advance()
    discard p.expect(tkIndent, "блок type")
    p.skipNewlines()
    while not p.at(tkDedent) and not p.at(tkEof):
      result.add p.parseTypeBody()
      p.skipNewlines()
    discard p.expect(tkDedent, "конец блока type")
  else:
    result.add p.parseTypeBody()

proc parseTypeExpr(p: var Parser): AstNode =
  if p.atOp("!"):
    let t = p.cur
    discard p.advance()
    let inner = p.parseTypeExpr()
    result = newNode(nkResultType, t.line, t.col)
    result.elemType = inner
  elif p.atKw(kwPtr):
    let t = p.cur
    discard p.advance()
    let inner = p.parseTypeExpr()
    result = newNode(nkPtrType, t.line, t.col)
    result.elemType = inner
  elif p.atKw(kwVoid):
    let t = p.cur
    discard p.advance()
    result = newNode(nkTypeName, t.line, t.col)
    result.typeName = "void"
  elif p.at(tkIdent):
    let t = p.cur
    discard p.advance()
    if p.at(tkLBracket):
      p.unsupported("обобщённый тип", "v0.3")
    result = newNode(nkTypeName, t.line, t.col)
    result.typeName = t.text
  else:
    p.failTok("E-PARSE", "ожидался тип")

proc parseBlock(p: var Parser): AstNode =
  let t = p.cur
  result = newNode(nkBlock, t.line, t.col)
  if p.at(tkNewline):
    discard p.advance()
    discard p.expect(tkIndent, "блок с отступом")
    p.skipNewlines()
    while not p.at(tkDedent) and not p.at(tkEof):
      let st = p.parseStmt()
      result.stmts.add st
      # блок `defer:` съедает свой newline и dedent, поэтому следующим
      # токеном может быть начало следующего оператора
      if st.kind != nkDefer and p.cur.kind notin {tkNewline, tkDedent, tkEof}:
        p.failTok("E-PARSE", "ожидался конец строки")
      p.skipNewlines()
    discard p.expect(tkDedent, "конец блока")
  else:
    result.stmts.add p.parseStmt()

proc parseBodyAfterColon(p: var Parser): AstNode =
  discard p.expect(tkColon, ":")
  result = p.parseBlock()

proc parseBodyAfterEq(p: var Parser): AstNode =
  discard p.expectOp("=")
  result = p.parseBlock()

proc parseTypeContinuation(p: var Parser; pragmas: var seq[AstNode]) =
  ## Продолжение заголовка процедуры прагмами на следующей строке с отступом.
  if p.at(tkNewline) and p.peek(1).kind == tkIndent and
     p.peek(2).kind == tkPragmaOpen:
    discard p.advance() # newline
    discard p.expect(tkIndent, "отступ прагм")
    while p.at(tkPragmaOpen):
      pragmas.add p.parsePragmaBlock()
    discard p.expect(tkNewline, "конец строки с прагмами")
    discard p.expect(tkDedent, "конец прагм")

proc parseProc(p: var Parser): AstNode =
  let start = p.cur
  discard p.advance() # proc
  if not p.at(tkIdent):
    p.failTok("E-PARSE", "ожидалось имя процедуры")
  let nameTok = p.cur
  let name = nameTok.text
  discard p.advance()
  let exported = p.accept(tkStar)
  if p.at(tkLBracket):
    p.unsupported("обобщённая процедура", "v0.3")
  discard p.expect(tkLParen, "(")
  var params: seq[AstNode]
  if not p.at(tkRParen):
    while true:
      if not p.at(tkIdent):
        p.failTok("E-PARSE", "ожидалось имя параметра")
      let pn = p.cur
      discard p.advance()
      discard p.expect(tkColon, ":")
      let isVar = p.acceptKw(kwVar)
      let pt = p.parseTypeExpr()
      var param = newNode(nkParam, pn.line, pn.col)
      param.paramName = pn.text
      param.paramVar = isVar
      param.paramTypeNode = pt
      params.add param
      if p.at(tkComma):
        discard p.advance()
        continue
      break
  discard p.expect(tkRParen, ")")
  if not p.at(tkColon):
    fail("E-NO-RETTYPE", p.path, nameTok.line, nameTok.col,
         "у процедуры '" & name & "' нет типа результата",
         "укажите ': !void', ': int' и т.п.")
  discard p.advance()
  let retType = p.parseTypeExpr()
  var pragmas: seq[AstNode]
  while p.at(tkPragmaOpen):
    pragmas.add p.parsePragmaBlock()
  p.parseTypeContinuation(pragmas)
  var body: AstNode = nil
  if p.atOp("="):
    body = p.parseBodyAfterEq()
  result = newNode(nkProcDecl, start.line, start.col)
  result.procName = name
  result.exportedProc = exported
  result.params = params
  result.retTypeNode = retType
  result.body = body
  result.procPragmas = pragmas

proc parseExpr(p: var Parser): AstNode
proc parseUnary(p: var Parser): AstNode
proc parsePostfix(p: var Parser): AstNode

proc parseAtom(p: var Parser): AstNode =
  let t = p.cur
  case t.kind
  of tkIntLit:
    discard p.advance()
    result = newNode(nkIntLit, t.line, t.col)
    result.intVal = int64(parseBiggestInt(t.text))
  of tkCharLit:
    discard p.advance()
    result = newNode(nkCharLit, t.line, t.col)
    result.charVal = parseInt(t.text)
  of tkStringLit:
    discard p.advance()
    result = newNode(nkStrLit, t.line, t.col)
    result.strVal = t.text
  of tkIdent:
    discard p.advance()
    result = newNode(nkIdent, t.line, t.col)
    result.name = t.text
  of tkLParen:
    discard p.advance()
    result = p.parseExpr()
    discard p.expect(tkRParen, ")")
  of tkKeyword:
    case t.kw
    of kwTry:
      discard p.advance()
      let inner = p.parseUnary()
      result = newNode(nkTry, t.line, t.col)
      result.operand = inner
    of kwNot:
      discard p.advance()
      let inner = p.parseUnary()
      result = newNode(nkUnary, t.line, t.col)
      result.op = "not"
      result.a = inner
    of kwTrue, kwFalse:
      p.unsupported("bool-литерал", "v0.2")
    else:
      p.unsupported("выражение с '" & t.text & "'", versionFor(t.kw))
  else:
    p.failTok("E-PARSE", "ожидалось выражение, а получено '" & t.text & "'")

proc parseUnary(p: var Parser): AstNode =
  if p.atOp("-") or p.atOp("+"):
    let t = p.cur
    let op = t.text
    discard p.advance()
    let inner = p.parseUnary()
    result = newNode(nkUnary, t.line, t.col)
    result.op = op
    result.a = inner
  else:
    result = p.parsePostfix()

proc parsePostfix(p: var Parser): AstNode =
  result = p.parseAtom()
  while true:
    if p.at(tkLParen):
      let t = p.cur
      discard p.advance()
      var args: seq[AstNode]
      if not p.at(tkRParen):
        while true:
          if p.at(tkIdent) and p.peek(1).kind == tkColon:
            let nt = p.cur
            discard p.advance()
            discard p.advance()
            let v = p.parseExpr()
            var nf = newNode(nkNamedField, nt.line, nt.col)
            nf.namedName = nt.text
            nf.namedValue = v
            args.add nf
          else:
            if p.at(tkIdent) and p.peek(1).kind == tkOperator and
               p.peek(1).text == "=":
              p.unsupported("именованный аргумент '='", "v0.3")
            args.add p.parseExpr()
          if p.at(tkComma):
            discard p.advance()
            continue
          break
      discard p.expect(tkRParen, ")")
      var call = newNode(nkCall, t.line, t.col)
      call.callee = result
      call.args = args
      result = call
    elif p.at(tkDot):
      let t = p.cur
      discard p.advance()
      if not p.at(tkIdent):
        p.failTok("E-PARSE", "ожидалось имя поля после '.'")
      let ft = p.cur
      discard p.advance()
      var f = newNode(nkField, t.line, t.col)
      f.obj = result
      f.fieldName = ft.text
      result = f
    elif p.at(tkLBracket):
      let t = p.cur
      discard p.advance()
      if p.at(tkRBracket):
        discard p.advance()
        var d = newNode(nkDeref, t.line, t.col)
        d.derefObj = result
        result = d
      else:
        p.unsupported("индексация p[i]", "v0.6")
    else:
      break

proc parseMul(p: var Parser): AstNode =
  result = p.parsePostfix()
  while p.atOp("*") or p.atOp("/") or p.atOp("%"):
    let t = p.cur
    discard p.advance()
    let rhs = p.parsePostfix()
    var n = newNode(nkBinary, t.line, t.col)
    n.op = t.text
    n.a = result
    n.b = rhs
    result = n

proc parseAdd(p: var Parser): AstNode =
  result = p.parseMul()
  while p.atOp("+") or p.atOp("-"):
    let t = p.cur
    discard p.advance()
    let rhs = p.parseMul()
    var n = newNode(nkBinary, t.line, t.col)
    n.op = t.text
    n.a = result
    n.b = rhs
    result = n

proc parseCmp(p: var Parser): AstNode =
  result = p.parseAdd()
  while true:
    if p.atOp("==") or p.atOp("!=") or p.atOp("<") or p.atOp("<=") or
       p.atOp(">") or p.atOp(">="):
      let t = p.cur
      discard p.advance()
      let rhs = p.parseAdd()
      var n = newNode(nkBinary, t.line, t.col)
      n.op = t.text
      n.a = result
      n.b = rhs
      result = n
    elif p.atKw(kwIn) or p.atKw(kwNotin) or p.atKw(kwIs) or p.atKw(kwIsnot):
      p.unsupported("оператор принадлежности/типа", "v0.2")
    elif p.atOp("..") or p.atOp("..<"):
      p.unsupported("диапазон", "v0.2")
    else:
      break

proc parseAnd(p: var Parser): AstNode =
  result = p.parseCmp()
  while p.atKw(kwAnd):
    let t = p.cur
    discard p.advance()
    let rhs = p.parseCmp()
    var n = newNode(nkBinary, t.line, t.col)
    n.op = "and"
    n.a = result
    n.b = rhs
    result = n

proc parseOr(p: var Parser): AstNode =
  result = p.parseAnd()
  while p.atKw(kwOr):
    let t = p.cur
    discard p.advance()
    let rhs = p.parseAnd()
    var n = newNode(nkBinary, t.line, t.col)
    n.op = "or"
    n.a = result
    n.b = rhs
    result = n

proc parseExpr(p: var Parser): AstNode =
  result = p.parseOr()

proc parseExprOrAssign(p: var Parser): AstNode =
  result = p.parseExpr()
  if p.atOp("="):
    let eq = p.cur
    discard p.advance()
    let rhs = p.parseExpr()
    var n = newNode(nkAssign, eq.line, eq.col)
    n.lhs = result
    n.rhs = rhs
    result = n

proc parseStmt(p: var Parser): AstNode =
  let t = p.cur
  case t.kind
  of tkKeyword:
    case t.kw
    of kwLet, kwVar:
      discard p.advance()
      if not p.at(tkIdent):
        p.failTok("E-PARSE", "ожидалось имя переменной")
      let nt = p.cur
      discard p.advance()
      var typeNode: AstNode = nil
      if p.at(tkColon):
        discard p.advance()
        typeNode = p.parseTypeExpr()
      if not p.atOp("="):
        p.failTok("E-UNSUPPORTED",
                  "объявление без инициализации не поддерживается в v0.1 (v0.2)")
      discard p.advance()
      let initExpr = p.parseExpr()
      let declKind = if t.kw == kwLet: nkLet else: nkVar
      result = newNode(declKind, t.line, t.col)
      result.varName = nt.text
      result.varTypeNode = typeNode
      result.init = initExpr
    of kwDefer:
      discard p.advance()
      result = newNode(nkDefer, t.line, t.col)
      result.deferBody = p.parseBodyAfterColon()
    of kwReturn:
      discard p.advance()
      result = newNode(nkReturn, t.line, t.col)
      if p.cur.kind notin {tkNewline, tkDedent, tkEof}:
        result.value = p.parseExpr()
    of kwDiscard:
      discard p.advance()
      result = newNode(nkDiscard, t.line, t.col)
      if p.cur.kind in {tkNewline, tkDedent, tkEof}:
        p.failTok("E-PARSE", "discard требует выражение")
      result.value = p.parseExpr()
    of kwTry:
      if p.peek(1).kind == tkColon:
        p.unsupported("try:-блок", "v0.2")
      result = p.parseExpr()
    of kwProc, kwType, kwFrom, kwImport:
      p.failTok("E-UNSUPPORTED",
                "объявления внутри процедуры не поддерживаются в v0.1 (v0.2)")
    else:
      p.unsupported("оператор '" & t.text & "'", versionFor(t.kw))
  of tkIdent, tkIntLit, tkStringLit, tkCharLit, tkLParen:
    result = p.parseExprOrAssign()
  of tkOperator:
    if t.text == "-" or t.text == "+":
      result = p.parseExprOrAssign()
    else:
      p.failTok("E-PARSE", "неожиданный оператор '" & t.text & "'")
  else:
    p.failTok("E-PARSE", "ожидался оператор, а получено '" & t.text & "'")

proc parseDecl(p: var Parser): seq[AstNode] =
  let t = p.cur
  case t.kind
  of tkKeyword:
    case t.kw
    of kwType:
      result = p.parseTypeSection()
    of kwProc:
      result.add p.parseProc()
    of kwFrom:
      p.failTok("E-PARSE", "from-импорт должен идти до объявлений")
    else:
      p.unsupported("объявление '" & t.text & "'", versionFor(t.kw))
  else:
    p.failTok("E-PARSE", "ожидалось объявление, а получено '" & t.text & "'")

proc parseModule*(toks: seq[Token]; path: string): AstNode =
  var p = Parser(toks: toks, pos: 0, path: path)
  let first = p.cur
  result = newNode(nkModule, first.line, first.col)
  p.skipNewlines()
  while p.at(tkPragmaOpen):
    for pr in p.parsePragmaBlock():
      result.stmts.add pr
    p.skipNewlines()
  while p.atKw(kwFrom) or p.atKw(kwImport):
    if p.atKw(kwFrom):
      result.stmts.add p.parseFromImport()
    else:
      result.stmts.add p.parseImport()
    p.skipNewlines()
  while not p.at(tkEof):
    if p.at(tkPragmaOpen):
      p.failTok("E-PARSE",
                "прагма модуля должна стоять до импортов (README §2.7)")
    for d in p.parseDecl():
      result.stmts.add d
    p.skipNewlines()
