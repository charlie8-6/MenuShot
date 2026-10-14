import Vision
import AppKit

/// OCR 文本识别（Vision 框架，随屏幕录制授权即可用，无需额外权限）。
enum OCRService {

    static func recognize(in image: CGImage, completion: @escaping (Result<String, Error>) -> Void) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                let lines = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
                let text = lines.joined(separator: "\n")
                DispatchQueue.main.async {
                    completion(.success(text))
                }
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }
}
