## Лексер Convulsions: байтовый скан, INDENT/DEDENT, литералы.
##
## Колонки считаются в байтах, 1-based. Внутри `(`/`[`/`{.` переносы строк
## не порождают tkNewline и отступы игнорируются (README §2.1).

import std/[strutils, unicode]
import diag, token

type
  Lexer = object
    src, path: string
    i, line, col: int
    tokens: seq[Token]
    indents: seq[int]
    depth: int
    atLineStart: bool
    lastNewline: bool

proc failAt(l: Lexer; code, msg: string; hint = "") {.noreturn.} =
  fail(code, l.path, l.line, l.col, msg, hint)

proc addTokAt(l: var Lexer; kind: TokenKind; text: string; line, col: int;
              kw = kwNone) =
  l.tokens.add Token(kind: kind, text: text, kw: kw, line: line, col: col)
  l.lastNewline = kind == tkNewline

proc bump(l: var Lexer) =
  if l.i >= l.src.len:
    return
  let c = l.src[l.i]
  if c == '\r':
    inc l.i
    if l.i < l.src.len and l.src[l.i] == '\n':
      inc l.i
    inc l.line
    l.col = 1
  elif c == '\n':
    inc l.i
    inc l.line
    l.col = 1
  else:
    inc l.i
    inc l.col

proc bumpN(l: var Lexer; n: int) =
  for _ in 0 ..< n:
    l.bump()

proc isIdentChar(c: char): bool =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc isDigit(c: char): bool =
  c in {'0'..'9'}

proc hexVal(c: char): int =
  if c in {'0'..'9'}: ord(c) - ord('0')
  elif c in {'a'..'f'}: ord(c) - ord('a') + 10
  elif c in {'A'..'F'}: ord(c) - ord('A') + 10
  else: -1

proc skipComment(l: var Lexer) =
  if l.i + 1 < l.src.len and l.src[l.i] == '#' and l.src[l.i + 1] == '[':
    var d = 1
    l.bumpN(2)
    while l.i < l.src.len:
      if l.i + 1 < l.src.len and l.src[l.i] == '#' and l.src[l.i + 1] == '[':
        inc d
        l.bumpN(2)
      elif l.i + 1 < l.src.len and l.src[l.i] == ']' and l.src[l.i + 1] == '#':
        dec d
        l.bumpN(2)
        if d == 0:
          return
      else:
        l.bump()
    l.failAt("E-LEX-COMMENT", "незакрытый блочный комментарий")
  else:
    while l.i < l.src.len and not (l.src[l.i] in {'\n', '\r'}):
      l.bump()

proc addRune(l: var Lexer; s: var string; cp: int) =
  if cp < 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
    l.failAt("E-LEX-ESCAPE", "недопустимый кодпоинт в \\u{...}")
  if cp <= 0x7F:
    s.add chr(cp)
  elif cp <= 0x7FF:
    s.add chr(0xC0 or (cp shr 6))
    s.add chr(0x80 or (cp and 0x3F))
  elif cp <= 0xFFFF:
    s.add chr(0xE0 or (cp shr 12))
    s.add chr(0x80 or ((cp shr 6) and 0x3F))
    s.add chr(0x80 or (cp and 0x3F))
  else:
    s.add chr(0xF0 or (cp shr 18))
    s.add chr(0x80 or ((cp shr 12) and 0x3F))
    s.add chr(0x80 or ((cp shr 6) and 0x3F))
    s.add chr(0x80 or (cp and 0x3F))

