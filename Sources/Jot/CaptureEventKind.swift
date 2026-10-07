import AppKit
import AVFoundation
import Combine
import Foundation
import JotCore
import FluidAudio

/// The raw values are stored in the capture_events table and shown in History.
enum CaptureEventKind: String {
    case started, paused, stopped, sleep
    case deviceChange = "device_change", inputStalled = "input_stalled"
    case audioGap = "audio_gap", audioDiscarded = "audio_discarded", processingError = "processing_error"
    case speakerPass = "speaker_pass", sessionSplit = "session_split"
}
