import Cocoa
import Foundation
import CoreLocation

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

        for displayID in allDisplays() {
            CGSetDisplayTransferByTable(displayID, UInt32(n), rT, gT, bT)
        }
    }

    private func allDisplays() -> [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return [CGMainDisplayID()] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
    }
}

// MARK: - Location Manager

class LocationManager: NSObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    private(set) var timezone: TimeZone = .current
    private(set) var cityName: String?
    var onUpdate: (() -> Void)?

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func start() {
        if CLLocationManager.locationServicesEnabled() {
            clManager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        manager.stopUpdatingLocation()

        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self = self, let pm = placemarks?.first else { return }
            if let tz = pm.timeZone { self.timezone = tz }
            self.cityName = [pm.locality, pm.country]
                .compactMap { $0 }
                .joined(separator: ", ")
            DispatchQueue.main.async { self.onUpdate?() }
        }

        // Switch to monitoring significant location changes (travel detection)
        manager.startMonitoringSignificantLocationChanges()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        timezone = .current
        DispatchQueue.main.async { self.onUpdate?() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            timezone = .current
            DispatchQueue.main.async { self.onUpdate?() }
        default:
            break
        }
    }

    var displayString: String {
        if let city = cityName {
            let abbr = timezone.abbreviation() ?? timezone.identifier
            return "\(city) (\(abbr))"
        }
        return timezone.identifier
    }
}

// MARK: - Schedule

enum SchedulePhase: String {
    case daylight = "Daylight (6500K)"
    case evening = "Evening (2700K)"
    case night = "Night (1900K)"

    var temperature: CGFloat {
        switch self {
        case .daylight: return 6500
        case .evening: return 2700
        case .night: return 1900
        }
    }
}

class ScheduleManager {
    var bedHour: Int = 23
    var bedMinute: Int = 0
    var wakeHour: Int = 7
    var wakeMinute: Int = 0
    var enabled: Bool = false

    var locationManager: LocationManager?
    var onPhaseChange: ((SchedulePhase) -> Void)?
    private var timer: Timer?

    init() { load() }

    func save() {
        let d = UserDefaults.standard
        d.set(bedHour, forKey: "sh_bedH")
        d.set(bedMinute, forKey: "sh_bedM")
        d.set(wakeHour, forKey: "sh_wakeH")
        d.set(wakeMinute, forKey: "sh_wakeM")
        d.set(enabled, forKey: "sh_on")
    }

    private func load() {
        let d = UserDefaults.standard
        guard d.object(forKey: "sh_bedH") != nil else { return }
        bedHour = d.integer(forKey: "sh_bedH")
        bedMinute = d.integer(forKey: "sh_bedM")
        wakeHour = d.integer(forKey: "sh_wakeH")
        wakeMinute = d.integer(forKey: "sh_wakeM")
        enabled = d.bool(forKey: "sh_on")
    }

    func restart() {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let phase = computePhase()
        onPhaseChange?(phase)
    }

    func computePhase() -> SchedulePhase {
        let tz = locationManager?.timezone ?? .current
        var cal = Calendar.current
        cal.timeZone = tz
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let wake = wakeHour * 60 + wakeMinute
        let bed = bedHour * 60 + bedMinute

        // Minutes elapsed since wake (handles midnight wrapping)
        let sinceWake: Int
        if nowMin >= wake {
            sinceWake = nowMin - wake
        } else {
            sinceWake = (1440 - wake) + nowMin
        }

        // Total awake duration
        let awakeDur: Int
        if bed > wake {
            awakeDur = bed - wake
        } else if bed < wake {
            awakeDur = (1440 - wake) + bed
        } else {
            awakeDur = 1440 // same time = full day
        }

        let eveningAt = max(0, awakeDur - 120) // 2h before bed
        let nightAt = max(0, awakeDur - 60)    // 1h before bed

        if sinceWake < eveningAt {
            return .daylight
        } else if sinceWake < nightAt {
            return .evening
        } else {
            return .night
        }
    }

    var bedtimeString: String {
        String(format: "%02d:%02d", bedHour, bedMinute)
    }

    var wakeString: String {
        String(format: "%02d:%02d", wakeHour, wakeMinute)
    }

