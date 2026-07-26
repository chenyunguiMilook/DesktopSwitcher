import AppKit

// LSUIElement in Info.plist keeps this out of the Dock and the app switcher; setting
// the policy here too means `swift run` behaves the same as the bundled app.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
