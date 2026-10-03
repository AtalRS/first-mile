import UIKit
import AVFoundation
import Capacitor

// Copied over ios/App/App/AppDelegate.swift by scripts/setup_ios.sh. Edit this copy.

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration",
                                          sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// The app's root view controller (created in SceneDelegate.swift). Registers the Coach plugin.
class CoachBridgeViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(CoachPlugin())
    }
}

/// `Capacitor.Plugins.Coach` in index.html. The page sends the workout's timeline of coach
/// clips and beeps; native code plays them on time, even with the screen locked.
@objc(CoachPlugin)
public class CoachPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CoachPlugin"
    public let jsName = "Coach"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "schedule", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "play", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stop", returnType: CAPPluginReturnPromise)
    ]
    private let audio = CoachAudio()

    /// events: [{at: epoch ms, clip?: "coach/x.mp3", tone?: Hz, count?: beeps}]
    @objc func schedule(_ call: CAPPluginCall) {
        let events = (call.getArray("events") ?? []).compactMap { CoachEvent($0 as? JSObject) }
        DispatchQueue.main.async { self.audio.schedule(events); call.resolve() }
    }

    @objc func play(_ call: CAPPluginCall) {
        guard let clip = call.getString("clip") else { return call.reject("clip is required") }
        DispatchQueue.main.async { self.audio.schedule([CoachEvent(at: Date().timeIntervalSince1970, clip: clip)]); call.resolve() }
    }

    @objc func stop(_ call: CAPPluginCall) {
        DispatchQueue.main.async { self.audio.stop(); call.resolve() }
    }
}

struct CoachEvent {
    let at: TimeInterval
    var clip: String?
    var tone: Double?
    var count = 1

    init(at: TimeInterval, clip: String) {
        self.at = at
        self.clip = clip
    }

    init?(_ o: JSObject?) {
        guard let o, let at = number(o["at"]) else { return nil }
        self.at = at / 1000
        clip = o["clip"] as? String
        tone = number(o["tone"])
        count = Int(number(o["count"]) ?? 1)
    }
}

private func number(_ v: JSValue?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    return nil
}

/// Plays the scheduled clips and beeps. A silent loop keeps the app running in the background
/// (UIBackgroundModes audio) while mixing with the runner's music; the music is lowered only
/// while the coach is speaking.
final class CoachAudio: NSObject, AVAudioPlayerDelegate {
    private let session = AVAudioSession.sharedInstance()
    private var events: [CoachEvent] = []
    private var timer: Timer?
    private var silence: AVAudioPlayer?
    private var voice: AVAudioPlayer?
    private var tones: [AVAudioPlayer] = []
    private var toneData: [String: Data] = [:]
    private var ducked = false
    private var quietSince: TimeInterval = 0
    /// Cues that come due this late (e.g. after a phone call) are dropped rather than played.
    private let maxLate: TimeInterval = 3

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: session)
    }

    /// Replaces the timeline. Stops whatever the coach is saying; the new timeline starts with
    /// the right line if one is due now.
    func schedule(_ new: [CoachEvent]) {
        voice?.stop()
        voice = nil
        events = new.sorted { $0.at < $1.at }
        guard !events.isEmpty else { return stop() }
        if timer == nil {
            startSession()
            if silence == nil {
                silence = try? AVAudioPlayer(data: Wav.silence())
                silence?.numberOfLoops = -1
            }
            silence?.play()
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    func stop() {
        events = []
        timer?.invalidate()
        timer = nil
        voice?.stop()
        voice = nil
        tones.forEach { $0.stop() }
        tones = []
        silence?.stop()
        ducked = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        while let e = events.first, e.at <= now {
            events.removeFirst()
            guard now - e.at <= maxLate else { continue }
            if let tone = e.tone { beep(tone, count: e.count) }
            if let clip = e.clip { speak(clip) }
        }
        tones.removeAll { !$0.isPlaying }
        guard voice == nil, tones.isEmpty, now - quietSince > 0.4 else { return }
        if events.isEmpty { stop() } else if ducked { unduck() }
    }

    private func speak(_ clip: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("public").appendingPathComponent(clip),
              let player = try? AVAudioPlayer(contentsOf: url) else { return }
        voice?.stop()
        duck()
        player.delegate = self
        player.play()
        voice = player
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === voice else { return }
        voice = nil
        quietSince = Date().timeIntervalSince1970
    }

    private func beep(_ freq: Double, count: Int) {
        let key = "\(freq)x\(count)"
        let data = toneData[key] ?? Wav.beeps(freq, count: count)
        toneData[key] = data
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.play()
        tones.append(player)
    }

    private func startSession() {
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        ducked = false
    }

    private func duck() {
        guard !ducked else { return }
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
        try? session.setActive(true)
        ducked = true
    }

    /// iOS only brings other apps' volume back up when our session is deactivated, so briefly
    /// pause the silent loop, deactivate, and start again without ducking.
    private func unduck() {
        silence?.pause()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        startSession()
        silence?.play()
    }

    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .ended, timer != nil else { return }
        voice = nil
        startSession()
        silence?.play()
    }
}

/// 16-bit mono WAV data for the silent keep-alive loop and the beeps.
enum Wav {
    static let rate = 44100

    static func silence() -> Data {
        wav([Int16](repeating: 0, count: rate))
    }

    /// Same as the web app's beep(): `count` sine pips 0.22 s apart, each fading out over 0.16 s.
    static func beeps(_ freq: Double, count: Int) -> Data {
        let pip = Int(Double(rate) * 0.18)
        var s = [Int16](repeating: 0, count: Int(Double(rate) * 0.22 * Double(max(count, 1) - 1)) + pip)
        for i in 0..<count {
            let start = Int(Double(rate) * 0.22 * Double(i))
            for j in 0..<pip where start + j < s.count {
                let t = Double(j) / Double(rate)
                let gain = 0.25 * pow(0.001 / 0.25, min(t / 0.16, 1))
                s[start + j] = Int16(gain * sin(2 * .pi * freq * t) * Double(Int16.max))
            }
        }
        return wav(s)
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.forEach { u16(UInt16(bitPattern: $0)) }
        return d
    }
}
