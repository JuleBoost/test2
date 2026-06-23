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
    anonKey: 'sb_publishable_j7o1byQWTqvAuvmJTlFe7w_5NmzKbc_',
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
    try { await _player.play(AssetSource('loading.mp3')); } catch (_) {}
    await Geolocator.requestPermission();
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DetectorScreen()));
  }

  @override
  void dispose() { _player.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(Icons.radar, size: 100, color: Colors.blueAccent),
        SizedBox(height: 25),
        CircularProgressIndicator(color: Colors.blueAccent),
        SizedBox(height: 15),
        Text("SYSTEM INITIALIZING...", style: TextStyle(color: Colors.white, letterSpacing: 2)),
      ])),
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
  
  String _appStatus = "Waiting for Model...";
  String _infTime = "0ms";
  String _syncFeedback = "";
  bool _isCam = false;
  bool _autoSync = false;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;
  
  // History list for the PDF
  final List<Map<String, dynamic>> _history = [];

  @override
  void initState() {
    super.initState();
    platform.setMethodCallHandler((call) async {
      if (call.method == "updateResults") {
        if (!mounted) return;
        setState(() => _infTime = "${call.arguments['time']}ms");
        
        if (_autoSync && !_isSyncing) {
          final List res = call.arguments['results'];
          if (res.isNotEmpty) {
            // Throttled to 1 SECOND as requested
            if (_lastSyncTime == null || DateTime.now().difference(_lastSyncTime!).inSeconds >= 1) {
              _syncToSupabase(res.first.toString());
            }
          }
        }
      }
    });
  }

  Future<void> _syncToSupabase(String label) async {
    _isSyncing = true;
    try {
      Position p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      List<Placemark> pm = await placemarkFromCoordinates(p.latitude, p.longitude);
      Placemark place = pm.first;
      final now = DateTime.now().toIso8601String();
      
      // Exact mapping from the image provided
      final data = {
        'anomaly': label,
        'category': 'AI Detection',
        'severity': 'Medium',
        'status': 'detected',
        'confidence': 0.95,
        'lat': p.latitude,
        'lng': p.longitude,
        'address': "${place.street}, ${place.locality}",
        'municipality_id': place.postalCode ?? "N/A",
        'municipality_name': place.locality ?? "N/A",
        'district': place.subLocality ?? "N/A",
        'governorate': place.administrativeArea ?? "N/A",
        'reports_count': 1,
        'first_seen_at': now,
        'last_seen_at': now,
        'timestamp': now,
        'updated_at': now,
      };

      // 1. ADD TO HISTORY FIRST (Ensures PDF is not empty)
      setState(() {
        _history.add(data);
        _lastSyncTime = DateTime.now();
        _syncFeedback = "DATABASE SYNCED: $label";
      });

      // 2. SEND TO SUPABASE
      await supabase.from('anomalies').insert(data);

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _syncFeedback = "");
      });
    } catch (e) {
      setState(() => _syncFeedback = "SYNC FAILED: Check Internet");
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _generateAndSharePdf() async {
    if (_history.isEmpty) {
      setState(() => _syncFeedback = "ERROR: No Data in History");
      return;
    }

    setState(() => _appStatus = "Generating PDF...");
    try {
      final pdf = pw.Document();
      pdf.addPage(pw.MultiPage(build: (pw.Context context) => [
        pw.Header(level: 0, text: "ANOMALY DETECTION LOG"),
        pw.TableHelper.fromTextArray(
          headers: ['Anomaly', 'District', 'Governorate', 'Time'],
          data: _history.map((item) => [
            item['anomaly'].toString(),
            item['district'].toString(),
            item['governorate'].toString(),
            item['timestamp'].toString().substring(11, 19)
          ]).toList(),
        ),
      ]));

      final dir = await getTemporaryDirectory();
      final file = File("${dir.path}/anomaly_report.pdf");
      await file.writeAsBytes(await pdf.save());
      
      // Share functionality
      await Share.shareXFiles([XFile(file.path)], text: 'Log Report');
      setState(() => _appStatus = "PDF Shared");
    } catch (e) {
      setState(() => _appStatus = "PDF Export Failed");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        if (_isCam) const SizedBox.expand(child: UiKitView(viewType: 'native-cam-view', creationParams: {}, creationParamsCodec: StandardMessageCodec())),
        
        // SYNC STATUS IN MIDDLE
        if (_syncFeedback.isNotEmpty)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(color: Colors.blueAccent.withOpacity(0.9), borderRadius: BorderRadius.circular(12)),
              child: Text(_syncFeedback, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),

        SafeArea(child: Column(children: [
          Container(
            color: Colors.black87, padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text("INF: $_infTime", style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                Text(_appStatus, style: const TextStyle(color: Colors.white70, fontSize: 10)),
                Row(children: [
                  const Text("AUTO-DB", style: TextStyle(color: Colors.white, fontSize: 10)),
                  Switch(value: _autoSync, activeColor: Colors.blueAccent, onChanged: (v) => setState(() => _autoSync = v)),
                ])
              ]),
            ]),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(20), color: Colors.black54,
            child: Wrap(spacing: 10, alignment: WrapAlignment.center, children: [
              ElevatedButton(onPressed: () async {
                setState(() => _appStatus = "Selecting Model...");
                FilePickerResult? r = await FilePicker.platform.pickFiles();
                if (r != null) {
                  await platform.invokeMethod('loadModel', {"path": r.files.single.path});
                  setState(() => _appStatus = "Model Loaded Successfully");
                } else {
                  setState(() => _appStatus = "Selection Cancelled");
                }
              }, child: const Text("Load Model")),
              ElevatedButton(onPressed: () {
                setState(() {
                  _isCam = !_isCam;
                  _appStatus = _isCam ? "Camera Started" : "Camera Stopped";
                });
              }, child: Text(_isCam ? "Stop Cam" : "Start Cam")),
              ElevatedButton(onPressed: _generateAndSharePdf, child: const Text("PDF & Share")),
            ]),
          )
        ])),
      ]),
    );
  }
}
