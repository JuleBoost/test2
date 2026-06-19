import UIKit
import Flutter
import CoreML
import Vision

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    private var model: VNCoreMLModel?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
        let channel = FlutterMethodChannel(name: "com.example.test2/detector", binaryMessenger: controller.binaryMessenger)

        channel.setMethodCallHandler({ (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            if call.method == "loadModel" {
                self.loadModel(call: call, result: result)
            } else if call.method == "detect" {
                self.runInference(call: call, result: result)
            } else {
                result(FlutterMethodNotImplemented)
            }
        })

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func loadModel(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
            result(false); return
        }
        
        let url = URL(fileURLWithPath: path)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let compiledUrl = try MLModel.compileModel(at: url)
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let mlModel = try MLModel(contentsOf: compiledUrl, configuration: config)
                self.model = try VNCoreMLModel(for: mlModel)
                DispatchQueue.main.async { result(true) }
            } catch {
                DispatchQueue.main.async { result(false) }
            }
        }
    }

    private func runInference(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let model = self.model,
              let args = call.arguments as? [String: Any],
              let buffer = args["buffer"] as? FlutterStandardTypedData,
              let width = args["width"] as? Int,
              let height = args["height"] as? Int else {
            result([]); return
        }

        let request = VNCoreMLRequest(model: model) { request, error in
            let observations = request.results as? [VNRecognizedObjectObservation] ?? []
            let results = observations.map { obj -> [String: Any] in
                let box = obj.boundingBox
                return [
                    "label": obj.labels.first?.identifier ?? "unknown",
                    "confidence": obj.confidence,
                    "x": box.origin.x,
                    "y": 1.0 - box.origin.y - box.size.height,
                    "w": box.size.width,
                    "h": box.size.height
                ]
            }
            result(results)
        }

        request.imageCropAndScaleOption = .scaleFill
        
        // Convert BGRA bytes to CVPixelBuffer
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue, kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        
        if let pb = pixelBuffer {
            CVPixelBufferLockBaseAddress(pb, [])
            let data = buffer.data
            data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                memcpy(CVPixelBufferGetBaseAddress(pb), ptr.baseAddress, data.count)
            }
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
            try? handler.perform([request])
            CVPixelBufferUnlockBaseAddress(pb, [])
        }
    }
}
