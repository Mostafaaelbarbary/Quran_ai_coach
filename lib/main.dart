import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
void main() {
  runApp(const QuranAIApp());
}

class QuranAIApp extends StatelessWidget {
  const QuranAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Quran AI Coach',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const QuranAgentDashboard(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class QuranAgentDashboard extends StatefulWidget {
  const QuranAgentDashboard({super.key});

  @override
  State<QuranAgentDashboard> createState() => _QuranAgentDashboardState();
}

class _QuranAgentDashboardState extends State<QuranAgentDashboard> {
  // Controllers and Services
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final AudioPlayer _player = AudioPlayer();
  final TextEditingController _textController = TextEditingController();

  // State Variables
  bool _isRecording = false;
  bool _isAnalyzing = false;
  bool _isPlayingReference = false;
  bool _isAsking = false;

  String _statusMessage = "Assalamu Alaikum! I am your AI Quran Assistant.";

  // Data from Backend
  String? _referenceAudioUrl;
  Map<String, dynamic>? _lastResult;

  // ✅ Base URL (fixes localhost problem)
  // Android Emulator -> 10.0.2.2
  // iOS Simulator -> 127.0.0.1
  // Real device -> your PC IP
  String get _baseUrl {
  if (kIsWeb) {
    // If backend runs on SAME machine as browser:
    return "http://localhost:8000";

    // If backend runs on another machine, use its LAN IP:
    // return "http://192.168.1.5:8000";
  }

  // Mobile:
  // Android emulator:
  // return "http://10.0.2.2:8000";

  // iOS simulator:
  // return "http://127.0.0.1:8000";

  // Best simple default for mobile testing:
  return "http://10.0.2.2:8000";
}
  @override
  void initState() {
    super.initState();
    _initRecorder();

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        setState(() => _isPlayingReference = false);
      }
    });
  }

  Future<void> _initRecorder() async {
    await _recorder.openRecorder();
  }

  @override
  void dispose() {
    _recorder.closeRecorder();
    _player.dispose();
    _textController.dispose();
    super.dispose();
  }

  // -------------------------
  // Recitation (unchanged)
  // -------------------------

  Future<void> _startRecording() async {
    try {
      await _recorder.startRecorder(
        toFile: 'recitation.webm',
        codec: Codec.opusWebM,
      );
      setState(() {
        _isRecording = true;
        _lastResult = null;
        _referenceAudioUrl = null;
        _statusMessage = "Listening to your recitation...";
      });
    } catch (e) {
      _showError("Could not start microphone.");
    }
  }

  Future<void> _stopRecording() async {
    final path = await _recorder.stopRecorder();
    setState(() {
      _isRecording = false;
      _isAnalyzing = true;
    });
    if (path != null) await _uploadAndAnalyze(path);
  }

  Future<void> _uploadAndAnalyze(String blobUrl) async {
    try {
      final uri = Uri.parse("$_baseUrl/analyze_recitation");
      final request = http.MultipartRequest("POST", uri);

      // NOTE: keeping your approach as-is
      final audioFile = await http.get(Uri.parse(blobUrl));
      request.files.add(http.MultipartFile.fromBytes(
        "audio",
        audioFile.bodyBytes,
        filename: "recitation.webm",
      ));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _lastResult = data;
          _referenceAudioUrl = data["reference_audio_url"];
          _isAnalyzing = false;
          _statusMessage = "Analysis Complete";
        });
      } else {
        throw Exception("Server Error: ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        _isAnalyzing = false;
        _statusMessage = "Connection Error: Is the backend running? ($_baseUrl)";
      });
    }
  }

  Future<void> _toggleReferenceAudio() async {
    if (_referenceAudioUrl == null) return;

    if (_isPlayingReference) {
      await _player.stop();
      setState(() => _isPlayingReference = false);
    } else {
      try {
        setState(() => _isPlayingReference = true);
        await _player.setUrl(_referenceAudioUrl!);
        await _player.play();
      } catch (e) {
        setState(() => _isPlayingReference = false);
        _showError("Could not play reference audio.");
      }
    }
  }

  // -------------------------
  // ✅ Chat -> Backend /ask
  // -------------------------

  Future<void> _handleTextQuery(String text) async {
    final raw = text.trim();
    if (raw.isEmpty) return;

    setState(() {
      _isAsking = true;
      _statusMessage = "Thinking...";
    });

    try {
      final q = Uri.encodeComponent(raw); // ✅ supports Arabic safely
      final uri = Uri.parse("$_baseUrl/ask?q=$q&debug=true");

      final res = await http.get(uri);

      if (res.statusCode != 200) {
        setState(() {
          _isAsking = false;
          _statusMessage = "Server error (${res.statusCode}).";
        });
        return;
      }

      final data = jsonDecode(res.body);
      final answer = (data["answer"] ?? "").toString();

      setState(() {
        _isAsking = false;
        _statusMessage = answer.isNotEmpty ? answer : "No answer returned.";
      });

      // Optional: print debug to console
      // print(data);

    } catch (e) {
      setState(() {
        _isAsking = false;
        _statusMessage = "Chat connection error. Check backend URL: $_baseUrl";
      });
    } finally {
      _textController.clear();
    }
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // -------------------------
  // UI
  // -------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Quran AI Coach"),
        centerTitle: true,
        backgroundColor: Colors.teal.shade700,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          children: [
            _buildStatusCard(),
            const SizedBox(height: 20),
            if (_lastResult != null) _buildResultDetails(),
            const Spacer(),
            _buildChatInput(),
            const SizedBox(height: 20),
            _buildActionButtons(),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _isRecording ? Colors.red.shade50 : Colors.teal.shade50,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(
          color: _isRecording ? Colors.red.shade200 : Colors.teal.shade200,
        ),
      ),
      child: Column(
        children: [
          if (_isAnalyzing || _isAsking) const CircularProgressIndicator(),
          if (!_isAnalyzing && !_isAsking)
            Text(
              _statusMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: _isRecording ? Colors.red.shade900 : Colors.teal.shade900,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            "Backend: $_baseUrl",
            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
          )
        ],
      ),
    );
  }

  Widget _buildResultDetails() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Score: ${_lastResult!['score']}/100",
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Colors.teal,
              ),
            ),
            const Divider(),
            Text("Expected: ${_lastResult!['expected_text']}"),
            const SizedBox(height: 8),
            Text(
              "Detected: ${_lastResult!['recognized_text']}",
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 16),
            Center(
              child: ElevatedButton.icon(
                onPressed: _toggleReferenceAudio,
                icon: Icon(_isPlayingReference ? Icons.stop : Icons.volume_up),
                label: Text(
                    _isPlayingReference ? "Stop" : "Listen to Correct Version"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber.shade100,
                ),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildChatInput() {
    return TextField(
      controller: _textController,
      decoration: InputDecoration(
        hintText: "Ask a question (Arabic or English)...",
        filled: true,
        fillColor: Colors.grey.shade100,
        suffixIcon: IconButton(
          icon: const Icon(Icons.send, color: Colors.teal),
          onPressed: () => _handleTextQuery(_textController.text),
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(30),
          borderSide: BorderSide.none,
        ),
      ),
      onSubmitted: _handleTextQuery,
    );
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _micButton(
          label: "Start",
          icon: Icons.mic,
          color: Colors.teal,
          isActive: !_isRecording && !_isAnalyzing,
          onTap: _startRecording,
        ),
        _micButton(
          label: "Stop",
          icon: Icons.stop,
          color: Colors.redAccent,
          isActive: _isRecording,
          onTap: _stopRecording,
        ),
      ],
    );
  }

  Widget _micButton({
    required String label,
    required IconData icon,
    required Color color,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return ElevatedButton.icon(
      onPressed: isActive ? onTap : null,
      icon: Icon(icon),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.grey.shade300,
        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
      ),
    );
  }
}