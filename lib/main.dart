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
import 'package:shared_preferences/shared_preferences.dart';

// Global client — avoids singleton so credentials can be swapped at runtime
SupabaseClient? _supabaseClient;

const _kDefaultUrl = 'https://hvygdmtjtwskklmyxgwv.supabase.co';
const _kDefaultKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imh2eWdkbXRqdHdza2tsbXl4Z3d2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE4ODc2ODEsImV4cCI6MjA5NzQ2MzY4MX0.x5us6LE2YxJO8FTlOSdd7BBFQiSW64pjDvkq_IZ1y1c';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('sb_url') ?? _kDefaultUrl;
  final key = prefs.getString('sb_key') ?? _kDefaultKey;
  _supabaseClient = SupabaseClient(url, key);

  runApp(const MaterialApp(home: SplashScreen()));
}

// ─── SPLASH ──────────────────────────────────────────────────────────────────

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
    } catch (_) {}
    await Geolocator.requestPermission();
    await Future.delayed(const Duration(seconds: 4));
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const DetectorScreen()));
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
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.radar, size: 100, color: Colors.blueAccent),
          SizedBox(height: 25),
          CircularProgressIndicator(color: Colors.blueAccent),
          SizedBox(height: 15),
          Text("SYSTEM INITIALIZING...",
              style: TextStyle(color: Colors.white, letterSpacing: 2)),
        ]),
      ),
    );
  }
}

// ─── DETECTOR ────────────────────────────────────────────────────────────────

class DetectorScreen extends StatefulWidget {
  const DetectorScreen({super.key});
  @override
  State<DetectorScreen> createState() => _DetectorScreenState();
}

class _DetectorScreenState extends State<DetectorScreen> {
  static const platform = MethodChannel('com.example.test2/detector');

  String _appStatus = "Waiting for Model...";
  String _infTime = "0ms";
  String _syncFeedback = "";
  bool _isCam = false;
  bool _autoSync = false;
  bool _isSyncing = false;
  DateTime? _lastSyncTime;

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
            if (_lastSyncTime == null ||
                DateTime.now().difference(_lastSyncTime!).inSeconds >= 1) {
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
      Position p = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.medium);
      List<Placemark> pm =
          await placemarkFromCoordinates(p.latitude, p.longitude);
      Placemark place = pm.first;
      final now = DateTime.now().toIso8601String();

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

      setState(() {
        _history.add(data);
        _lastSyncTime = DateTime.now();
        _syncFeedback = "DATABASE SYNCED: $label";
      });

