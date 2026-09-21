import Foundation
import AVFoundation
import CoreVideo

/// Generates our own silent video; no external film, download permission or network is needed.
@main struct CreateDownloadFixture {
    static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                          kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            var pixel: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel) == kCVReturnSuccess,
                  let pixel else { throw NSError(domain: "Fixture pixel buffer", code: 1) }
            CVPixelBufferLockBaseAddress(pixel, [])
            memset(CVPixelBufferGetBaseAddress(pixel), Int32(frame), CVPixelBufferGetDataSize(pixel))
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        // A valid ISO BMFF free box makes downloads long enough to pause and test Range.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let padding = 8 * 1024 * 1024
        var length = UInt32(padding + 8).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: Data("free".utf8))
        try handle.write(contentsOf: Data(repeating: 0, count: padding))
        try handle.close()
        print("Created local MP4 fixture: \(url.lastPathComponent)")
    }
}
