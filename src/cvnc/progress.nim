## Прогресс компилятора: стадии, счётчики, тайминги. Весь вывод — stderr.
import std/[monotimes, strutils, times]
import options

type
  Progress = object
    verbosity: Verbosity
    active: bool
    stageNo: int
    stageTotal: int
    totalStart: MonoTime
    stageStart: MonoTime
    currentTitle: string

var g: Progress

proc elapsedMs(since: MonoTime): float =
  float((getMonoTime() - since).inMilliseconds)

proc fmtTime(ms: float): string =
  formatFloat(ms / 1000.0, ffDecimal, 3) & "s"

proc enabled(): bool =
  g.active and g.verbosity != vQuiet

proc initProgress*(v: Verbosity; totalStages: int) =
  g = Progress(verbosity: v, active: true, stageNo: 0,
               stageTotal: totalStages, totalStart: getMonoTime(),
               stageStart: getMonoTime(), currentTitle: "")

proc quiet*(): bool =
  g.active and g.verbosity == vQuiet

proc header*(text: string) =
  if enabled():
    stderr.writeLine "cvn: " & text

proc stage*(title: string) =
  g.currentTitle = title
  inc g.stageNo
  g.stageStart = getMonoTime()
  if enabled():
    stderr.writeLine "cvn: [" & $g.stageNo & "/" & $g.stageTotal & "] " &
                     title

proc stageDone*(detail = ""; extra: seq[string] = @[]) =
  if not enabled():
    return
  let t = fmtTime(elapsedMs(g.stageStart))
  if detail.len > 0:
    stderr.writeLine "cvn:       " & detail & " (" & t & ")"
  else:
    stderr.writeLine "cvn:       (" & t & ")"
  if g.verbosity == vVerbose:
    for e in extra:
      stderr.writeLine "cvn:   " & e

proc verbose*(msg: string) =
  if g.active and g.verbosity == vVerbose:
    stderr.writeLine "cvn:   " & msg

proc info*(msg: string) =
  if enabled():
    stderr.writeLine "cvn: " & msg

proc success*(msg: string) =
  if enabled():
    stderr.writeLine "cvn: " & msg & " (" &
                     fmtTime(elapsedMs(g.totalStart)) & ")"

proc failStage*() =
  if enabled() and g.currentTitle.len > 0:
    stderr.writeLine "cvn: ошибка на этапе: " & g.currentTitle
