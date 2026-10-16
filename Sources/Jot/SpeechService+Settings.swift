import Combine
import Foundation
import JotCore

/// Settings the screens and `jot settings` read and write. Each property reads `settings`; each setter saves and then calls
/// `settingChanged`, which applies that setting's side effect and redraws.
extension SpeechService {
    /// After the store took a new value for `key`, from a screen or from `jot settings`: the side effect that setting has,
    /// then a redraw. The store already holds the value, so a setting with no side effect only redraws.
    func settingChanged(_ key: String) {
        objectWillChange.send()
        switch key {
        case JotDefaultsKey.automaticMicrophone: capture.resetInputSearch()
        case JotDefaultsKey.suggestionsEnabled:
            if suggestionsEnabled && !DictationInput.accessibilityGranted { input.requestAccessibility() }
            updateSuggestionMonitoring()
        case JotDefaultsKey.suggestionScreenContext, JotDefaultsKey.suggestionHeardMatches, JotDefaultsKey.suggestionWindowMinutes:
            suggestions.dismiss(action: .settingsChanged)
        case JotDefaultsKey.suggestionWindowImage:
            // The one place Screen Recording is asked for: turning the image on, never a request.
            if suggestionWindowImage && !WindowImageCapture.permitted { WindowImageCapture.requestPermission() }
            suggestions.dismiss(action: .settingsChanged)
        case JotDefaultsKey.highlightTargetField:
            if !highlightTargetField { dictation.hideHighlight() }
        case JotDefaultsKey.muteSpeakersDuringDictation:
            if !muteSpeakersDuringDictation { dictation.endSpeakerMute() }
        case JotDefaultsKey.keepMacAwakeWhileListening:
            updateKeepAwakeAssertion()
        case JotDefaultsKey.keepAudioForSpeakerPass:
            if !keepAudioForSpeakerPass { timeline.discardSessionAudio() }
        case JotSettings.speakerConfidence, JotSettings.minimumSpeakerTurn, JotSettings.hideFillerRows:
            library.refreshHistory()
        case JotSettings.paragraphPause:
            // Live groups by the paragraph pause alone, so a change to any other tuning value leaves it as it is.
            library.refreshHistory(); library.reloadLive()
        default: break
        }
    }

    private func save(_ key: String, _ value: Bool) { settings.set(key, value); settingChanged(key) }
    private func save(_ key: String, _ value: Int) { settings.set(key, value); settingChanged(key) }

    var automaticMicrophone: Bool {
        get { settings.bool(JotDefaultsKey.automaticMicrophone) }
        set { save(JotDefaultsKey.automaticMicrophone, newValue) }
    }

    var suggestionsEnabled: Bool {
        get { settings.bool(JotDefaultsKey.suggestionsEnabled) }
        set { save(JotDefaultsKey.suggestionsEnabled, newValue) }
    }
    /// Read the text shown above the field, such as a chat, for a request. Local and never stored.
    var suggestionScreenContext: Bool {
        get { settings.bool(JotDefaultsKey.suggestionScreenContext) }
        set { save(JotDefaultsKey.suggestionScreenContext, newValue) }
    }
    /// Add one image of the window around the field to a request. Local, in memory for that request, never stored.
    var suggestionWindowImage: Bool {
        get { settings.bool(JotDefaultsKey.suggestionWindowImage) }
        set { save(JotDefaultsKey.suggestionWindowImage, newValue) }
    }
    /// The model is ready and takes images: macOS 27 or later with a model that has vision.
    var windowImageSupported: Bool { AppleFMGeneration.acceptsImages }
    /// A selection rewrite can restore quoted words from matching speech within the context window.
    var suggestionHeardMatches: Bool {
        get { settings.bool(JotDefaultsKey.suggestionHeardMatches) }
        set { save(JotDefaultsKey.suggestionHeardMatches, newValue) }
    }
    /// How far back a suggestion may read: speech Jot heard and messages agents sent it, in minutes.
    var suggestionWindowMinutes: Int {
        get { settings.int(JotDefaultsKey.suggestionWindowMinutes) }
        set { save(JotDefaultsKey.suggestionWindowMinutes, newValue) }
    }
    var highlightTargetField: Bool {
        get { settings.bool(JotDefaultsKey.highlightTargetField) }
        set { save(JotDefaultsKey.highlightTargetField, newValue) }
    }
    var muteSpeakersDuringDictation: Bool {
        get { settings.bool(JotDefaultsKey.muteSpeakersDuringDictation) }
        set { save(JotDefaultsKey.muteSpeakersDuringDictation, newValue) }
    }
    var keepMacAwakeWhileListening: Bool {
        get { settings.bool(JotDefaultsKey.keepMacAwakeWhileListening) }
        set { save(JotDefaultsKey.keepMacAwakeWhileListening, newValue) }
    }
    /// Minutes of quiet that end an ambient session; 0 keeps one session until capture stops. A named meeting never splits.
    var newSessionAfterSilence: Int {
        get { settings.int(JotDefaultsKey.newSessionAfterSilence) }
        set { save(JotDefaultsKey.newSessionAfterSilence, newValue) }
    }
    /// Off means no audio reaches disk and no speaker pass runs. Switching off mid-session deletes that session's file; switching on waits for the next session, since a file that starts mid-session would misplace every segment.
    var keepAudioForSpeakerPass: Bool {
        get { settings.bool(JotDefaultsKey.keepAudioForSpeakerPass) }
        set { save(JotDefaultsKey.keepAudioForSpeakerPass, newValue) }
    }
    var cleanUpTranscriptions: Bool {
        get { settings.bool(JotDefaultsKey.cleanUpTranscriptions) }
        set { save(JotDefaultsKey.cleanUpTranscriptions, newValue) }
    }
    var cleanUpDictation: Bool {
        get { settings.bool(JotDefaultsKey.cleanUpDictation) }
        set { save(JotDefaultsKey.cleanUpDictation, newValue) }
    }
    /// The four grouping and speaker values as one, for the sliders and the code that groups rows.
    var tuning: TranscriptionTuning {
        get { settings.tuning }
        set {
            let previous = settings.tuning
            settings.setTuning(newValue)
            let saved = settings.tuning
            objectWillChange.send()
            guard saved != previous else { return }
            library.refreshHistory()
            if saved.paragraphPause != previous.paragraphPause { library.reloadLive() }
        }
    }
}
