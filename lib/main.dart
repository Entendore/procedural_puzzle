import 'dart:math';
import 'dart:typed_data';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:provider/provider.dart';

void main() {
  // Lock app to Portrait orientation for a consistent puzzle experience
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]).then((_) {
    runApp(const SlidePuzzleApp());
  });
}

class SlidePuzzleApp extends StatelessWidget {
  const SlidePuzzleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Procedural Slide Puzzle',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.tealAccent,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ==========================================
// 1. STATE MANAGEMENT (Provider/ChangeNotifier)
// ==========================================
enum MoveDirection { left, right, up, down, none }

class PuzzleGameController extends ChangeNotifier with WidgetsBindingObserver {
  final int gridSize;
  final bool hapticsEnabled;
  final bool soundEnabled;
  final AudioPlayer _audioPlayer;

  late List<int> _state;
  bool _isSolved = false;
  bool _isPeeking = false;
  bool _isPaused = false;
  int _moves = 0;
  int _seconds = 0;
  Timer? _timer;
  List<List<int>> _history = []; // For Undo feature

  late final List<Uint8List> _slideSounds;
  late final Uint8List _winSoundBytes;

  int get n => gridSize;
  int get emptyTile => n * n - 1;
  List<int> get state => _state;
  bool get isSolved => _isSolved;
  bool get isPeeking => _isPeeking;
  bool get isPaused => _isPaused;
  int get moves => _moves;
  String get formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return '\$m:\$s';
  }

