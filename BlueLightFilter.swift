import Cocoa
import Foundation

// MARK: - Color Temperature to RGB (Tanner Helland algorithm)

func kelvinToRGB(_ kelvin: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    let temp = kelvin / 100.0
    var red: CGFloat, green: CGFloat, blue: CGFloat

    if temp <= 66.0 {
        red = 255.0
    } else {
        red = 329.698727446 * pow(temp - 60.0, -0.1332047592)
    }

    if temp <= 66.0 {
        green = 99.4708025861 * log(temp) - 161.1195681661
    } else {
        green = 288.1221695283 * pow(temp - 60.0, -0.0755148492)
    }

    if temp >= 66.0 {
        blue = 255.0
    } else if temp <= 19.0 {
        blue = 0.0
    } else {
        blue = 138.5177312231 * log(temp - 10.0) - 305.0447927307
    }

    return (
        min(1.0, max(0.0, red / 255.0)),
        min(1.0, max(0.0, green / 255.0)),
        min(1.0, max(0.0, blue / 255.0))
    )
}

// MARK: - Gamma Controller

class GammaController {
    private let refRGB = kelvinToRGB(6500)

    func apply(_ kelvin: CGFloat) {
        let rgb = kelvinToRGB(kelvin)
        let rMul = rgb.r / refRGB.r
        let gMul = rgb.g / refRGB.g
        let bMul = rgb.b / refRGB.b

        let n = 256
        var rT = [CGGammaValue](repeating: 0, count: n)
        var gT = [CGGammaValue](repeating: 0, count: n)
        var bT = [CGGammaValue](repeating: 0, count: n)

        for i in 0..<n {
            let v = CGFloat(i) / 255.0
            rT[i] = CGGammaValue(min(1.0, v * rMul))
            gT[i] = CGGammaValue(min(1.0, v * gMul))
            bT[i] = CGGammaValue(min(1.0, v * bMul))
        }

        CGSetDisplayTransferByTable(CGMainDisplayID(), UInt32(n), rT, gT, bT)
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - Slider View for Menu

class SliderView: NSView {
    let slider: NSSlider
    let label: NSTextField
    let warmLabel: NSTextField
    let coolLabel: NSTextField
    var onChange: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        slider = NSSlider(value: 6500, minValue: 1900, maxValue: 6500, target: nil, action: nil)
        label = NSTextField(labelWithString: "6500K — Daylight")
        warmLabel = NSTextField(labelWithString: "Warm")
        coolLabel = NSTextField(labelWithString: "Cool")
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 58))

        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.alignment = .center

        warmLabel.font = NSFont.systemFont(ofSize: 9)
        warmLabel.textColor = .secondaryLabelColor
        coolLabel.font = NSFont.systemFont(ofSize: 9)
        coolLabel.textColor = .secondaryLabelColor
        coolLabel.alignment = .right

        addSubview(label)
        addSubview(slider)
        addSubview(warmLabel)
        addSubview(coolLabel)

        label.frame = NSRect(x: 20, y: 38, width: 220, height: 16)
        slider.frame = NSRect(x: 20, y: 16, width: 220, height: 20)
        warmLabel.frame = NSRect(x: 20, y: 1, width: 40, height: 14)
        coolLabel.frame = NSRect(x: 200, y: 1, width: 40, height: 14)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc func moved() {
        let k = CGFloat(slider.doubleValue)
        updateLabel(k)
        onChange?(k)
    }

    func updateLabel(_ k: CGFloat) {
        let rounded = Int(round(k / 100) * 100)
        let desc: String
        switch rounded {
        case ...2000: desc = "Candlelight"
        case ...3000: desc = "Incandescent"
        case ...4000: desc = "Halogen"
        case ...5500: desc = "Warm White"
        default: desc = "Daylight"
        }
        label.stringValue = "\(rounded)K — \(desc)"
    }

    func set(_ k: CGFloat) {
        slider.doubleValue = Double(k)
        updateLabel(k)
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let gamma = GammaController()
    var statusItem: NSStatusItem?
    var sliderView: SliderView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "🔅"

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "Blue Light Filter", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        // Slider
        let sliderItem = NSMenuItem()
        let sv = SliderView()
        sv.onChange = { [weak self] k in self?.applyTemp(k) }
        sliderItem.view = sv
        sliderView = sv
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        // Presets
        let presetLabel = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetLabel.isEnabled = false
        menu.addItem(presetLabel)

        for (name, key, kelvin) in [
            ("Candlelight (1,900K)", "1", 1900),
            ("Incandescent (2,700K)", "2", 2700),
            ("Halogen (3,400K)", "3", 3400),
            ("Daylight (6,500K) — Off", "0", 6500),
        ] as [(String, String, Int)] {
            let item = NSMenuItem(title: name, action: #selector(presetTapped(_:)), keyEquivalent: key)
            item.target = self
            item.tag = kelvin
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        print("Blue Light Filter running. Use the menu bar icon to adjust.")
        print("Slide from 6500K (daylight) down to 1900K (candlelight).")
        print("Press Ctrl+C to quit and restore display.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        gamma.restore()
    }

    func applyTemp(_ k: CGFloat) {
        sliderView?.set(k)
        if k >= 6450 {
            gamma.restore()
        } else {
            gamma.apply(k)
        }
    }

    @objc func presetTapped(_ sender: NSMenuItem) {
        applyTemp(CGFloat(sender.tag))
    }

    @objc func doQuit() {
        gamma.restore()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Signal Handlers

func setupSignalHandlers() {
    signal(SIGINT) { _ in
        CGDisplayRestoreColorSyncSettings()
        exit(0)
    }
    signal(SIGTERM) { _ in
        CGDisplayRestoreColorSyncSettings()
        exit(0)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
setupSignalHandlers()
app.setActivationPolicy(.accessory)
app.run()
