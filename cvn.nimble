version       = "0.3.0"
author        = "Convulsions contributors"
description   = "Convulsions compiler (kernel MVP: hello world via C11)"
license       = "MIT"
srcDir        = "src"
bin           = @["cvn"]
binDir        = "bin"

requires "nim >= 2.0.0"

task test, "build compiler and run unit + e2e tests":
  exec "nim c -d:release --path:src -o:bin/cvn src/cvn.nim"
  exec "nim c -r --path:src tests/tester.nim"

task smoke, "compile and run examples/hello.conv":
  exec "bin/cvn build examples/hello.conv -o build/hello"
  exec "build/hello"
