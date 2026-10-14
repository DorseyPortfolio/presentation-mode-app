import CoreMedia
import NDIBridge

// Lifecycle/UI fields stay on the main actor; send touches only the native locked sender.
final class NDIService: @unchecked Sendable {
    private let sender = pm_ndi_sender_create()
    private(set) var isRunning = false
    private(set) var sourceName = ""

    deinit { pm_ndi_sender_destroy(sender) }

    func start(sourceName: String) throws {
        guard !isRunning else { return }
        let trimmedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw NDIError.failure("Enter the NDI source name used by ProPresenter.")
        }
        guard let runtimePath = Bundle.main.privateFrameworksPath?.appending("/libndi.dylib") else {
            throw NDIError.failure("The bundled NDI runtime path is unavailable.")
        }
        var error = Array<CChar>(repeating: 0, count: 512)
        let result = runtimePath.withCString { runtime in
            trimmedName.withCString { name in
                error.withUnsafeMutableBufferPointer {
                    pm_ndi_sender_start(sender, runtime, name, $0.baseAddress, $0.count)
                }
            }
        }
        guard result == 0 else { throw NDIError.failure(Self.decode(error)) }
        self.sourceName = trimmedName
        isRunning = true
    }

    func send(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var error = Array<CChar>(repeating: 0, count: 512)
        let result = error.withUnsafeMutableBufferPointer {
            pm_ndi_sender_send_pixel_buffer(sender, Unmanaged.passUnretained(pixelBuffer).toOpaque(), $0.baseAddress, $0.count)
        }
        if result < 0 && result != -2 { fputs("NDI output error: \(Self.decode(error))\n", stderr) }
    }

    func stop() {
        pm_ndi_sender_stop(sender)
        isRunning = false
    }

    private static func decode(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    enum NDIError: LocalizedError {
        case failure(String)
        var errorDescription: String? {
            switch self { case .failure(let message): message.isEmpty ? "NDI output failed." : message }
        }
    }
}
