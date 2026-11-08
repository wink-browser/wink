import AppKit

/// The menu bar. Key equivalents are delivered even while web content has
/// focus (CEF forwards unhandled key events to the main menu). Items without
/// an explicit target travel the responder chain, ending at the app delegate.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Wink", [
            item("About Wink", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            item("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:))),
            item("Welcome to Wink…", #selector(AppDelegate.showWelcome(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            servicesItem(),
            .separator(),
            item("Hide Wink", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("Quit Wink", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ]))
        main.addItem(submenu("File", [
            item("New Tab", #selector(AppDelegate.newTabAction(_:)), "t"),
            item("New Window", #selector(AppDelegate.newWindowAction(_:)), "n"),
            item("New Private Window", #selector(AppDelegate.newPrivateWindowAction(_:)), "n", [.command, .shift]),
            item("Open Location…", #selector(AppDelegate.openLocationAction(_:)), "l"),
            .separator(),
            item("Reopen Closed Tab", #selector(AppDelegate.reopenClosedTabAction(_:)), "t", [.command, .shift]),
            item("Close Tab", #selector(AppDelegate.closeTabAction(_:)), "w"),
            item("Close Window", #selector(AppDelegate.closeWindowAction(_:)), "w", [.command, .shift]),
            .separator(),
            item("Print…", #selector(AppDelegate.printAction(_:)), "p"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift], target: nil),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil),
            .separator(),
            item("Find…", #selector(AppDelegate.findAction(_:)), "f"),
            item("Find Next", #selector(AppDelegate.findNextAction(_:)), "g"),
            item("Find Previous", #selector(AppDelegate.findPreviousAction(_:)), "g", [.command, .shift]),
            .separator(),
            item("Copy Page Address", #selector(AppDelegate.copyURLAction(_:)), "c", [.command, .shift]),
        ]))
        main.addItem(submenu("View", [
            item("Toggle Sidebar", #selector(AppDelegate.toggleSidebarAction(_:)), "s"),
            item("Winky Sidebar", #selector(AppDelegate.toggleAgentPanelAction(_:)), "j", [.command, .option]),
            .separator(),
            item("Reload Page", #selector(AppDelegate.reloadAction(_:)), "r"),
            item("Reload Ignoring Cache", #selector(AppDelegate.hardReloadAction(_:)), "r", [.command, .shift]),
            item("Stop", #selector(AppDelegate.stopAction(_:)), "."),
            .separator(),
            item("Actual Size", #selector(AppDelegate.actualSizeAction(_:)), "0"),
            item("Zoom In", #selector(AppDelegate.zoomInAction(_:)), "="),
            item("Zoom Out", #selector(AppDelegate.zoomOutAction(_:)), "-"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control], target: nil),
            .separator(),
            item("Developer Tools", #selector(AppDelegate.devToolsAction(_:)), "i", [.command, .option]),
        ]))
        main.addItem(submenu("History", [
            item("Back", #selector(AppDelegate.backAction(_:)), "["),
            item("Forward", #selector(AppDelegate.forwardAction(_:)), "]"),
            .separator(),
            item("Search History…", #selector(AppDelegate.newTabAction(_:)), "y"),
            item("Clear Browsing Data…", #selector(AppDelegate.clearBrowsingDataAction(_:)), "\u{8}", [.command, .shift]),
        ]))
        main.addItem(submenu("Agents", [
            item("Ask Winky", #selector(AppDelegate.toggleWinkyBarAction(_:)), "j"),
            item("Share This Tab with Agents", #selector(AppDelegate.shareTabWithAgentsAction(_:)), "e", [.command, .shift]),
            item("Stop All Agents", #selector(AppDelegate.stopAgentsAction(_:)), ".", [.command, .shift]),
            .separator(),
            item("Connect Claude Code…", #selector(AppDelegate.connectClaudeCodeAction(_:))),
            item("Agent Settings…", #selector(AppDelegate.showSettings(_:))),
        ]))
        var windowItems: [NSMenuItem] = [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
            .separator(),
            item("Select Next Tab", #selector(AppDelegate.nextTabAction(_:)), "]", [.command, .shift]),
            item("Select Previous Tab", #selector(AppDelegate.previousTabAction(_:)), "[", [.command, .shift]),
            item("Next Tab", #selector(AppDelegate.nextTabAction(_:)), "\t", [.control]),
            item("Previous Tab", #selector(AppDelegate.previousTabAction(_:)), "\t", [.control, .shift]),
            item("Pin Tab", #selector(AppDelegate.pinTabAction(_:)), "d", [.command, .shift]),
            .separator(),
        ]
        for index in 0..<9 {
            let menuItem = item(index == 8 ? "Last Tab" : "Tab \(index + 1)", #selector(AppDelegate.selectTabAction(_:)),
                                "\(index + 1)")
            menuItem.tag = index
            windowItems.append(menuItem)
        }
        windowItems.append(.separator())
        windowItems.append(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        let windowMenu = submenu("Window", windowItems)
        NSApp.windowsMenu = windowMenu.submenu
        main.addItem(windowMenu)
        let help = submenu("Help", [])
        NSApp.helpMenu = help.submenu
        main.addItem(help)
        return main
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        return item
    }

    private static func servicesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Services")
        item.submenu = menu
        NSApp.servicesMenu = menu
        return item
    }
}