proc scanChar(l: var Lexer) =
  let sl = l.line
  let sc = l.col
  l.bump() # '
  if l.i >= l.src.len or l.src[l.i] in {'\n', '\r'}:
    l.failAt("E-LEX-CHAR", "незакрытый char-литерал")
  var v = 0
  if l.src[l.i] == '\\':
    l.bump()
    if l.i >= l.src.len:
      l.failAt("E-LEX-CHAR", "незакрытый escape в char-литерале")
    let e = l.src[l.i]
    case e
    of 'n': v = 10; l.bump()
    of 't': v = 9; l.bump()
    of 'r': v = 13; l.bump()
    of '0': v = 0; l.bump()
    of '\\': v = 92; l.bump()
    of '\'': v = 39; l.bump()
    of 'x':
      l.bump()
      if l.i + 1 >= l.src.len:
        l.failAt("E-LEX-ESCAPE", "\\xNN: нужно две шестнадцатеричные цифры")
      let h1 = hexVal(l.src[l.i])
      let h2 = hexVal(l.src[l.i + 1])
      if h1 < 0 or h2 < 0:
        l.failAt("E-LEX-ESCAPE", "\\xNN: некорректная цифра")
      v = h1 * 16 + h2
      l.bumpN(2)
    of 'u':
      l.failAt("E-LEX-ESCAPE",
               "char — байт: \\u{...} в char-литерале запрещён",
               "используйте строку или Rune(runeAt(...))")
    else:
      l.failAt("E-LEX-ESCAPE", "неизвестный escape в char-литерале: \\" & $e)
  else:
    if ord(l.src[l.i]) >= 128:
      l.failAt("E-LEX-CHAR",
               "char — байт: не-ASCII символ в char-литерале запрещён",
               "используйте строку или Rune/runeAt")
    if l.src[l.i] == '\'':
      l.failAt("E-LEX-CHAR", "пустой char-литерал")
    v = ord(l.src[l.i])
    l.bump()
  if l.i >= l.src.len or l.src[l.i] != '\'':
    l.failAt("E-LEX-CHAR", "ожидалась закрывающая кавычка char-литерала")
  l.bump()
  l.addTokAt(tkCharLit, $v, sl, sc)

proc scanString(l: var Lexer) =
  let sl = l.line
  let sc = l.col
  l.bump() # "
  var res = ""
  while true:
    if l.i >= l.src.len:
      l.failAt("E-LEX-STRING", "незакрытый строковый литерал")
    if l.src[l.i] == '"':
      l.bump()
      break
    if l.src[l.i] in {'\n', '\r'}:
      l.failAt("E-LEX-STRING", "многострочные строки не поддерживаются (v0.2)")
    if l.src[l.i] == '\\':
      l.bump()
      if l.i >= l.src.len:
        l.failAt("E-LEX-STRING", "незакрытый escape")
      let e = l.src[l.i]
      case e
      of 'n': res.add '\n'; l.bump()
      of 't': res.add '\t'; l.bump()
      of 'r': res.add '\r'; l.bump()
      of '0': res.add '\0'; l.bump()
      of '\\': res.add '\\'; l.bump()
      of '"': res.add '"'; l.bump()
      of 'x':
        l.bump()
        if l.i + 1 >= l.src.len:
          l.failAt("E-LEX-ESCAPE", "\\xNN: нужно две шестнадцатеричные цифры")
        let h1 = hexVal(l.src[l.i])
        let h2 = hexVal(l.src[l.i + 1])
        if h1 < 0 or h2 < 0:
          l.failAt("E-LEX-ESCAPE", "\\xNN: некорректная цифра")
        res.add chr(h1 * 16 + h2)
        l.bumpN(2)
      of 'u':
        l.bump()
        if l.i >= l.src.len or l.src[l.i] != '{':
          l.failAt("E-LEX-ESCAPE", "\\u: ожидалась '{'")
        l.bump()
        var cp = 0
        var nd = 0
        while l.i < l.src.len and l.src[l.i] != '}':
          let h = hexVal(l.src[l.i])
          if h < 0:
            l.failAt("E-LEX-ESCAPE", "\\u{...}: некорректная цифра")
          cp = cp * 16 + h
          inc nd
          if nd > 6:
            l.failAt("E-LEX-ESCAPE", "\\u{...}: слишком много цифр")
          l.bump()
        if l.i >= l.src.len or nd == 0:
          l.failAt("E-LEX-ESCAPE", "\\u{...}: пустая последовательность")
        l.bump() # }
        l.addRune(res, cp)
      else:
        l.failAt("E-LEX-ESCAPE", "неизвестный escape \\" & $e)
    else:
      res.add l.src[l.i]
      l.bump()
  l.addTokAt(tkStringLit, res, sl, sc)

