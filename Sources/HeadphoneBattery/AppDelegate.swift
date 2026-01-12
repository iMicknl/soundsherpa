import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private let bluetoothManager = BluetoothManager.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupPopover()
        bluetoothManager.startMonitoring()
        
        // Observe battery changes to update status bar icon
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("BatteryLevelChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateStatusBarIcon()
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        bluetoothManager.stopMonitoring()
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        
        if let button = statusItem?.button {
            let image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Headphones")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "Headphone Battery Monitor"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 320, height: 400)
        popover?.behavior = .transient
        popover?.animates = true
        
        let popoverView = PopoverView(bluetoothManager: bluetoothManager) { [weak self] in
            self?.quitApp()
        }
        popover?.contentViewController = NSHostingController(rootView: popoverView)
        
        // Monitor for clicks outside the popover to close it
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover?.isShown == true {
                self?.closePopover()
            }
        }
    }
    
    @objc private func togglePopover() {
        if let popover = popover {
            if popover.isShown {
                closePopover()
            } else {
                showPopover()
            }
        }
    }
    
    private func showPopover() {
        if let button = statusItem?.button {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            
            // Refresh data when showing
            bluetoothManager.refresh()
        }
    }
    
    private func closePopover() {
        popover?.performClose(nil)
    }
    
    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        
        if let battery = bluetoothManager.currentDevice?.batteryLevel {
            if battery < 20 {
                button.contentTintColor = .systemRed
            } else if battery < 50 {
                button.contentTintColor = .systemOrange
            } else {
                button.contentTintColor = nil
            }
            
            let batteryInfo = "\(battery)%"
            let deviceName = bluetoothManager.currentDevice?.name ?? "Bose Device"
            button.toolTip = "\(deviceName)\nBattery: \(batteryInfo)"
        } else {
            button.contentTintColor = nil
            button.toolTip = "Headphone Battery Monitor"
        }
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
