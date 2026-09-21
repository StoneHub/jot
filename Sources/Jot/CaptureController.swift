import AppKit
import Foundation
import JotCore

/// Gets samples from the chosen input device reliably: device selection, the saved-microphone fallback, and the retry after wake. What the samples mean is SpeechService's job.
@MainActor
final class CaptureController: ObservableObject {
    let microphone: MicrophoneSource
    @Published private(set) var inputDevices: [AudioInputDevice] = []
    @Published var selectedInputUID = UserDefaults.standard.string(forKey: JotDefaultsKey.selectedInputUID) ?? ""
    @Published private(set) var selectedInputName = UserDefaults.standard.string(forKey: JotDefaultsKey.selectedInputName) ?? "Saved microphone"
    /// True while the saved microphone is unplugged; capture then runs on System Default and the choice is kept.
    @Published private(set) var selectedInputMissing = false
    @Published private(set) var systemDefaultInputName = "System Default"
    /// Sentences for the service notice; the controller has no screen of its own.
    var onNotice: (String) -> Void = { _ in }
    private let availableDevices: () -> [AudioInputDevice]
    private let defaultDeviceName: () -> String?
    private let retry: MicrophoneStartRetry
    private var watcher: AudioInputDeviceWatcher?

    init(microphone: MicrophoneSource, retry: MicrophoneStartRetry = MicrophoneStartRetry(),
         availableDevices: @escaping () -> [AudioInputDevice] = AudioInputDevice.available,
         defaultDeviceName: @escaping () -> String? = AudioInputDevice.defaultName) {
        self.microphone = microphone
        self.retry = retry
        self.availableDevices = availableDevices
        self.defaultDeviceName = defaultDeviceName
    }

    var running: Bool { microphone.running }
    var bufferedSampleCount: Int { microphone.bufferedSampleCount }
    /// Picker rows: every connected input, plus the saved one marked not connected so the selection always matches a tag.
    var inputRows: [AudioInputDevice] {
        guard selectedInputMissing else { return inputDevices }
        return inputDevices + [AudioInputDevice(id: selectedInputUID, name: "\(selectedInputName) (not connected)")]
    }

    func watchDevices() {
        refreshInputDevices()
        watcher = AudioInputDeviceWatcher { [weak self] in self?.refreshInputDevices() }
    }

    func stopWatching() { watcher?.stop(); watcher = nil }

    func refreshInputDevices() {
        inputDevices = availableDevices()
        systemDefaultInputName = defaultDeviceName() ?? "System Default"
        if let saved = inputDevices.first(where: { $0.id == selectedInputUID }), saved.name != selectedInputName {
            selectedInputName = saved.name; UserDefaults.standard.set(saved.name, forKey: JotDefaultsKey.selectedInputName)
        }
        let wasMissing = selectedInputMissing
        let captureUID = MicrophoneSelection.captureUID(saved: selectedInputUID, available: inputDevices.map(\.id))
        selectedInputMissing = !selectedInputUID.isEmpty && captureUID == nil
        if selectedInputMissing && !wasMissing { onNotice("\(selectedInputName) is not connected. Using System Default until it returns.") }
        if wasMissing && !selectedInputMissing { onNotice(running ? "\(selectedInputName) is connected again. Jot uses it when capture next starts." : "\(selectedInputName) is connected again.") }
        microphone.setInputForNextStart(uid: captureUID)
    }

    func setInput(uid: String) throws {
        try microphone.setInput(uid: MicrophoneSelection.captureUID(saved: uid, available: inputDevices.map(\.id)))
        selectedInputUID = uid
        if let device = inputDevices.first(where: { $0.id == uid }) { selectedInputName = device.name }
        selectedInputMissing = !uid.isEmpty && !inputDevices.contains { $0.id == uid }
        if uid.isEmpty { UserDefaults.standard.removeObject(forKey: JotDefaultsKey.selectedInputUID); UserDefaults.standard.removeObject(forKey: JotDefaultsKey.selectedInputName) }
        else { UserDefaults.standard.set(uid, forKey: JotDefaultsKey.selectedInputUID); UserDefaults.standard.set(selectedInputName, forKey: JotDefaultsKey.selectedInputName) }
    }

    /// Core Audio can refuse the input device for a few seconds after wake or a device change, so a failed start is retried before it is reported. `shouldContinue` is asked after each wait; false from it, or a cancelled wait, returns false without starting.
    func startRetrying(shouldContinue: () -> Bool) async throws -> Bool {
        var attempt = 1
        while true {
            do { try microphone.start(); return true }
            catch {
                guard let delay = retry.delay(afterFailedAttempt: attempt) else {
                    throw JotError.message("The microphone did not start after \(attempt) tries (\(error.localizedDescription)). Choose Resume to try again, or relaunch Jot.")
                }
                onNotice("The microphone did not start (\(error.localizedDescription)). Retrying…")
                do { try await Task.sleep(for: .seconds(delay)) } catch { return false }
                guard shouldContinue() else { return false }
                refreshInputDevices()
                attempt += 1
            }
        }
    }

    func stop() { microphone.stop() }
    func drain() -> (samples: [Float], dropped: Int, lastAudio: Date, rms: Float) { microphone.drain() }
    func shouldIgnoreConfigurationChange() -> Bool { microphone.shouldIgnoreConfigurationChange() }
}