proc scanNumber(l: var Lexer) =
  let sl = l.line
  let sc = l.col
  let start = l.i
  if l.i + 1 < l.src.len and l.src[l.i] == '0' and
     (l.src[l.i + 1] in {'x', 'X', 'b', 'B', 'o', 'O'}):
    l.bumpN(2)
    while l.i < l.src.len and (isIdentChar(l.src[l.i]) or l.src[l.i] == '_'):
      l.bump()
  else:
    while l.i < l.src.len and (isDigit(l.src[l.i]) or l.src[l.i] == '_'):
      l.bump()

  if l.i < l.src.len and l.src[l.i] == '\'':
    l.failAt("E-LEX-NUMBER", "суффиксы литералов ('i8, 'u64) будут в v0.2")
  if l.i < l.src.len and l.src[l.i] == '.' and
     not (l.i + 1 < l.src.len and l.src[l.i + 1] == '.'):
    if l.i + 1 < l.src.len and isDigit(l.src[l.i + 1]):
      l.failAt("E-LEX-NUMBER", "вещественные литералы будут в v0.2")
  if l.i < l.src.len and l.src[l.i] in {'e', 'E'}:
    l.failAt("E-LEX-NUMBER", "вещественные литералы будут в v0.2")

  var raw = l.src[start ..< l.i].replace("_", "")
  if raw.len == 0:
    l.failAt("E-LEX-NUMBER", "пустой числовой литерал")
  var value: BiggestInt = 0
  let low = raw.toLowerAscii()
  var base = 10
  var idx = 0
  if low.startsWith("0x"):
    base = 16; idx = 2
  elif low.startsWith("0b"):
    base = 2; idx = 2
  elif low.startsWith("0o"):
    base = 8; idx = 2
  if idx >= raw.len:
    l.failAt("E-LEX-NUMBER", "пустой числовой литерал: " & raw)
  for k in idx ..< raw.len:
    let d = hexVal(raw[k])
    if d < 0 or d >= base:
      l.failAt("E-LEX-NUMBER", "некорректная цифра в литерале: " & raw)
    if value > (high(BiggestInt) - BiggestInt(d)) div BiggestInt(base):
      l.failAt("E-LEX-NUMBER", "литерал переполняет int64: " & raw)
    value = value * BiggestInt(base) + BiggestInt(d)
  l.addTokAt(tkIntLit, $value, sl, sc)

proc scanIdent(l: var Lexer) =
  let sl = l.line
  let sc = l.col
  let start = l.i
  while l.i < l.src.len and isIdentChar(l.src[l.i]):
    l.bump()
  let s = l.src[start ..< l.i]
  if s == "b" and l.i < l.src.len and l.src[l.i] == '"':
    # b"..." — байтовая строка: тот же разбор escape, тип string
    l.scanString()
    return
  if s.len == 1 and s[0] == 'r' and l.i < l.src.len and l.src[l.i] == '"':
    l.failAt("E-LEX-STRING", "raw-строки (r\"...\") будут в v0.2")
  let kw = keywordOf(s)
  if kw != kwNone:
    l.addTokAt(tkKeyword, s, sl, sc, kw)
  else:
    l.addTokAt(tkIdent, s, sl, sc)

proc scanOperator(l: var Lexer) =
  let sl = l.line
  let sc = l.col
  if l.i + 2 < l.src.len:
    let three = l.src[l.i .. l.i + 2]
    if three in ["..<", "<<=", ">>="]:
      l.addTokAt(tkOperator, three, sl, sc)
      l.bumpN(3)
      return
  if l.i + 1 < l.src.len:
    let two = l.src[l.i .. l.i + 1]
    if two in ["==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "&=",
               "|=", "^=", "<<", ">>", "..", "->"]:
      l.addTokAt(tkOperator, two, sl, sc)
      l.bumpN(2)
      return
  let c = l.src[l.i]
  if c in {'+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~',
           '?', ';', '{', '}'}:
    if c == '{':
      l.addTokAt(tkOperator, "{", sl, sc)
      inc l.depth
      l.bump()
      return
    if c == '}':
      l.addTokAt(tkOperator, "}", sl, sc)
      if l.depth > 0: dec l.depth
      l.bump()
      return
    if c == ';':
      l.failAt("E-LEX-CHAR", "точка с запятой запрещена (README §2.1)")
    l.addTokAt(tkOperator, $c, sl, sc)
    l.bump()
    return
  l.failAt("E-LEX-CHAR", "неизвестный символ: " & $c)

