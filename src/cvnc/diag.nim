## Диагностика компилятора: единый тип ошибки и рендер.

type
  CvnError* = object of CatchableError
    code*: string
    file*: string
    line*: int
    col*: int
    hint*: string

proc newDiag*(code, file: string; line, col: int; msg: string;
              hint = ""): ref CvnError =
  new(result)
  result.code = code
  result.file = file
  result.line = line
  result.col = col
  result.msg = msg
  result.hint = hint

proc fail*(code, file: string; line, col: int; msg: string;
           hint = "") {.noreturn.} =
  raise newDiag(code, file, line, col, msg, hint)

proc render*(e: ref CvnError): string =
  result = ""
  if e.file.len > 0:
    result.add e.file
    result.add ":"
    result.add $e.line
    result.add ":"
    result.add $e.col
    result.add ": "
  result.add "error[" & e.code & "]: " & e.msg
  if e.hint.len > 0:
    result.add "\n  help: " & e.hint