    var scheduleDescription: String {
        let wake = wakeHour * 60 + wakeMinute
        let bed = bedHour * 60 + bedMinute
        let awakeDur: Int
        if bed > wake {
            awakeDur = bed - wake
        } else if bed < wake {
            awakeDur = (1440 - wake) + bed
        } else {
            awakeDur = 1440
        }
        let eveningMin = (wake + max(0, awakeDur - 120)) % 1440
        let nightMin = (wake + max(0, awakeDur - 60)) % 1440

        func fmt(_ m: Int) -> String {
            String(format: "%02d:%02d", m / 60, m % 60)
        }

        return """
        \(fmt(wake)) \u{2013} \(fmt(eveningMin))  Daylight (6500K)
        \(fmt(eveningMin)) \u{2013} \(fmt(nightMin))  Evening (2700K)
        \(fmt(nightMin)) \u{2013} \(fmt(wake))  Night (1900K)
        """
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
        label = NSTextField(labelWithString: "6500K \u{2014} Daylight")
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
        label.stringValue = "\(rounded)K \u{2014} \(desc)"
    }

    func set(_ k: CGFloat) {
        slider.doubleValue = Double(k)
        updateLabel(k)
    }
}

// MARK: - Schedule Settings Window

class ScheduleSettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let schedule: ScheduleManager
    private let location: LocationManager

    private var locationLabel: NSTextField?
    private var bedPicker: NSDatePicker?
    private var wakePicker: NSDatePicker?
    private var scheduleLabel: NSTextField?
    private var enableCheck: NSButton?

    var onDismiss: (() -> Void)?

    init(schedule: ScheduleManager, location: LocationManager) {
        self.schedule = schedule
        self.location = location
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            refresh()
            return
        }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Schedule Settings"
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        window = w

        let v = NSView(frame: w.contentView!.bounds)
        v.autoresizingMask = [.width, .height]
        w.contentView = v

        var y: CGFloat = 292

        // --- Location ---
        v.addSubview(makeLabel("Location", bold: true, frame: NSRect(x: 20, y: y, width: 280, height: 18)))
        y -= 22

        let locVal = makeLabel(location.displayString, bold: false, frame: NSRect(x: 20, y: y, width: 280, height: 18))
        locVal.textColor = .secondaryLabelColor
        v.addSubview(locVal)
        locationLabel = locVal
        y -= 36

        // --- Bedtime ---
        v.addSubview(makeLabel("Bedtime", bold: true, frame: NSRect(x: 20, y: y, width: 280, height: 18)))
        y -= 30

        let bp = makeTimePicker(hour: schedule.bedHour, minute: schedule.bedMinute)
        bp.frame = NSRect(x: 20, y: y, width: 120, height: 26)
        v.addSubview(bp)
        bedPicker = bp
        y -= 36

        // --- Wake time ---
        v.addSubview(makeLabel("Wake Time", bold: true, frame: NSRect(x: 20, y: y, width: 280, height: 18)))
        y -= 30

        let wp = makeTimePicker(hour: schedule.wakeHour, minute: schedule.wakeMinute)
        wp.frame = NSRect(x: 20, y: y, width: 120, height: 26)
        v.addSubview(wp)
        wakePicker = wp
        y -= 36

        // --- Schedule preview ---
        v.addSubview(makeLabel("Schedule Preview", bold: true, frame: NSRect(x: 20, y: y, width: 280, height: 18)))
        y -= 58

        let sl = makeLabel(schedule.scheduleDescription, bold: false, frame: NSRect(x: 20, y: y, width: 280, height: 52))
        sl.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sl.maximumNumberOfLines = 3
        v.addSubview(sl)
        scheduleLabel = sl
        y -= 32

        // --- Enable toggle ---
        let check = NSButton(checkboxWithTitle: "Enable Auto Schedule", target: self, action: #selector(toggleEnable(_:)))
        check.state = schedule.enabled ? .on : .off
        check.frame = NSRect(x: 20, y: y, width: 220, height: 20)
        v.addSubview(check)
        enableCheck = check

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func refresh() {
        locationLabel?.stringValue = location.displayString
        enableCheck?.state = schedule.enabled ? .on : .off
        scheduleLabel?.stringValue = schedule.scheduleDescription
    }

    private func makeLabel(_ text: String, bold: Bool, frame: NSRect) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = bold ? NSFont.systemFont(ofSize: 12, weight: .semibold)
                      : NSFont.systemFont(ofSize: 12)
        l.lineBreakMode = .byWordWrapping
        l.maximumNumberOfLines = 0
        l.frame = frame
        return l
    }

    private func makeTimePicker(hour: Int, minute: Int) -> NSDatePicker {
        let dp = NSDatePicker()
        dp.datePickerStyle = .textFieldAndStepper
        dp.datePickerElements = [.hourMinute]
        dp.timeZone = location.timezone
        dp.calendar = {
            var cal = Calendar.current
            cal.timeZone = location.timezone
            return cal
        }()
        dp.dateValue = dateFrom(hour: hour, minute: minute)
        dp.target = self
        dp.action = #selector(timeChanged)
        return dp
    }

    private func dateFrom(hour: Int, minute: Int) -> Date {
        var cal = Calendar.current
        cal.timeZone = location.timezone
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        return cal.date(from: comps) ?? Date()
    }

    @objc private func timeChanged() {
        guard let bp = bedPicker, let wp = wakePicker else { return }
        var cal = Calendar.current
        cal.timeZone = location.timezone
        schedule.bedHour = cal.component(.hour, from: bp.dateValue)
        schedule.bedMinute = cal.component(.minute, from: bp.dateValue)
        schedule.wakeHour = cal.component(.hour, from: wp.dateValue)
        schedule.wakeMinute = cal.component(.minute, from: wp.dateValue)
        schedule.save()
        scheduleLabel?.stringValue = schedule.scheduleDescription
        if schedule.enabled { schedule.restart() }
    }

    @objc private func toggleEnable(_ sender: NSButton) {
        schedule.enabled = sender.state == .on
        schedule.save()
        schedule.restart()
        onDismiss?()
    }

    func updateLocation() {
        locationLabel?.stringValue = location.displayString
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss?()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let gamma = GammaController()
    let location = LocationManager()
    let schedule = ScheduleManager()
    var statusItem: NSStatusItem?
    var sliderView: SliderView?
    var settingsController: ScheduleSettingsController?
    var scheduleStatusItem: NSMenuItem?
    var scheduleToggleItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire location into schedule
        schedule.locationManager = location

        location.onUpdate = { [weak self] in
            self?.settingsController?.updateLocation()
        }

        schedule.onPhaseChange = { [weak self] phase in
            guard let self = self else { return }
            self.applyTemp(phase.temperature)
            self.updateScheduleMenu()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "\u{1F505}"

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
            ("Daylight (6,500K) \u{2014} Off", "0", 6500),
        ] as [(String, String, Int)] {
            let item = NSMenuItem(title: name, action: #selector(presetTapped(_:)), keyEquivalent: key)
            item.target = self
            item.tag = kelvin
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // Schedule section
        let schedLabel = NSMenuItem(title: "Schedule", action: nil, keyEquivalent: "")
        schedLabel.isEnabled = false
        menu.addItem(schedLabel)

        let statusMenuItem = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        scheduleStatusItem = statusMenuItem
        menu.addItem(statusMenuItem)

        let toggleItem = NSMenuItem(title: "Enable Auto Schedule", action: #selector(toggleSchedule), keyEquivalent: "s")
        toggleItem.target = self
        scheduleToggleItem = toggleItem
        menu.addItem(toggleItem)

        let settingsItem = NSMenuItem(title: "Schedule Settings\u{2026}", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu

        // Start location detection
        location.start()

        // Start schedule if previously enabled
        if schedule.enabled {
            schedule.restart()
        }
        updateScheduleMenu()

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

    @objc func toggleSchedule() {
        schedule.enabled.toggle()
        schedule.save()
        schedule.restart()
        updateScheduleMenu()
    }

    @objc func openSettings() {
        if settingsController == nil {
            settingsController = ScheduleSettingsController(schedule: schedule, location: location)
            settingsController?.onDismiss = { [weak self] in
                self?.updateScheduleMenu()
            }
        }
        settingsController?.show()
    }

    func updateScheduleMenu() {
        if schedule.enabled {
            let phase = schedule.computePhase()
            scheduleStatusItem?.title = "\u{25CF} \(phase.rawValue)"
            scheduleToggleItem?.title = "Disable Auto Schedule"
        } else {
            scheduleStatusItem?.title = "Off"
            scheduleToggleItem?.title = "Enable Auto Schedule"
        }
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