proc scanToken(l: var Lexer) =
  while l.i < l.src.len and l.src[l.i] == ' ':
    l.bump()
  if l.i >= l.src.len:
    return
  let c = l.src[l.i]
  case c
  of '\t':
    l.failAt("E-TAB", "табуляция запрещена; используйте пробелы")
  of '\n', '\r':
    let top = l.depth == 0
    l.bump()
    l.atLineStart = true
    if top and not l.lastNewline:
      l.addTokAt(tkNewline, "", l.line, l.col)
    return
  of '#':
    l.skipComment()
    return
  of '"':
    l.scanString()
  of '\'':
    l.scanChar()
  of '0'..'9':
    l.scanNumber()
  of 'a'..'z', 'A'..'Z', '_':
    l.scanIdent()
  of '(':
    l.addTokAt(tkLParen, "(", l.line, l.col)
    inc l.depth
    l.bump()
  of ')':
    l.addTokAt(tkRParen, ")", l.line, l.col)
    if l.depth > 0: dec l.depth
    l.bump()
  of '[':
    l.addTokAt(tkLBracket, "[", l.line, l.col)
    inc l.depth
    l.bump()
  of ']':
    l.addTokAt(tkRBracket, "]", l.line, l.col)
    if l.depth > 0: dec l.depth
    l.bump()
  of ',':
    l.addTokAt(tkComma, ",", l.line, l.col)
    l.bump()
  of ':':
    l.addTokAt(tkColon, ":", l.line, l.col)
    l.bump()
  of '*':
    l.addTokAt(tkStar, "*", l.line, l.col)
    l.bump()
  of '{':
    if l.i + 1 < l.src.len and l.src[l.i + 1] == '.':
      l.addTokAt(tkPragmaOpen, "{.", l.line, l.col)
      inc l.depth
      l.bumpN(2)
    else:
      l.addTokAt(tkOperator, "{", l.line, l.col)
      inc l.depth
      l.bump()
  of '.':
    if l.i + 1 < l.src.len and l.src[l.i + 1] == '}':
      l.addTokAt(tkPragmaClose, ".}", l.line, l.col)
      if l.depth > 0: dec l.depth
      l.bumpN(2)
    else:
      l.addTokAt(tkDot, ".", l.line, l.col)
      l.bump()
  else:
    l.scanOperator()

proc skipToCode(l: var Lexer) =
  ## Пропускает пустые строки и комментарии, затем выставляет INDENT/DEDENT.
  while l.i < l.src.len:
    var spaces = 0
    while l.i < l.src.len and l.src[l.i] == ' ':
      inc spaces
      l.bump()
    if l.i >= l.src.len:
      return
    if l.src[l.i] == '\t':
      l.failAt("E-TAB", "табуляция в отступе запрещена")
    if l.src[l.i] in {'\n', '\r'}:
      l.bump()
      continue
    if l.src[l.i] == '#':
      l.skipComment()
      if l.i < l.src.len and l.src[l.i] in {'\n', '\r'}:
        l.bump()
      continue
    if spaces > l.indents[^1]:
      l.indents.add spaces
      l.addTokAt(tkIndent, "", l.line, l.col)
    elif spaces < l.indents[^1]:
      while l.indents.len > 1 and spaces < l.indents[^1]:
        l.indents.setLen(l.indents.len - 1)
        l.addTokAt(tkDedent, "", l.line, l.col)
      if spaces != l.indents[^1]:
        l.failAt("E-INDENT", "отступ не совпадает ни с одним внешним блоком")
    l.atLineStart = false
    return

proc lex*(src, path: string): seq[Token] =
  let bad = validateUtf8(src)
  if bad >= 0:
    var line = 1
    var col = 1
    for k in 0 ..< bad:
      if src[k] == '\n':
        inc line
        col = 1
      else:
        inc col
    fail("E-LEX-UTF8", path, line, col,
         "исходник не является валидным UTF-8",
         "файл должен быть в UTF-8; байт " & $bad & " нарушает кодировку")
  var l = Lexer(src: src, path: path, line: 1, col: 1,
                indents: @[0], atLineStart: true)
  while l.i < l.src.len:
    if l.atLineStart and l.depth == 0:
      l.skipToCode()
      if l.atLineStart:
        # EOF или конец файла после комментария
        break
    else:
      l.atLineStart = false
      l.scanToken()
  if not l.lastNewline:
    l.addTokAt(tkNewline, "", l.line, l.col)
  while l.indents.len > 1:
    l.indents.setLen(l.indents.len - 1)
    l.addTokAt(tkDedent, "", l.line, l.col)
  l.addTokAt(tkEof, "", l.line, l.col)
  l.tokens
