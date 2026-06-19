import UIKit
import Flutter
import AVFoundation
import Vision

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    var model: VNCoreMLModel?
    var channel: FlutterMethodChannel?

    override func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = window?.rootViewController as! FlutterViewController
        channel = FlutterMethodChannel(name: "com.example.test2/detector", binaryMessenger: controller.binaryMessenger)
        
        let factory = NativeViewFactory(delegate: self)
        registrar(forPlugin: "NativeCam")?.register(factory, withId: "native-cam-view")

        channel?.setMethodCallHandler({ (call, result) in
            if call.method == "loadModel", let args = call.arguments as? [String: Any], let path = args["path"] as? String {
                self.loadModel(path: path, result: result)
            } else { result(FlutterMethodNotImplemented) }
        })

        GeneratedPluginRegistrant.register(with: self)
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    func loadModel(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)
        do {
            let compiledUrl = try MLModel.compileModel(at: url)
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiledUrl, configuration: config)
            self.model = try VNCoreMLModel(for: mlModel)
            result(true)
        } catch { result(false) }
    }
}

class NativeViewFactory: NSObject, FlutterPlatformViewFactory {
    private var delegate: AppDelegate
    init(delegate: AppDelegate) { self.delegate = delegate }
    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return NativeCamView(frame: frame, delegate: delegate)
    }
}

class NativeCamView: NSObject, FlutterPlatformView, AVCaptureVideoDataOutputSampleBufferDelegate {
    private var _view: UIView = UIView()
    private var delegate: AppDelegate
    private var session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var boxLayer = CAShapeLayer()

    init(frame: CGRect, delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        _view.frame = frame
        setupCamera()
    }

    func view() -> UIView { return _view }

    func setupCamera() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        session.sessionPreset = .hd1280x720
        let input = try? AVCaptureDeviceInput(device: device)
        if let input = input { session.addInput(input) }
        
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cam_queue"))
        session.addOutput(output)

        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = _view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        _view.layer.addSublayer(previewLayer)

        boxLayer.frame = _view.bounds
        _view.layer.addSublayer(boxLayer)
        
        DispatchQueue.global().async { self.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let model = delegate.model else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let start = CACurrentMediaTime()
        let request = VNCoreMLRequest(model: model) { request, _ in
            let end = CACurrentMediaTime()
            let millis = Int((end - start) * 1000)
            
            let observations = request.results as? [VNRecognizedObjectObservation] ?? []
            
            DispatchQueue.main.async {
                self.drawBoxes(observations: observations)
                // Send data back to Flutter for History/UI
                let labels = observations.map { $0.labels.first?.identifier ?? "unknown" }
                self.delegate.channel?.invokeMethod("updateResults", arguments: ["time": millis, "results": labels])
            }
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([request])
    }

    func drawBoxes(observations: [VNRecognizedObjectObservation]) {
        boxLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        for observation in observations {
            let rect = VNImageRectForNormalizedRect(observation.boundingBox, Int(_view.bounds.width), Int(_view.bounds.height))
            let correctedRect = CGRect(x: rect.origin.x, y: _view.bounds.height - rect.origin.y - rect.size.height, width: rect.size.width, height: rect.size.height)
            
            let shape = CAShapeLayer()
            shape.path = UIBezierPath(rect: correctedRect).cgPath
            shape.strokeColor = UIColor.green.cgColor
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 3
            
            let text = CATextLayer()
            text.string = "\(observation.labels.first?.identifier ?? "") \(Int(observation.confidence * 100))%"
            text.fontSize = 16
            text.foregroundColor = UIColor.white.cgColor
            text.backgroundColor = UIColor.green.withAlphaComponent(0.7).cgColor
            text.frame = CGRect(x: correctedRect.origin.x, y: correctedRect.origin.y - 22, width: 150, height: 22)
            
            shape.addSublayer(text)
            boxLayer.addSublayer(shape)
        }
    }
}
