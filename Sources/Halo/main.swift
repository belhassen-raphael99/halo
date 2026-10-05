import AppKit

if Debug.run(CommandLine.arguments) { exit(0) }

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