  PuzzleGameController({
    required this.gridSize,
    required this.hapticsEnabled,
    required this.soundEnabled,
    required AudioPlayer audioPlayer,
  }) : _audioPlayer = audioPlayer {
    _slideSounds = [
      _generateWav([523.25], 60),
      _generateWav([587.33], 60),
      _generateWav([659.25], 60),
      _generateWav([783.99], 60),
    ];
    _winSoundBytes = _generateWav([523.25, 659.25, 783.99, 1046.50], 600);

    WidgetsBinding.instance.addObserver(this);
    _shufflePuzzle();
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      if (!_isSolved) {
        _timer?.cancel();
        _isPaused = true;
        notifyListeners();
      }
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isSolved && !_isPeeking && !_isPaused) {
        _seconds++;
        notifyListeners();
      }
    });
  }

  void togglePeek(bool isPeeking) {
    _isPeeking = isPeeking;
    notifyListeners();
  }

  void resumeGame() {
    _isPaused = false;
    notifyListeners();
    _startTimer();
  }

  void _shufflePuzzle() {
    _state = List.generate(n * n, (index) => index);
    final random = Random();
    int emptyIndex = emptyTile;
    
    int moves = n * n * 20; 
    for (int i = 0; i < moves; i++) {
      final neighbors = _getNeighbors(emptyIndex);
      final swapWith = neighbors[random.nextInt(neighbors.length)];
      _state[emptyIndex] = _state[swapWith];
      _state[swapWith] = emptyTile;
      emptyIndex = swapWith;
    }
    
    _moves = 0;
    _seconds = 0;
    _isSolved = false;
    _history.clear();
  }

  void reshuffle() {
    _timer?.cancel();
    _shufflePuzzle();
    _startTimer();
    notifyListeners();
  }

  List<int> _getNeighbors(int index) {
    int x = index % n;
    int y = index ~/ n;
    List<int> neighbors = [];
    if (x > 0) neighbors.add(index - 1);
    if (x < n - 1) neighbors.add(index + 1);
    if (y > 0) neighbors.add(index - n);
    if (y < n - 1) neighbors.add(index + n);
    return neighbors;
  }

  MoveDirection getMoveDirection(int tileValue) {
    int tileIndex = _state.indexOf(tileValue);
    int emptyIndex = _state.indexOf(emptyTile);

    int tx = tileIndex % n;
    int ty = tileIndex ~/ n;
    int ex = emptyIndex % n;
    int ey = emptyIndex ~/ n;

    if (tx == ex) {
      if (ty - ey == 1) return MoveDirection.up;
      if (ty - ey == -1) return MoveDirection.down;
    }
    if (ty == ey) {
      if (tx - ex == 1) return MoveDirection.left;
      if (tx - ex == -1) return MoveDirection.right;
    }
    return MoveDirection.none;
  }

  Future<void> _playSlideSound() async {
    if (!soundEnabled) return;
    try {
      final soundBytes = _slideSounds[Random().nextInt(_slideSounds.length)];
      await _audioPlayer.play(BytesSource(soundBytes));
    } catch (e) {
      debugPrint("Error playing sound: \$e");
    }
  }

  void tryMove(int tileValue) {
    if (_isSolved || _isPaused) return;

    int tileIndex = _state.indexOf(tileValue);
    int emptyIndex = _state.indexOf(emptyTile);

    if (_getNeighbors(emptyIndex).contains(tileIndex)) {
      if (hapticsEnabled) HapticFeedback.lightImpact();
      _playSlideSound();
      
      _history.add(List.from(_state)); // Save state for undo
      
      // Create a new list to trigger Provider updates cleanly
      _state = [..._state]; 
      _state[emptyIndex] = tileValue;
      _state[tileIndex] = emptyTile;
      _moves++;
      notifyListeners();

      if (_isWinCondition()) {
        _timer?.cancel();
        _isSolved = true;
        if (soundEnabled) _audioPlayer.play(BytesSource(_winSoundBytes));
        if (hapticsEnabled) {
          HapticFeedback.heavyImpact();
          Future.delayed(const Duration(milliseconds: 200), () => HapticFeedback.mediumImpact());
        }
        notifyListeners();
      }
    }
  }

  void undoMove() {
    if (_history.isEmpty || _isSolved || _isPaused) return;
    
    if (hapticsEnabled) HapticFeedback.selectionClick();
    _state = _history.removeLast();
    _moves = _moves > 0 ? _moves - 1 : 0;
    notifyListeners();
  }

  bool _isWinCondition() {
    for (int i = 0; i < emptyTile; i++) {
      if (_state[i] != i) return false;
    }
    return true;
  }

  Future<Map<String, dynamic>> saveAndGetScore() async {
    final prefs = await SharedPreferences.getInstance();
    String newScore = '\$moves moves | \$formattedTime';
    String key = 'best_\$n';
    String? oldScore = prefs.getString(key);

    bool isNewBest = false;
    if (oldScore == null || moves < int.parse(oldScore.split(' ')[0])) {
      await prefs.setString(key, newScore);
      isNewBest = true;
    }
    return {
      'isNewBest': isNewBest,
      'moves': moves,
      'time': formattedTime,
    };
  }
}

// ==========================================
// 2. PROCEDURAL GENERATORS
// ==========================================
Uint8List _generateWav(List<double> frequencies, int durationMs) {
  int sampleRate = 44100;
  int numSamples = (sampleRate * durationMs / 1000).round();
  int dataSize = numSamples * 2;
  int totalSize = 44 + dataSize;

  ByteData byteData = ByteData(totalSize);
  
  byteData.setUint8(0, 0x52); byteData.setUint8(1, 0x49); byteData.setUint8(2, 0x46); byteData.setUint8(3, 0x46);
  byteData.setUint32(4, totalSize - 8, Endian.little);
  byteData.setUint8(8, 0x57); byteData.setUint8(9, 0x41); byteData.setUint8(10, 0x56); byteData.setUint8(11, 0x45);
  
  byteData.setUint8(12, 0x66); byteData.setUint8(13, 0x6d); byteData.setUint8(14, 0x74); byteData.setUint8(15, 0x20);
  byteData.setUint32(16, 16, Endian.little);
  byteData.setUint16(20, 1, Endian.little);
  byteData.setUint16(22, 1, Endian.little);
  byteData.setUint32(24, sampleRate, Endian.little);
  byteData.setUint32(28, sampleRate * 2, Endian.little);
  byteData.setUint16(32, 2, Endian.little);
  byteData.setUint16(34, 16, Endian.little);
  
  byteData.setUint8(36, 0x64); byteData.setUint8(37, 0x61); byteData.setUint8(38, 0x74); byteData.setUint8(39, 0x61);
  byteData.setUint32(40, dataSize, Endian.little);

  for (int i = 0; i < numSamples; i++) {
    double t = i / sampleRate;
    double sample = 0;
    for (double freq in frequencies) {
      sample += sin(2 * pi * freq * t);
    }
    sample = (sample / frequencies.length) * 0.5;
    
    double fadeSamples = sampleRate * 0.01; 
    if (i < fadeSamples) sample *= (i / fadeSamples);
    if (i > numSamples - fadeSamples) sample *= ((numSamples - i) / fadeSamples);
    
    int value = (sample * 32767).toInt();
    byteData.setInt16(44 + i * 2, value, Endian.little);
  }

  return byteData.buffer.asUint8List();
}

