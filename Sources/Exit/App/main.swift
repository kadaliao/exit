import AppKit

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffered output for the CLI tools
let arguments = Array(CommandLine.arguments.dropFirst())
if let code = DevTools.run(arguments) {
    exit(code)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
