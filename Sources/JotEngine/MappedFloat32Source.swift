import CoreML
import FluidAudio
import Foundation
import JotCore

/// A session file mapped into memory. It is already the Float32 layout FluidAudio streams for its own file input, so no converted copy is written anywhere.
struct MappedFloat32Source: AudioSampleSource {
    private let data: Data
    let sampleCount: Int

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        sampleCount = data.count / MemoryLayout<Float>.stride
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, offset >= 0, offset < sampleCount else { return }
        let available = min(sampleCount - offset, count)
        data.withUnsafeBytes { destination.update(from: $0.bindMemory(to: Float.self).baseAddress!.advanced(by: offset), count: available) }
    }
}