Future<ImageProvider> _generateImage(int seed) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final random = Random(seed);
  
  final bgColors = [Colors.amber.shade50, Colors.blueGrey.shade50, Colors.red.shade50, Colors.teal.shade50];
  canvas.drawRect(Rect.fromLTWH(0, 0, 400, 400), Paint()..color = bgColors[random.nextInt(bgColors.length)]);

  final palette = [
    Colors.red.shade900, Colors.blue.shade900, Colors.yellow.shade700, 
    Colors.black, Colors.orange.shade800, Colors.teal.shade800
  ];

  for (int i = 0; i < random.nextInt(3) + 4; i++) {
    final paint = Paint()..color = palette[random.nextInt(palette.length)];
    final dx = random.nextDouble() * 400;
    final dy = random.nextDouble() * 400;
    final size = random.nextDouble() * 150 + 100;

    int shapeType = random.nextInt(3);
    if (shapeType == 0) {
      canvas.drawCircle(Offset(dx, dy), size / 2, paint);
    } else if (shapeType == 1) {
      canvas.drawRect(Rect.fromLTWH(dx - size/2, dy - size/2, size, size * (random.nextDouble() + 0.5)), paint);
    } else {
      Path path = Path();
      path.moveTo(dx, dy - size/2);
      path.lineTo(dx - size/2, dy + size/2);
      path.lineTo(dx + size/2, dy + size/2);
      path.close();
      canvas.drawPath(path, paint);
    }
  }

  for (int i = 0; i < 3; i++) {
    final paint = Paint()
      ..color = Colors.black87
      ..strokeWidth = random.nextDouble() * 10 + 4;
    canvas.drawLine(
      Offset(random.nextDouble() * 400, random.nextDouble() * 400),
      Offset(random.nextDouble() * 400, random.nextDouble() * 400),
      paint
    );
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(400, 400);
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  return MemoryImage(byteData!.buffer.asUint8List());
}

