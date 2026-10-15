import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';

// Run with:  flutter run --dart-define=GEMINI_API_KEY=your_key
// (Keeps the key out of source control. For production, proxy via your own
// backend instead of shipping a key inside the app.)
const String kGeminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
const String kGeminiModel = 'gemini-2.5-flash';
const String kBarrettUrl = 'https://calc.apacrs.org/barrett_universal2105/';

const String kExtractionPrompt =
    'Extract Axial Length, K1, K2, Anterior Chamber Depth, and Lens Thickness. '
    'Return ONLY valid JSON with keys: AL, K1, K2, ACD, LT.';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    _cameras = await availableCameras();
  } catch (_) {
    _cameras = [];
  }
  runApp(const BiometryApp());
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

class BiometryApp extends StatelessWidget {
  const BiometryApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Biometry to Barrett',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class BiometryData {
  final double? al;
  final double? k1;
  final double? k2;
  final double? acd;
  final double? lt;

  const BiometryData({this.al, this.k1, this.k2, this.acd, this.lt});

  factory BiometryData.fromJson(Map<String, dynamic> json) {
    return BiometryData(
      al: _toDouble(json['AL']),
      k1: _toDouble(json['K1']),
      k2: _toDouble(json['K2']),
      acd: _toDouble(json['ACD']),
      lt: _toDouble(json['LT']),
    );
  }

  /// Tolerates numbers or strings such as "23.45 mm" or "43,25".
  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final cleaned = v.toString().replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), '');
    return double.tryParse(cleaned);
  }

  @override
  String toString() => 'AL=$al, K1=$k1, K2=$k2, ACD=$acd, LT=$lt';
}

// ---------------------------------------------------------------------------
// Vision service (Gemini)
// ---------------------------------------------------------------------------

class VisionService {
  Future<BiometryData> extractBiometry(Uint8List imageBytes) async {
    if (kGeminiApiKey.isEmpty) {
      throw Exception('Missing API key. Run with --dart-define=GEMINI_API_KEY=...');
    }

    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$kGeminiModel:generateContent',
    );

    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': kExtractionPrompt},
            {
              'inline_data': {
                'mime_type': 'image/jpeg',
                'data': base64Encode(imageBytes),
              }
            },
          ],
        }
      ],
      'generationConfig': {
        'temperature': 0,
        'responseMimeType': 'application/json',
      },
    });

    final response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': kGeminiApiKey,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode != 200) {
      throw Exception('Vision API error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'] as String?;
    if (text == null) throw Exception('Vision API returned no text.');

    return BiometryData.fromJson(_parseJson(text));
  }

  /// Strips ```json fences if the model adds them anyway.
  Map<String, dynamic> _parseJson(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'```json|```'), '').trim();
    return jsonDecode(cleaned) as Map<String, dynamic>;
  }
}

// ---------------------------------------------------------------------------
// JavaScript injection
// ---------------------------------------------------------------------------

class BarrettInjector {
  /// Candidate IDs per field. The first one found on the page is used.
  static const Map<String, List<String>> _ids = {
    'AL': ['MainContent_Axlength'],
    'K1': ['MainContent_MeasuredK1'],
    'K2': ['MainContent_MeasuredK2'],
    'ACD': ['MainContent_OpticalACD'],
    'LT': ['MainContent_LensThickness', 'MainContent_LensThick', 'MainContent_LT'],
    'TARGET': [
      'MainContent_RefractionR',
      'MainContent_Refraction',
      'MainContent_TargetRefraction',
    ],
  };

  static String buildScript(BiometryData d) {
    final values = <String, String>{
      if (d.al != null) 'AL': d.al.toString(),
      if (d.k1 != null) 'K1': d.k1.toString(),
      if (d.k2 != null) 'K2': d.k2.toString(),
      if (d.acd != null) 'ACD': d.acd.toString(),
      if (d.lt != null) 'LT': d.lt.toString(),
      'TARGET': '0', // hardcoded target refraction
    };

    // jsonEncode produces safely escaped JS literals.
    final idsJs = jsonEncode(_ids);
    final valuesJs = jsonEncode(values);

    return '''
(function () {
  var ids = $idsJs;
  var values = $valuesJs;
  var report = { filled: [], missing: [] };

  function setValue(el, v) {
    el.focus();
    el.value = v;
    el.dispatchEvent(new Event('input',  { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
    el.blur();
  }

  Object.keys(values).forEach(function (key) {
    var found = false;
    for (var i = 0; i < ids[key].length; i++) {
      var el = document.getElementById(ids[key][i]);
      if (el) {
        setValue(el, values[key]);
        report.filled.push(key + ' -> ' + ids[key][i]);
        found = true;
        break;
      }
    }
    if (!found) report.missing.push(key);
  });

  return JSON.stringify(report);
})();
''';
  }
}

// ---------------------------------------------------------------------------
// Home screen: camera preview + scan
// ---------------------------------------------------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final VisionService _vision = VisionService();
  CameraController? _controller;
  bool _processing = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    if (_cameras.isEmpty) {
      setState(() => _cameraError = 'No camera available.');
      return;
    }
    final controller = CameraController(
      _cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Camera error: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _processing) return;

    setState(() => _processing = true);
    try {
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      final data = await _vision.extractBiometry(bytes);

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => WebViewScreen(data: data)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Scan failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(title: const Text('Biometry Scanner')),
      body: Stack(
        children: [
          Positioned.fill(
            child: _cameraError != null
                ? Center(child: Text(_cameraError!))
                : (controller == null || !controller.value.isInitialized)
                    ? const Center(child: CircularProgressIndicator())
                    : CameraPreview(controller),
          ),
          if (_processing)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text(
                        'Extracting values...',
                        style: TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: _processing ? null : _scan,
            icon: const Icon(Icons.document_scanner),
            label: const Text('Scan Biometry'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// WebView screen: Barrett calculator + injection
// ---------------------------------------------------------------------------

class WebViewScreen extends StatefulWidget {
  final BiometryData data;
  const WebViewScreen({super.key, required this.data});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _web;
  bool _pageLoaded = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _pageLoaded = true);
          },
        ),
      )
      ..loadRequest(Uri.parse(kBarrettUrl));
  }

  Future<void> _pasteVariables() async {
    final script = BarrettInjector.buildScript(widget.data);
    String message;

    try {
      final result = await _web.runJavaScriptReturningResult(script);
      message = _summarize(result);
    } catch (e) {
      message = 'Injection failed: $e';
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }

  /// Android returns the JS string JSON-quoted; iOS may not. Handle both.
  String _summarize(Object result) {
    try {
      var s = result.toString();
      if (s.startsWith('"')) s = jsonDecode(s) as String;
      final report = jsonDecode(s) as Map<String, dynamic>;
      final missing = (report['missing'] as List).cast<String>();
      if (missing.isEmpty) return 'All fields filled. Please verify before calculating.';
      return 'Filled, but element IDs not found for: ${missing.join(', ')}';
    } catch (_) {
      return 'Injection ran. Please verify the fields.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Barrett Universal II'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _web.reload(),
          ),
        ],
      ),
      body: WebViewWidget(controller: _web),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _pageLoaded ? _pasteVariables : null,
        icon: const Icon(Icons.paste),
        label: const Text('Paste Variables'),
      ),
    );
  }
}
