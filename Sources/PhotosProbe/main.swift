import Foundation
import Darwin

// Only inspect the user's current Photos selection. This probe never writes metadata.
let script = #"""
tell application "Photos"
    set picked to selection
    set n to count of picked
    if n is 0 then return "selection=0"
    set p to item 1 of picked
    set ident to id of p as text
    set d to description of p
    set k to keywords of p
    if d is missing value then set d to ""
    if k is missing value then set k to {}
    return "selection=" & n & linefeed & "native_id=" & ident & linefeed & "description_present=" & ((d is not "") as text) & linefeed & "keyword_count=" & (count of k)
end tell
"""#

let process = Process()
let out = Pipe()
let err = Pipe()
process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
process.arguments = ["-e", script]
process.standardOutput = out
process.standardError = err

do {
    try process.run()
    let limit = Date().addingTimeInterval(15)
    while process.isRunning && Date() < limit {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        let grace = Date().addingTimeInterval(1)
        while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        fputs("Photos 读取超时；已结束本次脚本，未重启 Photos。\n", stderr)
        exit(2)
    }
    process.waitUntilExit()
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    if process.terminationStatus != 0 {
        FileHandle.standardError.write(errors)
        exit(process.terminationStatus)
    }
    FileHandle.standardOutput.write(output)
} catch {
    fputs("无法运行 Photos 读取验证：\(error.localizedDescription)\n", stderr)
    exit(1)
}
