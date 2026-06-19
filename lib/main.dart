import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: DetectorScreen()));
}

class DetectorScreen extends StatefulWidget {
  const DetectorScreen({super.key});
  @override
  State<DetectorScreen> createState() => _DetectorScreenState();
}

class _DetectorScreenState extends State<DetectorScreen> {
  static const platform = MethodChannel('com.example.test2/detector');
  CameraController? _controller;
  List<dynamic> _recognitions = [];
  bool _isDetecting = false;
  String _status = "Ready";
  String _inferenceTime = "0";
  String? _modelPath;
  final List<Map<String, dynamic>> _history = [];

  Future<void> _pickModel() async {
    setState(() => _status = "Picking model...");
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) {
      setState(() => _status = "Loading CoreML...");
      final path = result.files.single.path;
      final bool success = await platform.invokeMethod('loadModel', {"path": path});
      setState(() {
        _modelPath = success ? path : null;
        _status = success ? "Model Loaded" : "Load Failed";
      });
    }
  }

  void _toggleCamera() async {
    if (_controller != null) {
      await _controller!.dispose();
      setState(() { _controller = null; _status = "Ready"; _recognitions = []; });
      return;
    }

    setState(() => _status = "Starting Camera...");
    final cameras = await availableCameras();
    _controller = CameraController(
      cameras[0], 
      ResolutionPreset.medium, // Restored to Medium
      imageFormatGroup: ImageFormatGroup.bgra8888, 
      enableAudio: false
    );
    
    await _controller!.initialize();
    _controller!.startImageStream((image) async {
      if (_isDetecting || _modelPath == null) return;
      _isDetecting = true;

      final stopwatch = Stopwatch()..start();
      try {
        final List<dynamic> results = await platform.invokeMethod('detect', {
          "buffer": image.planes[0].bytes,
          "width": image.width,
          "height": image.height,
        });
        
        setState(() {
          _recognitions = results;
          _inferenceTime = "${stopwatch.elapsedMilliseconds}ms";
          // Log results to history
          for (var res in results) {
            _history.add({'label': res['label'], 'time': DateTime.now().toIso8601String()});
          }
        });
      } finally {
        _isDetecting = false;
      }
    });
    setState(() => _status = "Detecting...");
  }

  Future<void> _saveData() async {
    setState(() => _status = "Saving...");
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/detections.json');
    await file.writeAsString(jsonEncode(_history));
    setState(() => _status = "Data Saved");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            SizedBox.expand(child: CameraPreview(_controller!)),
          CustomPaint(painter: DetectionPainter(_recognitions), child: Container()),
          SafeArea(
            child: Column(
              children: [
                Container(
                  color: Colors.black54,
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  child: Text("Status: $_status | Inference: $_inferenceTime",
                      style: const TextStyle(color: Colors.white)),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 10,
                    children: [
                      ElevatedButton(onPressed: _pickModel, child: const Text("Load Model")),
                      ElevatedButton(onPressed: _toggleCamera, child: Text(_controller == null ? "Start" : "Stop")),
                      ElevatedButton(onPressed: _saveData, child: const Text("Save")),
                    ],
                  ),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DetectionPainter extends CustomPainter {
  final List<dynamic> results;
  DetectionPainter(this.results);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 3.0..color = Colors.redAccent;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var res in results) {
      final rect = Rect.fromLTWH(
        res['x'] * size.width,
        res['y'] * size.height,
        res['w'] * size.width,
        res['h'] * size.height,
      );
      canvas.drawRect(rect, paint);

      textPainter.text = TextSpan(
        text: "${res['label']} ${(res['confidence'] * 100).toStringAsFixed(0)}%",
        style: const TextStyle(color: Colors.white, backgroundColor: Colors.redAccent, fontSize: 14),
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left, rect.top - 20));
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
