import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';

void main() => runApp(const MaterialApp(home: NativeDetectorScreen()));

class NativeDetectorScreen extends StatefulWidget {
  const NativeDetectorScreen({super.key});
  @override
  State<NativeDetectorScreen> createState() => _NativeDetectorScreenState();
}

class _NativeDetectorScreenState extends State<NativeDetectorScreen> {
  static const platform = MethodChannel('com.example.test2/detector');
  String _status = "Ready";
  String _inferenceTime = "0ms";
  bool _isCameraRunning = false;
  List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    // Listen for data coming from Swift (Inference time and detections)
    platform.setMethodCallHandler((call) async {
      if (call.method == "updateResults") {
        setState(() {
          _inferenceTime = "${call.arguments['time']}ms";
          final List results = call.arguments['results'];
          for (var res in results) {
            _history.add({'label': res, 'time': DateTime.now().toIso8601String()});
          }
        });
      }
    });
  }

  Future<void> _pickModel() async {
    setState(() => _status = "Picking model...");
    FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result != null) {
      final success = await platform.invokeMethod('loadModel', {"path": result.files.single.path});
      setState(() => _status = success ? "Model Loaded" : "Load Failed");
    }
  }

  void _toggleCamera() {
    setState(() {
      _isCameraRunning = !_isCameraRunning;
      _status = _isCameraRunning ? "Detecting..." : "Camera Stopped";
    });
  }

  Future<void> _saveData() async {
    setState(() => _status = "Saving...");
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/detections.json');
    await file.writeAsString(jsonEncode(_history));
    setState(() => _status = "Saved: ${_history.length} items");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_isCameraRunning)
            const UiKitView(
              viewType: 'native-cam-view',
              creationParams: {},
              creationParamsCodec: StandardMessageCodec(),
            ),
          SafeArea(
            child: Column(
              children: [
                Container(
                  color: Colors.black54, width: double.infinity, padding: const EdgeInsets.all(8),
                  child: Text("Status: $_status | Inference: $_inferenceTime", 
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(
                    spacing: 10,
                    children: [
                      ElevatedButton(onPressed: _pickModel, child: const Text("Load Model")),
                      ElevatedButton(onPressed: _toggleCamera, child: Text(_isCameraRunning ? "Stop" : "Start")),
                      ElevatedButton(onPressed: _saveData, child: const Text("Save JSON")),
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
