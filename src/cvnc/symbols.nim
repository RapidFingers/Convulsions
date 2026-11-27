## Символы, области видимости, модули.

import std/tables
import ast, types

type
  SymKind* = enum
    skProc, skVar, skLet, skParam, skType, skModule, skBuiltin

  Symbol* = ref object
    id*: int
    kind*: SymKind
    name*: string
    cname*: string
    typ*: Type
    node*: AstNode
    exported*: bool
    external*: bool
    byRef*: bool
    modulePath*: string
    paramNames*: seq[string]
    paramVars*: seq[bool]
    paramSyms*: seq[Symbol]
    builtin*: string
    propagate*: bool
    isGeneric*: bool
    genericParams*: seq[string]
    typeArgs*: seq[Type]
    templateId*: int
    monoDepth*: int
    typeEnv*: Table[string, Type]

  Scope* = ref object
    parent*: Scope
    syms*: Table[string, Symbol]

  ModuleInfo* = ref object
    path*: string
    file*: string
    profile*: string
    headers*: seq[string]
    ast*: AstNode
    scope*: Scope
    exports*: Table[string, Symbol]
    importNodes*: seq[AstNode]
    imported*: Table[string, ModuleInfo]
    isEntry*: bool

proc newScope*(parent: Scope = nil): Scope =
  Scope(parent: parent, syms: initTable[string, Symbol]())

proc define*(s: Scope; sym: Symbol) =
  s.syms[sym.name] = sym

proc lookup*(s: Scope; name: string): Symbol =
  var cur = s
  while cur != nil:
    if cur.syms.hasKey(name):
      return cur.syms[name]
    cur = cur.parent
  nil

proc hasOwn*(s: Scope; name: string): bool =
  s.syms.hasKey(name)

proc addExport*(m: ModuleInfo; sym: Symbol) =
  m.exports[sym.name] = sym