      await _supabaseClient!.from('anomalies').insert(data);

      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _syncFeedback = "");
      });
    } catch (e) {
      setState(() =>
          _syncFeedback = "FAIL: ${e.toString().substring(0, 80)}");
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
          data: _history
              .map((item) => [
                    item['anomaly'].toString(),
                    item['district'].toString(),
                    item['governorate'].toString(),
                    item['timestamp'].toString().substring(11, 19),
                  ])
              .toList(),
        ),
      ]));

      final dir = await getTemporaryDirectory();
      final file = File("${dir.path}/anomaly_report.pdf");
      await file.writeAsBytes(await pdf.save());
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
        if (_isCam)
          const SizedBox.expand(
              child: UiKitView(
                  viewType: 'native-cam-view',
                  creationParams: {},
                  creationParamsCodec: StandardMessageCodec())),

        if (_syncFeedback.isNotEmpty)
          Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12)),
              child: Text(_syncFeedback,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ),

        SafeArea(
          child: Column(children: [
            // TOP BAR
            Container(
              color: Colors.black87,
              padding: const EdgeInsets.all(12),
              child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("INF: $_infTime",
                        style: const TextStyle(
                            color: Colors.greenAccent, fontSize: 12)),
                    Text(_appStatus,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 10)),
                    Row(children: [
                      const Text("AUTO-DB",
                          style:
                              TextStyle(color: Colors.white, fontSize: 10)),
                      Switch(
                          value: _autoSync,
                          activeColor: Colors.blueAccent,
                          onChanged: (v) =>
                              setState(() => _autoSync = v)),
                      // ← Settings icon
                      IconButton(
                        icon: const Icon(Icons.settings,
                            color: Colors.white70, size: 20),
                        onPressed: () async {
                          await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const SettingsScreen()));
                          // Rebuild in case credentials changed
                          if (mounted) setState(() {});
                        },
                      ),
                    ]),
                  ]),
            ),

            const Spacer(),

            // BOTTOM BUTTONS
            Container(
              padding: const EdgeInsets.all(20),
              color: Colors.black54,
              child: Wrap(
                  spacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton(
                        onPressed: () async {
                          setState(() => _appStatus = "Selecting Model...");
                          FilePickerResult? r =
                              await FilePicker.platform.pickFiles();
                          if (r != null) {
                            await platform.invokeMethod(
                                'loadModel', {"path": r.files.single.path});
                            setState(
                                () => _appStatus = "Model Loaded Successfully");
                          } else {
                            setState(() => _appStatus = "Selection Cancelled");
                          }
                        },
                        child: const Text("Load Model")),
                    ElevatedButton(
                        onPressed: () {
                          setState(() {
                            _isCam = !_isCam;
                            _appStatus =
                                _isCam ? "Camera Started" : "Camera Stopped";
                          });
                        },
                        child: Text(_isCam ? "Stop Cam" : "Start Cam")),
                    ElevatedButton(
                        onPressed: _generateAndSharePdf,
                        child: const Text("PDF & Share")),
                  ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ─── SETTINGS ────────────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  String _statusMsg = "";
  bool _isTesting = false;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    _urlController.text = prefs.getString('sb_url') ?? _kDefaultUrl;
    _keyController.text = prefs.getString('sb_key') ?? _kDefaultKey;
    setState(() {});
  }

  Future<void> _save() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _statusMsg = "URL and key cannot be empty.");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sb_url', url);
    await prefs.setString('sb_key', key);
    // Swap the global client immediately — no restart needed
    _supabaseClient = SupabaseClient(url, key);
    setState(() => _statusMsg = "✓ Saved & applied.");
  }

  Future<void> _testConnection() async {
    final url = _urlController.text.trim();
    final key = _keyController.text.trim();
    if (url.isEmpty || key.isEmpty) {
      setState(() => _statusMsg = "Fill in URL and key first.");
      return;
    }
    setState(() {
      _isTesting = true;
      _statusMsg = "Testing...";
    });
    try {
      final testClient = SupabaseClient(url, key);
      await testClient.from('anomalies').select('id').limit(1);
      setState(() => _statusMsg = "✓ Connection successful!");
    } catch (e) {
      final msg = e.toString();
      setState(() =>
          _statusMsg = "✗ ${msg.length > 80 ? msg.substring(0, 80) : msg}");
    } finally {
      setState(() => _isTesting = false);
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: const Text("Database Settings",
            style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text("Supabase URL",
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _urlController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: "https://xxxx.supabase.co",
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white10,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 20),
          const Text("Anon / Publishable Key",
              style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          TextField(
            controller: _keyController,
            style: const TextStyle(color: Colors.white),
            maxLines: 3,
            decoration: InputDecoration(
              hintText: "eyJhbGci...",
              hintStyle: const TextStyle(color: Colors.white38),
              filled: true,
              fillColor: Colors.white10,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: _isTesting ? null : _testConnection,
                icon: _isTesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.wifi_tethering),
                label: const Text("Test Connection"),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: _save,
                icon: const Icon(Icons.save),
                label: const Text("Save"),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          if (_statusMsg.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _statusMsg.startsWith("✓")
                    ? Colors.green.withOpacity(0.2)
                    : Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: _statusMsg.startsWith("✓")
                        ? Colors.green
                        : Colors.redAccent),
              ),
              child: Text(_statusMsg,
                  style: TextStyle(
                      color: _statusMsg.startsWith("✓")
                          ? Colors.greenAccent
                          : Colors.redAccent)),
            ),
        ]),
      ),
    );
  }
}
