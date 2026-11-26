## Представление типов Convulsions (MVP).

type
  TypeKind* = enum
    tyVoid, tyInt, tyBool, tyChar, tyString, tyRune, tyPointer, tyPtr,
    tyObject, tyProc, tyResult, tyError, tyErrorCode, tyUnknown

  Field* = object
    name*: string
    typ*: Type
    exported*: bool

  Type* = ref object
    kind*: TypeKind
    elem*: Type
    params*: seq[Type]
    ret*: Type
    name*: string
    cname*: string
    opaque*: bool
    ownerModule*: string
    fields*: seq[Field]

proc newType*(kind: TypeKind; name = ""): Type =
  Type(kind: kind, name: name)

proc cSanitize*(s: string): string =
  for c in s:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
      result.add c
    else:
      result.add '_'

proc ptrTo*(elem: Type): Type =
  result = newType(tyPtr)
  result.elem = elem

proc isResult*(t: Type): bool =
  t != nil and t.kind == tyResult

proc isVoid*(t: Type): bool =
  t != nil and t.kind == tyVoid

proc sameType*(a, b: Type): bool =
  if a.isNil or b.isNil:
    return false
  if a == b:
    return true
  if a.kind != b.kind:
    return false
  case a.kind
  of tyPtr, tyResult:
    result = sameType(a.elem, b.elem)
  of tyProc:
    if a.params.len != b.params.len:
      return false
    for i in 0 ..< a.params.len:
      if not sameType(a.params[i], b.params[i]):
        return false
    result = sameType(a.ret, b.ret)
  of tyObject:
    result = a.cname == b.cname and a.cname.len > 0
  else:
    result = true

proc typeName*(t: Type): string =
  if t.isNil:
    return "<nil>"
  case t.kind
  of tyVoid: "void"
  of tyInt: "int"
  of tyBool: "bool"
  of tyChar: "char"
  of tyString: "string"
  of tyRune: "Rune"
  of tyPointer: "pointer"
  of tyPtr: "ptr " & typeName(t.elem)
  of tyObject:
    if t.name.len > 0: t.name else: "<object>"
  of tyProc:
    var s = "proc("
    for i, p in t.params:
      if i > 0: s.add ", "
      s.add typeName(p)
    s.add "): " & typeName(t.ret)
    s
  of tyResult: "!" & typeName(t.elem)
  of tyError: "error"
  of tyErrorCode: "ErrorCode"
  of tyUnknown: "<unknown>"
