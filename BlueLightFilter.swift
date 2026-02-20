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
    case evening = "Evening (3400K)"
    case night = "Night (2700K)"

    var temperature: CGFloat {
        switch self {
        case .daylight: return 6500
        case .evening: return 3400
        case .night: return 2700
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

        let eveningAt = max(0, awakeDur - 180) // 3h before bed
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
        let eveningMin = (wake + max(0, awakeDur - 180)) % 1440
        let nightMin = (wake + max(0, awakeDur - 60)) % 1440

        func fmt(_ m: Int) -> String {
            String(format: "%02d:%02d", m / 60, m % 60)
        }

        return """
        \(fmt(wake)) \u{2013} \(fmt(eveningMin))  Daylight (6500K)
        \(fmt(eveningMin)) \u{2013} \(fmt(nightMin))  Evening (3400K)
        \(fmt(nightMin)) \u{2013} \(fmt(wake))  Night (2700K)
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
        warmLabel.textColor = .tertiaryLabelColor
        coolLabel.font = NSFont.systemFont(ofSize: 9)
        coolLabel.textColor = .tertiaryLabelColor
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

// MARK: - Schedule Graph View

class ScheduleGraphView: NSView {
    var schedule: ScheduleManager?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        guard let sched = schedule else { return }

        let ml: CGFloat = 46, mr: CGFloat = 12, mt: CGFloat = 18, mb: CGFloat = 28
        let gx = ml, gy = mb
        let gw = bounds.width - ml - mr
        let gh = bounds.height - mt - mb

        let wake = sched.wakeHour * 60 + sched.wakeMinute
        let bed  = sched.bedHour * 60 + sched.bedMinute
        let dur: Int = bed > wake ? bed - wake : (bed < wake ? 1440 - wake + bed : 1440)
        let evMin = (wake + max(0, dur - 180)) % 1440
        let niMin = (wake + max(0, dur - 60)) % 1440

        func xFor(_ m: Int) -> CGFloat { gx + CGFloat(m) / 1440.0 * gw }
        func yFor(_ k: CGFloat) -> CGFloat { gy + (k - 1500) / 5500.0 * gh }

        func smoothstep(_ t: Double) -> CGFloat {
            let c = min(1, max(0, t))
            return CGFloat(c * c * (3 - 2 * c))
        }

        let trans: Double = 20
        let eveningAt = Double(max(0, dur - 180))
        let nightAt   = Double(max(0, dur - 60))

        func temp(_ m: Int) -> CGFloat {
            let s = Double(m >= wake ? m - wake : 1440 - wake + m)
            if s < trans {
                let t = s / trans
                return 2700 + smoothstep(t) * (6500 - 2700)
            }
            if s < eveningAt - trans { return 6500 }
            if s < eveningAt + trans {
                let t = (s - (eveningAt - trans)) / (2 * trans)
                return 6500 - smoothstep(t) * (6500 - 3400)
            }
            if s < nightAt - trans { return 3400 }
            if s < nightAt + trans {
                let t = (s - (nightAt - trans)) / (2 * trans)
                return 3400 - smoothstep(t) * (3400 - 2700)
            }
            return 2700
        }

        func sleeping(_ m: Int) -> Bool {
            if bed < wake { return m >= bed && m < wake }
            return m >= bed || m < wake
        }

        // --- Background: rounded rect with system quaternary fill ---
        let bgPath = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(bgPath)
        ctx.setFillColor(NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor)
        ctx.fillPath()

        // Subtle border
        ctx.addPath(bgPath)
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        ctx.strokePath()

        // --- Clip to graph area ---
        ctx.saveGState()
        let graphRect = CGRect(x: gx, y: gy, width: gw, height: gh)
        let graphClip = CGPath(roundedRect: graphRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(graphClip)
        ctx.clip()

        // --- Subtle phase zone backgrounds ---
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        for px in 0..<Int(gw) {
            let minute = Int(Double(px) / Double(gw) * 1440.0) % 1440
            let x = gx + CGFloat(px)
            let isSleep = sleeping(minute)

            if isSleep {
                // Sleep zone: slightly darker
                let alpha: CGFloat = isDark ? 0.06 : 0.04
                ctx.setFillColor(NSColor.labelColor.withAlphaComponent(alpha).cgColor)
                ctx.fill(CGRect(x: x, y: gy, width: 1, height: gh))
            }
        }

        // --- Fill under curve with subtle warm gradient ---
        for px in stride(from: 0, to: Int(gw), by: 2) {
            let minute = Int(Double(px) / Double(gw) * 1440.0) % 1440
            let x = gx + CGFloat(px)
            let t = temp(minute)
            let fillH = yFor(t) - gy

            // Warm fill color based on temperature
            let warmth = (t - 1500) / 5000.0  // 0 = warm, 1 = cool
            let fillColor: NSColor
            if warmth > 0.8 {
                fillColor = NSColor.systemBlue
            } else if warmth > 0.3 {
                fillColor = NSColor.systemOrange
            } else {
                fillColor = NSColor(red: 0.95, green: 0.5, blue: 0.2, alpha: 1)
            }

            let steps = max(1, Int(fillH))
            for sy in stride(from: 0, to: steps, by: 3) {
                let frac = CGFloat(sy) / CGFloat(steps)
                let alpha: CGFloat = 0.02 + 0.08 * frac * frac
                ctx.setFillColor(fillColor.withAlphaComponent(alpha).cgColor)
                ctx.fill(CGRect(x: x, y: gy + CGFloat(sy), width: 2, height: 3))
            }
        }

        // --- Grid lines using system separator color ---
        ctx.setLineWidth(0.5)
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.2)
        for k: CGFloat in [2700, 3400, 6500] {
            let yy = yFor(k)
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.move(to: CGPoint(x: gx, y: yy))
            ctx.addLine(to: CGPoint(x: gx + gw, y: yy))
            ctx.strokePath()
        }
        for h in stride(from: 0, through: 24, by: 3) {
            let xx = xFor(h * 60)
            ctx.setStrokeColor(gridColor.cgColor)
            ctx.move(to: CGPoint(x: xx, y: gy))
            ctx.addLine(to: CGPoint(x: xx, y: gy + gh))
            ctx.strokePath()
        }

        // --- Phase transition markers ---
        let dashColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.4)
        for edge in [wake, evMin, niMin, bed] {
            let xx = xFor(edge)
            ctx.setStrokeColor(dashColor.cgColor)
            ctx.setLineWidth(0.5)
            ctx.setLineDash(phase: 0, lengths: [3, 4])
            ctx.move(to: CGPoint(x: xx, y: gy))
            ctx.addLine(to: CGPoint(x: xx, y: gy + gh))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        // --- Temperature curve line ---
        let linePath = CGMutablePath()
        linePath.move(to: CGPoint(x: xFor(0), y: yFor(temp(0))))
        for m in 1...1440 {
            linePath.addLine(to: CGPoint(x: xFor(m), y: yFor(temp(m % 1440))))
        }

        // Soft shadow behind line
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4,
                       color: NSColor.systemOrange.withAlphaComponent(0.3).cgColor)
        ctx.addPath(linePath)
        ctx.setStrokeColor(NSColor.systemOrange.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()
        ctx.restoreGState()

        // Core line
        ctx.addPath(linePath)
        ctx.setStrokeColor(NSColor.systemOrange.cgColor)
        ctx.setLineWidth(2)
        ctx.strokePath()

        // --- "NOW" vertical marker using system accent ---
        let tz = sched.locationManager?.timezone ?? .current
        var cal = Calendar.current; cal.timeZone = tz
        let nowDate = Date()
        let now = cal.component(.hour, from: nowDate) * 60 + cal.component(.minute, from: nowDate)
        let nx = xFor(now)
        let ny = yFor(temp(now))

        let accentColor = NSColor.controlAccentColor

        // Vertical dashed line
        ctx.setStrokeColor(accentColor.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.move(to: CGPoint(x: nx, y: gy))
        ctx.addLine(to: CGPoint(x: nx, y: gy + gh))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])

        // Dot at current position
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 6, color: accentColor.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(accentColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: nx - 5, y: ny - 5, width: 10, height: 10))
        ctx.restoreGState()

        // White ring
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(x: nx - 5, y: ny - 5, width: 10, height: 10))

        ctx.restoreGState() // end graph clip

        // --- Phase labels inside graph area ---
        let phaseLabelAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        let dayMid = evMin > wake ? (wake + evMin) / 2 : ((wake + evMin + 1440) / 2) % 1440
        let dayLabel = NSAttributedString(string: "DAYLIGHT", attributes: phaseLabelAttr)
        dayLabel.draw(at: NSPoint(x: xFor(dayMid) - dayLabel.size().width / 2, y: gy + 4))

        let evMid = niMin > evMin ? (evMin + niMin) / 2 : ((evMin + niMin + 1440) / 2) % 1440
        let evLabel = NSAttributedString(string: "EVENING", attributes: phaseLabelAttr)
        evLabel.draw(at: NSPoint(x: xFor(evMid) - evLabel.size().width / 2, y: gy + 4))

        let sleepMid = wake > bed ? (bed + wake) / 2 : ((bed + wake + 1440) / 2) % 1440
        let sleepLabelAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.quaternaryLabelColor
        ]
        let sleepLabel = NSAttributedString(string: "SLEEP", attributes: sleepLabelAttr)
        sleepLabel.draw(at: NSPoint(x: xFor(sleepMid) - sleepLabel.size().width / 2, y: gy + 4))

        // --- Y-axis labels ---
        let axisAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for (k, label) in [(2700, "2700K"), (3400, "3400K"), (6500, "6500K")] as [(CGFloat, String)] {
            let s = NSAttributedString(string: label, attributes: axisAttr)
            s.draw(at: NSPoint(x: gx - s.size().width - 4, y: yFor(k) - s.size().height / 2))
        }

        // --- X-axis time labels ---
        let timeAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for h in stride(from: 0, through: 24, by: 3) {
            let label = String(format: "%d:00", h % 24)
            let s = NSAttributedString(string: label, attributes: timeAttr)
            let xx = xFor(h * 60)
            s.draw(at: NSPoint(x: xx - s.size().width / 2, y: 4))
        }

        // --- "NOW" label ---
        let nowLabelAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: accentColor
        ]
        let nowLabel = NSAttributedString(string: "NOW", attributes: nowLabelAttr)
        let nlX = min(max(nx - nowLabel.size().width / 2, gx), gx + gw - nowLabel.size().width)
        nowLabel.draw(at: NSPoint(x: nlX, y: 16))

        // --- Bed & Wake time markers ---
        let markerAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let bedX = xFor(bed)
        let bedStr = NSAttributedString(
            string: "BED " + String(format: "%02d:%02d", sched.bedHour, sched.bedMinute),
            attributes: markerAttr
        )
        let bedLabelX = min(max(bedX - bedStr.size().width / 2, gx), gx + gw - bedStr.size().width)
        bedStr.draw(at: NSPoint(x: bedLabelX, y: gy + gh - 14))

        let wakeX = xFor(wake)
        let wakeStr = NSAttributedString(
            string: "WAKE " + String(format: "%02d:%02d", sched.wakeHour, sched.wakeMinute),
            attributes: markerAttr
        )
        let wakeLabelX = min(max(wakeX - wakeStr.size().width / 2, gx), gx + gw - wakeStr.size().width)
        wakeStr.draw(at: NSPoint(x: wakeLabelX, y: gy + gh - 14))
    }
}

// MARK: - Native Time Picker (NSDatePicker)

class TimePicker: NSView {
    private let datePicker: NSDatePicker
    var onChange: (() -> Void)?

    var hour: Int {
        get { Calendar.current.component(.hour, from: datePicker.dateValue) }
        set { setTime(hour: newValue, minute: minute) }
    }

    var minute: Int {
        get { Calendar.current.component(.minute, from: datePicker.dateValue) }
        set { setTime(hour: hour, minute: newValue) }
    }

    init(hour: Int, minute: Int) {
        datePicker = NSDatePicker()
        super.init(frame: .zero)

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = .hourMinute
        datePicker.locale = Locale(identifier: "en_GB") // 24-hour format
        datePicker.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        datePicker.isBezeled = true
        datePicker.isBordered = true
        datePicker.drawsBackground = false
        datePicker.target = self
        datePicker.action = #selector(dateChanged)

        setTime(hour: hour, minute: minute)
        addSubview(datePicker)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setTime(hour: Int, minute: Int) {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        if let date = Calendar.current.date(from: comps) {
            datePicker.dateValue = date
        }
    }

    override func layout() {
        super.layout()
        datePicker.sizeToFit()
        let pickerSize = datePicker.fittingSize
        let x = (bounds.width - pickerSize.width) / 2
        let y = (bounds.height - pickerSize.height) / 2
        datePicker.frame = NSRect(x: x, y: y, width: pickerSize.width, height: pickerSize.height)
    }

    @objc private func dateChanged() {
        onChange?()
    }
}

// MARK: - Schedule Controls View (inline in menu)

class ScheduleControlsView: NSView {
    let bedPicker: TimePicker
    let wakePicker: TimePicker
    let locationLabel: NSTextField
    var onChange: (() -> Void)?

    private let schedule: ScheduleManager
    private let location: LocationManager

    init(schedule: ScheduleManager, location: LocationManager) {
        self.schedule = schedule
        self.location = location

        locationLabel = NSTextField(labelWithString: location.displayString)
        bedPicker = TimePicker(hour: schedule.bedHour, minute: schedule.bedMinute)
        wakePicker = TimePicker(hour: schedule.wakeHour, minute: schedule.wakeMinute)

        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 70))

        // Location
        let locIcon = NSTextField(labelWithString: "\u{1F4CD}")
        locIcon.font = NSFont.systemFont(ofSize: 10)
        locIcon.frame = NSRect(x: 14, y: 52, width: 16, height: 14)
        addSubview(locIcon)

        locationLabel.font = NSFont.systemFont(ofSize: 10)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.frame = NSRect(x: 30, y: 52, width: 280, height: 14)
        addSubview(locationLabel)

        // Bed row
        let bedLabel = NSTextField(labelWithString: "\u{1F6CF} Bed")
        bedLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        bedLabel.frame = NSRect(x: 14, y: 26, width: 50, height: 18)
        addSubview(bedLabel)

        bedPicker.frame = NSRect(x: 58, y: 22, width: 102, height: 26)
        bedPicker.onChange = { [weak self] in self?.timeChanged() }
        addSubview(bedPicker)

        // Wake row
        let wakeLabel = NSTextField(labelWithString: "\u{23F0} Wake")
        wakeLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        wakeLabel.frame = NSRect(x: 166, y: 26, width: 50, height: 18)
        addSubview(wakeLabel)

        wakePicker.frame = NSRect(x: 216, y: 22, width: 102, height: 26)
        wakePicker.onChange = { [weak self] in self?.timeChanged() }
        addSubview(wakePicker)

        // Summary line
        let hint = NSTextField(labelWithString: "Evening starts 3h before bed, night 1h before")
        hint.font = NSFont.systemFont(ofSize: 9)
        hint.textColor = NSColor.tertiaryLabelColor
        hint.frame = NSRect(x: 14, y: 4, width: 300, height: 14)
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func timeChanged() {
        schedule.bedHour = bedPicker.hour
        schedule.bedMinute = bedPicker.minute
        schedule.wakeHour = wakePicker.hour
        schedule.wakeMinute = wakePicker.minute
        schedule.save()
        if schedule.enabled { schedule.restart() }
        onChange?()
    }

    func updateLocation() {
        locationLabel.stringValue = location.displayString
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let gamma = GammaController()
    let location = LocationManager()
    let schedule = ScheduleManager()
    var statusItem: NSStatusItem?
    var sliderView: SliderView?
    var scheduleStatusItem: NSMenuItem?
    var graphMenuItem: NSMenuItem?
    var controlsMenuItem: NSMenuItem?
    var menuGraphView: ScheduleGraphView?
    var scheduleControls: ScheduleControlsView?
    var toggleCheck: NSButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Wire location into schedule
        schedule.locationManager = location

        location.onUpdate = { [weak self] in
            self?.scheduleControls?.updateLocation()
        }

        schedule.onPhaseChange = { [weak self] phase in
            guard let self = self else { return }
            self.applyTemp(phase.temperature)
            self.updateScheduleMenu()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "\u{1F453}"

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

        // Toggle as custom view so menu stays open
        let toggleItem = NSMenuItem()
        let toggleContainer = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        let check = NSButton(checkboxWithTitle: "Enable Auto Schedule", target: self, action: #selector(toggleSchedule))
        check.state = schedule.enabled ? .on : .off
        check.font = NSFont.systemFont(ofSize: 13)
        check.frame = NSRect(x: 18, y: 3, width: 280, height: 20)
        toggleContainer.addSubview(check)
        toggleItem.view = toggleContainer
        toggleCheck = check
        menu.addItem(toggleItem)

        let statusMenuItem = NSMenuItem(title: "Off", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        scheduleStatusItem = statusMenuItem
        menu.addItem(statusMenuItem)

        // Inline controls (bed/wake pickers + location)
        let ctrlItem = NSMenuItem()
        let cv = ScheduleControlsView(schedule: schedule, location: location)
        cv.onChange = { [weak self] in
            self?.menuGraphView?.needsDisplay = true
            self?.updateScheduleMenu()
        }
        ctrlItem.view = cv
        ctrlItem.isHidden = !schedule.enabled
        controlsMenuItem = ctrlItem
        scheduleControls = cv
        menu.addItem(ctrlItem)

        // Inline graph
        let graphItem = NSMenuItem()
        let gv = ScheduleGraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))
        gv.schedule = schedule
        graphItem.view = gv
        graphItem.isHidden = !schedule.enabled
        graphMenuItem = graphItem
        menuGraphView = gv
        menu.addItem(graphItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(doQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
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
        schedule.enabled = (toggleCheck?.state == .on)
        schedule.save()
        schedule.restart()
        updateScheduleMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuGraphView?.needsDisplay = true
    }

    func updateScheduleMenu() {
        toggleCheck?.state = schedule.enabled ? .on : .off
        if schedule.enabled {
            let phase = schedule.computePhase()
            scheduleStatusItem?.title = "\u{25CF} \(phase.rawValue)"
            graphMenuItem?.isHidden = false
            controlsMenuItem?.isHidden = false
        } else {
            scheduleStatusItem?.title = "Off"
            graphMenuItem?.isHidden = true
            controlsMenuItem?.isHidden = true
        }
        menuGraphView?.needsDisplay = true
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
