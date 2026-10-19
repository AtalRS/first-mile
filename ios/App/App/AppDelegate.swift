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
    /// The run/walk change (or finish) at the start of a segment, said late if it was missed.
    var key = false

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
        key = o["key"] as? Bool ?? false
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
/// while the coach is speaking. After a phone call (or anything else that takes the audio) the
/// loop is restarted and the coach says the run/walk change the runner missed.
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
    /// Cues that come due this late are dropped rather than played, except the latest key one.
    private let maxLate: TimeInterval = 3
    /// A phone call or similar has the audio; wait for it to end (or for the app to be opened).
    private var interrupted = false
    private var retryAt: TimeInterval = 0
    /// The latest key cue that came due while the coach couldn't play, said once it can.
    private var missed: [CoachEvent] = []

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(mediaReset), name: AVAudioSession.mediaServicesWereResetNotification, object: session)
        nc.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Replaces the timeline. Stops whatever the coach is saying; the new timeline starts with
    /// the right line if one is due now.
    func schedule(_ new: [CoachEvent]) {
        voice?.stop()
        voice = nil
        events = new.sorted { $0.at < $1.at }
        missed = []
        guard !events.isEmpty else { return stop() }
        if timer == nil {
            interrupted = false
            retryAt = 0
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
        missed = []
        ducked = false
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        if !interrupted, silence?.isPlaying != true, now >= retryAt, !resume() { retryAt = now + 2 }
        let live = !interrupted && silence?.isPlaying == true
        while let e = events.first, e.at <= now {
            events.removeFirst()
            if live && now - e.at <= maxLate {
                if e.key { missed = [] }
                play(e)
            } else if e.key {
                if missed.first?.at != e.at { missed = [] }
                missed.append(e)
            }
        }
        guard live else { return }
        missed.forEach(play)
        missed = []
        tones.removeAll { !$0.isPlaying }
        guard voice == nil, tones.isEmpty, now - quietSince > 0.4 else { return }
        if events.isEmpty { stop() } else if ducked { unduck() }
    }

    private func play(_ e: CoachEvent) {
        if let tone = e.tone { beep(tone, count: e.count) }
        if let clip = e.clip { speak(clip) }
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

    /// Starts the session and the silent loop, dropping anything cut off when the audio was
    /// taken away. False while something else (e.g. a call) still has the audio.
    private func resume() -> Bool {
        voice?.stop()
        voice = nil
        tones.forEach { $0.stop() }
        tones = []
        if silence == nil {
            silence = try? AVAudioPlayer(data: Wav.silence())
            silence?.numberOfLoops = -1
        }
        guard (try? startSession()) != nil else { return false }
        return silence?.play() == true
    }

    private func startSession() throws {
        ducked = false
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
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
        try? startSession()
        silence?.play()
    }

    /// Phone calls, alarms, Siri. Cues that come due meanwhile are held back (see tick()).
    @objc private func interruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let reason = (note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt).flatMap(AVAudioSession.InterruptionReason.init)
        DispatchQueue.main.async {
            guard self.timer != nil else { return }
            // A late notice that the app was suspended isn't a call: tick() just restarts the audio.
            if type == .began && reason != .appWasSuspended {
                self.interrupted = true
            } else if type == .ended {
                self.interrupted = false
                self.retryAt = 0
                self.tick()
            }
        }
    }

    /// iOS doesn't always send the end of an interruption, so try again when the app is opened.
    @objc private func becameActive() {
        guard timer != nil, interrupted || silence?.isPlaying != true else { return }
        interrupted = false
        retryAt = 0
        tick()
    }

    /// The system audio server restarted: every player is dead, so tick() builds them again.
    @objc private func mediaReset() {
        DispatchQueue.main.async {
            self.silence = nil
            self.voice = nil
            self.tones = []
            self.ducked = false
            self.retryAt = 0
        }
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
