import AppKit

if Debug.run(CommandLine.arguments) { exit(0) }
if CommandLine.arguments.contains("--demo") {
    AppController.demo = true
    IconRulesStore.shared = IconRulesStore(persistent: false)
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
