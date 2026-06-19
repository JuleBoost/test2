import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://hvygdmtjtwskklmyxgwv.supabase.co',
    anonKey: 'sb_publishable_OahMLpySUkDoVhYGQGKLsQ_H6LGcnx5',
  );
  runApp(const MaterialApp(home: SplashScreen()));
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final AudioPlayer _player = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  Future<void> _initApp() async {
    try {
      await _player.play(AssetSource('loading.mp3'));
    } catch (e) {
      print("Audio play error: $e");
    }
    
    await Future.delayed(const Duration(seconds: 4));
    await Geolocator.requestPermission();
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DetectorScreen()));
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.security, size: 100, color: Colors.blueAccent),
            SizedBox(height: 20),
            CircularProgressIndicator(color: Colors.blueAccent),
            SizedBox(height: 10),
            Text("SYSTEM INITIALIZING...", style: TextStyle(color: Colors.white, letterSpacing: 2))
          ],
        ),
      ),
    );
  }
}

class DetectorScreen extends StatefulWidget {
  const DetectorScreen({super.key});
  @override
  State<DetectorScreen> createState() => _DetectorScreenState();
}

class _DetectorScreenState extends State<DetectorScreen> {
  static const platform = MethodChannel('com.example.test2/detector');
  final supabase = Supabase.instance.client;
  String _status = "Ready";
  String _infTime = "0ms";
  bool _isCam = false;
  bool _autoSync = false;
  final List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler((call) async {
      if (call.method == "updateResults") {
        setState(() => _infTime = "${call.arguments['time']}ms");
        if (_autoSync) {
          final List res = call.arguments['results'];
          if (res.isNotEmpty) _syncToSupabase(res.first.toString());
        }
      }
    });
  }

  Future<void> _syncToSupabase(String label) async {
    try {
      Position p = await Geolocator.getCurrentPosition();
      List<Placemark> pm = await placemarkFromCoordinates(p.latitude, p.longitude);
      String addr = "${pm.first.street}, ${pm.first.locality}";
      
      final data = {
        'anomaly': label,
        'confidence': 0.95,
        'lat': p.latitude,
        'lng': p.longitude,
        'address': addr,
        'timestamp': DateTime.now().toIso8601String(),
      };
      
      _history.add(data);
      await supabase.from('detections').insert(data);
    } catch (e) { print(e); }
  }

  Future<void> _generatePdf() async {
    final pdf = pw.Document();
    pdf.addPage(pw.MultiPage(build: (pw.Context context) => [
      pw.Header(level: 0, text: "Anomaly Detection Report"),
      pw.TableHelper.fromTextArray(
        data: <List<String>>[
          ['Anomaly', 'Address', 'Lat', 'Lng', 'Time'],
          ..._history.map((e) => [e['anomaly'], e['address'], e['lat'].toString(), e['lng'].toString(), e['timestamp']])
        ],
      ),
    ]));
    
    final dir = await getTemporaryDirectory();
    final file = File("${dir.path}/report.pdf");
    await file.writeAsBytes(await pdf.save());
    await Share.shareXFiles([XFile(file.path)], text: 'Detection PDF Report');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isCam) const SizedBox.expand(child: UiKitView(viewType: 'native-cam-view', creationParams: {}, creationParamsCodec: StandardMessageCodec())),
          SafeArea(
            child: Column(
              children: [
                Container(
                  color: Colors.black54, padding: const EdgeInsets.all(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Status: $_status | $_infTime", style: const TextStyle(color: Colors.white)),
                      Row(children: [
                        const Text("AUTO-DB", style: TextStyle(color: Colors.white, fontSize: 10)),
                        Switch(value: _autoSync, onChanged: (v) => setState(() => _autoSync = v)),
                      ])
                    ],
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Wrap(spacing: 10, children: [
                    ElevatedButton(onPressed: () async {
                      FilePickerResult? r = await FilePicker.platform.pickFiles();
                      if (r != null) await platform.invokeMethod('loadModel', {"path": r.files.single.path});
                      setState(() => _status = "Model Loaded");
                    }, child: const Text("Load Model")),
                    ElevatedButton(onPressed: () => setState(() => _isCam = !_isCam), child: Text(_isCam ? "Stop" : "Start")),
                    ElevatedButton(onPressed: _generatePdf, child: const Text("PDF & Share")),
                  ]),
                )
              ],
            ),
          ),
        ],
      ),
    );
  }
}
