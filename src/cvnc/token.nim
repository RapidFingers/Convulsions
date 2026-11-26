## Лексемы и полный список ключевых слов (README §2.2).

type
  Keyword* = enum
    kwNone,
    kwAddr, kwAnd, kwAs, kwAsm, kwAwait, kwBlock, kwBreak, kwCase, kwCast,
    kwCatch, kwClass, kwConcept, kwConst, kwContinue, kwDefer, kwDiscard,
    kwDistinct, kwDo, kwElif, kwElse, kwEnum, kwErrdefer, kwExport, kwFalse,
    kwFor, kwFrom, kwFunc, kwIf, kwImport, kwIn, kwInclude, kwInterface, kwIs,
    kwIsnot, kwIterator, kwLet, kwNil, kwNot, kwNotin, kwObject, kwOf, kwOr,
    kwProc, kwPtr, kwRef, kwReturn, kwShared, kwSpawn, kwStatic, kwTemplate,
    kwThrow, kwTrue, kwTry, kwTuple, kwType, kwUnion, kwVar, kwVoid, kwWeak,
    kwWhen, kwWhile, kwXor, kwYield

  TokenKind* = enum
    tkEof, tkNewline, tkIndent, tkDedent, tkIdent, tkKeyword, tkIntLit,
    tkStringLit, tkCharLit, tkOperator, tkLParen, tkRParen, tkLBracket,
    tkRBracket, tkComma, tkColon, tkDot, tkStar, tkPragmaOpen, tkPragmaClose

  Token* = object
    kind*: TokenKind
    text*: string
    kw*: Keyword
    line*: int
    col*: int

const keywordPairs* = [
  ("addr", kwAddr), ("and", kwAnd), ("as", kwAs), ("asm", kwAsm),
  ("await", kwAwait), ("block", kwBlock), ("break", kwBreak), ("case", kwCase),
  ("cast", kwCast), ("catch", kwCatch), ("class", kwClass),
  ("concept", kwConcept), ("const", kwConst), ("continue", kwContinue),
  ("defer", kwDefer), ("discard", kwDiscard), ("distinct", kwDistinct),
  ("do", kwDo), ("elif", kwElif), ("else", kwElse), ("enum", kwEnum),
  ("errdefer", kwErrdefer), ("export", kwExport), ("false", kwFalse),
  ("for", kwFor), ("from", kwFrom), ("func", kwFunc), ("if", kwIf),
  ("import", kwImport), ("in", kwIn), ("include", kwInclude),
  ("interface", kwInterface), ("is", kwIs), ("isnot", kwIsnot),
  ("iterator", kwIterator), ("let", kwLet), ("nil", kwNil), ("not", kwNot),
  ("notin", kwNotin), ("object", kwObject), ("of", kwOf), ("or", kwOr),
  ("proc", kwProc), ("ptr", kwPtr), ("ref", kwRef), ("return", kwReturn),
  ("shared", kwShared), ("spawn", kwSpawn), ("static", kwStatic),
  ("template", kwTemplate), ("throw", kwThrow), ("true", kwTrue),
  ("try", kwTry), ("tuple", kwTuple), ("type", kwType), ("union", kwUnion),
  ("var", kwVar), ("void", kwVoid), ("weak", kwWeak), ("when", kwWhen),
  ("while", kwWhile), ("xor", kwXor), ("yield", kwYield)
]

proc keywordOf*(s: string): Keyword =
  for (name, kw) in keywordPairs:
    if name == s:
      return kw
  kwNone