// ==========================================
// 3. UI WIDGETS
// ==========================================
class GlassCard extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsets padding;
  final Color? borderColor;

  const GlassCard({
    super.key, 
    required this.child, 
    this.borderRadius = 20.0, 
    this.padding = const EdgeInsets.all(16.0),
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 8.0, sigmaY: 8.0),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            border: Border.all(color: borderColor ?? Colors.white.withOpacity(0.15), width: 1.5),
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _SettingToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingToggle({required this.label, required this.icon, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.grey.shade400, size: 18),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
            ],
          ),
          Switch(
            value: value,
            activeColor: Colors.tealAccent,
            inactiveThumbColor: Colors.grey.shade700,
            inactiveTrackColor: Colors.grey.shade800,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 4. HOME SCREEN
// ==========================================
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ImagePicker _picker = ImagePicker();
  int _gridSize = 3;
  Map<int, String> _bestScores = {};
  List<ImageProvider> _generatedImages = [];
  ImageProvider? _selectedImage;

  bool _showNumbers = false;
  bool _hapticsEnabled = true;
  bool _soundEnabled = true;

  @override
  void initState() {
    super.initState();
    _loadData();
    _generateNewPhotos();
  }

  Future<void> _generateNewPhotos() async {
    List<ImageProvider> imgs = [];
    for (int i = 0; i < 6; i++) {
      imgs.add(await _generateImage(Random().nextInt(100000)));
    }
    setState(() {
      _generatedImages = imgs;
      _selectedImage = imgs.first;
    });
  }

  Future<void> _pickAndCropImage(ImageSource source) async {
    try {
      final XFile? pickedFile = await _picker.pickImage(source: source);
      if (pickedFile != null) {
        final croppedFile = await ImageCropper().cropImage(
          sourcePath: pickedFile.path,
          aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: 'Crop Image',
              toolbarColor: const Color(0xFF0F172A),
              toolbarWidgetColor: Colors.tealAccent,
              activeControlsWidgetColor: Colors.tealAccent,
              backgroundColor: Colors.black,
              lockAspectRatio: true,
            ),
            IOSUiSettings(title: 'Crop Image', aspectRatioLockEnabled: true),
          ],
        );

        if (croppedFile != null) {
          final bytes = await croppedFile.readAsBytes();
          setState(() => _selectedImage = MemoryImage(bytes));
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking/cropping image: \$e')),
      );
    }
  }

  Future<void> _loadData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _bestScores = {
        3: prefs.getString('best_3') ?? '--',
        4: prefs.getString('best_4') ?? '--',
        5: prefs.getString('best_5') ?? '--',
      };
      _showNumbers = prefs.getBool('showNumbers') ?? false;
      _hapticsEnabled = prefs.getBool('haptics') ?? true;
      _soundEnabled = prefs.getBool('sound') ?? true;
    });
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('showNumbers', _showNumbers);
    await prefs.setBool('haptics', _hapticsEnabled);
    await prefs.setBool('sound', _soundEnabled);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [const Color(0xFF0F172A), const Color(0xFF1E293B)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Procedural\nPuzzle', textAlign: TextAlign.center, style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white, height: 1.1)),
                    const SizedBox(height: 8),
                    Text('Generated Art & Audio', textAlign: TextAlign.center, style: TextStyle(color: Colors.tealAccent.shade200, fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 30),
                    
                    Container(
                      width: 220,
                      height: 220,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [BoxShadow(color: Colors.tealAccent.withOpacity(0.2), blurRadius: 20, spreadRadius: 2)],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: _selectedImage != null
                            ? Image(image: _selectedImage!, fit: BoxFit.cover)
                            : const Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _pickAndCropImage(ImageSource.gallery),
                            child: Semantics(
                              label: 'Pick image from gallery',
                              button: true,
                              child: GlassCard(
                                borderRadius: 12,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(Icons.photo_library, color: Colors.tealAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text('Gallery', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => _pickAndCropImage(ImageSource.camera),
                            child: Semantics(
                              label: 'Take photo with camera',
                              button: true,
                              child: GlassCard(
                                borderRadius: 12,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(Icons.camera_alt, color: Colors.tealAccent, size: 18),
                                    SizedBox(width: 8),
                                    Text('Camera', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Procedural Patterns', style: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1)),
                        GestureDetector(
                          onTap: _generateNewPhotos,
                          child: Semantics(
                            label: 'Generate new patterns',
                            button: true,
                            child: GlassCard(
                              borderRadius: 12,
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              child: Row(
                                children: const [
                                  Icon(Icons.refresh, size: 14, color: Colors.tealAccent),
                                  SizedBox(width: 4),
                                  Text('New', style: TextStyle(color: Colors.tealAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          ),
                        )
                      ],
                    ),
                    const SizedBox(height: 12),
                    _generatedImages.isEmpty
                      ? const SizedBox(height: 60, child: Center(child: CircularProgressIndicator(color: Colors.white24)))
                      : SizedBox(
                          height: 60,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: _generatedImages.length,
                            itemBuilder: (context, index) {
                              bool isSelected = _selectedImage == _generatedImages[index];
                              return GestureDetector(
                                onTap: () => setState(() => _selectedImage = _generatedImages[index]),
                                child: Semantics(
                                  label: 'Select procedural pattern \${index + 1}',
                                  button: true,
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: 60,
                                    height: 60,
                                    margin: const EdgeInsets.only(right: 8),
                                    transform: Matrix4.identity()..scale(isSelected ? 1.1 : 1.0),
                                    transformAlignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: isSelected ? Colors.tealAccent : Colors.white.withOpacity(0.1), 
                                        width: isSelected ? 3 : 1
                                      ),
                                      image: DecorationImage(
                                        image: _generatedImages[index],
                                        fit: BoxFit.cover,
                                      ),
                                      boxShadow: isSelected ? [BoxShadow(color: Colors.tealAccent.withOpacity(0.4), blurRadius: 8)] : [],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    const SizedBox(height: 32),

                    Text('Difficulty', style: TextStyle(color: Colors.grey.shade300, fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1)),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        for (int i = 0; i < 3; i++) ...[
                          Expanded(
                            child: _buildDifficultyButton([3, 4, 5][i], ['Easy', 'Medium', 'Hard'][i]),
                          ),
                          if (i < 2) const SizedBox(width: 12),
                        ]
                      ],
                    ),
                    const SizedBox(height: 16),
                    
                    Text('Best: \${_bestScores[_gridSize] ?? '--'}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 24),

                    GlassCard(
                      borderRadius: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Column(
                        children: [
                          _SettingToggle(label: 'Show Numbers', icon: Icons.looks_one_outlined, value: _showNumbers, onChanged: (val) { setState(() => _showNumbers = val); _saveSettings(); }),
                          Divider(color: Colors.white.withOpacity(0.1), height: 1),
                          _SettingToggle(label: 'Vibration', icon: Icons.vibration_outlined, value: _hapticsEnabled, onChanged: (val) { setState(() => _hapticsEnabled = val); _saveSettings(); }),
                          Divider(color: Colors.white.withOpacity(0.1), height: 1),
                          _SettingToggle(label: 'Sound', icon: Icons.volume_up_outlined, value: _soundEnabled, onChanged: (val) { setState(() => _soundEnabled = val); _saveSettings(); }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),

                    if (_selectedImage != null)
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.tealAccent,
                          foregroundColor: const Color(0xFF0F172A),
                          padding: const EdgeInsets.symmetric(vertical: 18),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          final audioPlayer = AudioPlayer();
                          final controller = PuzzleGameController(
                            gridSize: _gridSize,
                            hapticsEnabled: _hapticsEnabled,
                            soundEnabled: _soundEnabled,
                            audioPlayer: audioPlayer,
                          );

                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ChangeNotifierProvider(
                                create: (_) => controller,
                                child: PuzzleScreen(
                                  imageProvider: _selectedImage!,
                                  showNumbers: _showNumbers,
                                ),
                              ),
                            ),
                          );
                          controller.dispose();
                          if (context.mounted) _loadData();
                        },
                        child: const Text('Start Puzzle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1)),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDifficultyButton(int size, String label) {
    bool isSelected = _gridSize == size;
    return GestureDetector(
      onTap: () => setState(() => _gridSize = size),
      child: Semantics(
        label: '\$size by \$size grid, \$label difficulty',
        button: true,
        child: GlassCard(
          borderRadius: 16,
          padding: const EdgeInsets.symmetric(vertical: 16),
          borderColor: isSelected ? Colors.tealAccent : Colors.white.withOpacity(0.15),
          child: Column(
            children: [
              Text('\${size}x\$size', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isSelected ? Colors.tealAccent : Colors.white)),
              const SizedBox(height: 2),
              Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade400, letterSpacing: 1)),
            ],
          ),
        ),
      ),
    );
  }
}

// ==========================================
// 5. PUZZLE SCREEN
// ==========================================
class PuzzleScreen extends StatelessWidget {
  final ImageProvider imageProvider;
  final bool showNumbers;

  const PuzzleScreen({super.key, required this.imageProvider, required this.showNumbers});

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final puzzleSize = screenWidth > 420 ? 400.0 : screenWidth - 32;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [const Color(0xFF0F172A), const Color(0xFF1E293B)],
                ),
              ),
            ),

            Positioned(
              top: 16,
              left: 16,
              right: 16,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _FloatingButton(icon: Icons.arrow_back_ios_new, semanticLabel: 'Back to home', onTap: () => Navigator.pop(context, true)),
                  Row(
                    children: [
                      Selector<PuzzleGameController, String>(
                        selector: (_, controller) => controller.formattedTime,
                        builder: (context, time, child) => _FloatingGlassStat(icon: Icons.timer_outlined, value: time),
                      ),
                      const SizedBox(width: 8),
                      Selector<PuzzleGameController, int>(
                        selector: (_, controller) => controller.moves,
                        builder: (context, moves, child) => _FloatingGlassStat(icon: Icons.touch_app_outlined, value: '\$moves'),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Consumer<PuzzleGameController>(
                        builder: (context, controller, child) {
                          return _FloatingButton(
                            icon: Icons.replay, 
                            semanticLabel: 'Undo last move', 
                            onTap: controller.undoMove
                          );
                        }
                      ),
                      const SizedBox(width: 8),
                      Consumer<PuzzleGameController>(
                        builder: (context, controller, child) {
                          return _FloatingButton(
                            icon: Icons.shuffle, 
                            semanticLabel: 'Shuffle puzzle', 
                            onTap: controller.reshuffle
                          );
                        }
                      ),
                    ],
                  )
                ],
              ),
            ),

            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Consumer<PuzzleGameController>(
                    builder: (context, controller, child) {
                      return GestureDetector(
                        onLongPressStart: (_) => controller.togglePeek(true),
                        onLongPressEnd: (_) => controller.togglePeek(false),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          width: puzzleSize,
                          height: puzzleSize,
                          decoration: BoxDecoration(
                            color: Colors.black,
                            border: Border.all(
                              color: controller.isSolved ? Colors.tealAccent : Colors.white.withOpacity(0.15),
                              width: 4,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: controller.isSolved 
                                    ? Colors.tealAccent.withOpacity(0.4) 
                                    : Colors.black.withOpacity(0.5),
                                blurRadius: controller.isSolved ? 30 : 20, 
                                spreadRadius: controller.isSolved ? 5 : 2
                              )
                            ],
                          ),
                          child: Stack(
                            children: [
                              if (!controller.isPeeking)
                                ...List.generate(controller.n * controller.n - 1, (tileValue) {
                                  int currentIndex = controller.state.indexOf(tileValue);
                                  int x = currentIndex % controller.n;
                                  int y = currentIndex ~/ controller.n;

                                  int srcX = tileValue % controller.n;
                                  int srcY = tileValue ~/ controller.n;
                                  double tileSize = puzzleSize / controller.n;

                                  return AnimatedPositioned(
                                    duration: const Duration(milliseconds: 120),
                                    curve: Curves.easeOut,
                                    left: x * tileSize,
                                    top: y * tileSize,
                                    width: tileSize,
                                    height: tileSize,
                                    child: _PuzzleTile(
                                      tileValue: tileValue,
                                      srcX: srcX,
                                      srcY: srcY,
                                      n: controller.n,
                                      puzzleSize: puzzleSize,
                                      tileSize: tileSize,
                                      imageProvider: imageProvider,
                                      showNumbers: showNumbers,
                                      isSolved: controller.isSolved,
                                      controller: controller,
                                    ),
                                  );
                                }),

                              if (controller.isPeeking)
                                Opacity(
                                  opacity: 0.8,
                                  child: Image(
                                    image: imageProvider,
                                    width: puzzleSize,
                                    height: puzzleSize,
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                  ),
                                ),
                              
                              if (controller.isSolved)
                                Positioned.fill(
                                  child: Center(
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween(begin: 0.0, end: 1.0),
                                      duration: const Duration(milliseconds: 400),
                                      builder: (context, scale, child) {
                                        return Transform.scale(scale: scale, child: child);
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.7),
                                          borderRadius: BorderRadius.circular(16),
                                          border: Border.all(color: Colors.tealAccent, width: 2)
                                        ),
                                        child: const Text('SOLVED!', style: TextStyle(color: Colors.tealAccent, fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 2)),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Selector<PuzzleGameController, bool>(
                    selector: (_, controller) => controller.isPeeking,
                    builder: (context, isPeeking, child) {
                      return Text(
                        isPeeking ? 'Release to hide' : 'Tap or Drag to slide. Hold to peek.',
                        style: TextStyle(color: Colors.white.withOpacity(0.5), fontStyle: FontStyle.italic, fontWeight: FontWeight.w500),
                      );
                    }
                  ),
                ],
              ),
            ),

            // Pause Overlay
            Selector<PuzzleGameController, bool>(
              selector: (_, controller) => controller.isPaused,
              builder: (context, isPaused, child) {
                if (!isPaused) return const SizedBox.shrink();
                return Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.8),
                    child: Center(
                      child: GlassCard(
                        borderRadius: 20,
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Paused', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900)),
                            const SizedBox(height: 24),
                            Consumer<PuzzleGameController>(
                              builder: (context, controller, child) {
                                return ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.tealAccent,
                                    foregroundColor: const Color(0xFF0F172A),
                                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                  onPressed: controller.resumeGame,
                                  child: const Text('Resume', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                );
                              }
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }
            ),

            // Win Dialog Trigger
            Consumer<PuzzleGameController>(
              builder: (context, controller, child) {
                if (controller.isSolved) {
                  Future.delayed(const Duration(milliseconds: 1400), () {
                    if (context.mounted) _showWinDialog(context, controller);
                  });
                }
                return const SizedBox.shrink();
              }
            ),
          ],
        ),
      ),
    );
  }

  void _showWinDialog(BuildContext context, PuzzleGameController controller) async {
    final scoreData = await controller.saveAndGetScore();
    if (!context.mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Colors.tealAccent.withOpacity(0.3))),
        title: const Text('Solved!', textAlign: TextAlign.center, style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.w900)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Time: \${scoreData['time']}', style: const TextStyle(fontSize: 18, color: Colors.white)),
            Text('Moves: \${scoreData['moves']}', style: const TextStyle(fontSize: 18, color: Colors.white)),
            if (scoreData['isNewBest'])
              Padding(
                padding: const EdgeInsets.only(top: 12.0),
                child: Text('New Best Score!', style: TextStyle(color: Colors.amber.shade300, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context); 
              Navigator.pop(context, true); 
            },
            child: const Text('Home', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.tealAccent,
              foregroundColor: const Color(0xFF0F172A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              Navigator.pop(context); 
              controller.reshuffle();
            },
            child: const Text('Play Again'),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 6. FLOATING GLASS WIDGETS & TILE
// ==========================================
class _FloatingButton extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  const _FloatingButton({required this.icon, required this.semanticLabel, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Semantics(
        label: semanticLabel,
        button: true,
        child: GlassCard(
          borderRadius: 12,
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.tealAccent, size: 20),
        ),
      ),
    );
  }
}

class _FloatingGlassStat extends StatelessWidget {
  final IconData icon;
  final String value;

  const _FloatingGlassStat({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      borderRadius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
        ],
      ),
    );
  }
}

class _PuzzleTile extends StatefulWidget {
  final int tileValue;
  final int srcX;
  final int srcY;
  final int n;
  final double puzzleSize;
  final double tileSize;
  final ImageProvider imageProvider;
  final bool showNumbers;
  final bool isSolved;
  final PuzzleGameController controller;

  const _PuzzleTile({
    required this.tileValue,
    required this.srcX,
    required this.srcY,
    required this.n,
    required this.puzzleSize,
    required this.tileSize,
    required this.imageProvider,
    required this.showNumbers,
    required this.isSolved,
    required this.controller,
  });

  @override
  State<_PuzzleTile> createState() => _PuzzleTileState();
}

class _PuzzleTileState extends State<_PuzzleTile> {
  Offset _dragOffset = Offset.zero;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    int row = (widget.tileValue / widget.n).floor() + 1;
    int col = (widget.tileValue % widget.n) + 1;
    
    return Semantics(
      label: 'Puzzle piece \${widget.tileValue + 1}. Originally located at row \$row, column \$col. Double tap to move.',
      button: true,
      child: GestureDetector(
        onPanStart: (details) {
          MoveDirection dir = widget.controller.getMoveDirection(widget.tileValue);
          if (dir != MoveDirection.none) {
            setState(() => _isDragging = true);
          }
        },
        onPanUpdate: (details) {
          if (!_isDragging) return;
          MoveDirection dir = widget.controller.getMoveDirection(widget.tileValue);
          
          setState(() {
            double newX = _dragOffset.dx + details.delta.dx;
            double newY = _dragOffset.dy + details.delta.dy;
            
            if (dir == MoveDirection.left) {
              _dragOffset = Offset(newX.clamp(-widget.tileSize, 0.0), 0.0);
            } else if (dir == MoveDirection.right) {
              _dragOffset = Offset(newX.clamp(0.0, widget.tileSize), 0.0);
            } else if (dir == MoveDirection.up) {
              _dragOffset = Offset(0.0, newY.clamp(-widget.tileSize, 0.0));
            } else if (dir == MoveDirection.down) {
              _dragOffset = Offset(0.0, newY.clamp(0.0, widget.tileSize));
            }
          });
        },
        onPanEnd: (details) {
          if (!_isDragging) return;
          MoveDirection dir = widget.controller.getMoveDirection(widget.tileValue);
          bool shouldMove = false;
          
          if (dir == MoveDirection.left && _dragOffset.dx <= -widget.tileSize / 2) shouldMove = true;
          if (dir == MoveDirection.right && _dragOffset.dx >= widget.tileSize / 2) shouldMove = true;
          if (dir == MoveDirection.up && _dragOffset.dy <= -widget.tileSize / 2) shouldMove = true;
          if (dir == MoveDirection.down && _dragOffset.dy >= widget.tileSize / 2) shouldMove = true;
          
          setState(() {
            _dragOffset = Offset.zero;
            _isDragging = false;
          });
          
          if (shouldMove) {
            widget.controller.tryMove(widget.tileValue);
          }
        },
        onTap: () => widget.controller.tryMove(widget.tileValue),
        child: AnimatedScale(
          scale: _isDragging ? 1.05 : 1.0,
          duration: const Duration(milliseconds: 80),
          child: Transform.translate(
            offset: _dragOffset,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: EdgeInsets.all(widget.isSolved ? 0.0 : 0.5),
              decoration: BoxDecoration(
                border: widget.isSolved 
                    ? Border.all(color: Colors.transparent, width: 0) 
                    : Border.all(color: Colors.white.withOpacity(0.1), width: 1),
              ),
              child: Stack(
                children: [
                  ClipRect(
                    child: OverflowBox(
                      minWidth: widget.puzzleSize,
                      minHeight: widget.puzzleSize,
                      maxWidth: widget.puzzleSize,
                      maxHeight: widget.puzzleSize,
                      alignment: Alignment(
                        ((widget.srcX / (widget.n - 1)) * 2) - 1,
                        ((widget.srcY / (widget.n - 1)) * 2) - 1,
                      ),
                      child: Image(
                        image: widget.imageProvider,
                        width: widget.puzzleSize,
                        height: widget.puzzleSize,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                  ),
                  if (widget.showNumbers)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '\${widget.tileValue + 1}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
