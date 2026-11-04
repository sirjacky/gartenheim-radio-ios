import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';

void main() {
  runApp(const GartenheimRadioApp());
}

class GartenheimRadioApp extends StatelessWidget {
  const GartenheimRadioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Gartenheim-Radio',
      theme: ThemeData.dark(),
      home: const RadioHomePage(),
    );
  }
}

class RadioHomePage extends StatefulWidget {
  const RadioHomePage({super.key});

  @override
  State<RadioHomePage> createState() => _RadioHomePageState();
}

class _RadioHomePageState extends State<RadioHomePage> {
  static const Color darkBlue = Color(0xFF070D20);
  static const Color neonBlue = Color(0xFF00E5FF);

  static const String streamUrl =
      'https://gartenheimradio.sp.radio.fm/stream';

  static const String metadataUrl =
      'https://gartenheimradio.spcast.eu/status-json.xsl';

  final AudioPlayer _player = AudioPlayer();

  Timer? _metadataTimer;
  Timer? _displayTimer;
  StreamSubscription<PlayerState>? _playerSubscription;

  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isConnecting = false;
  bool _requestRunning = false;

  String? _errorMessage;

  String _title = 'Gartenheim-Radio';
  String _artist = 'Dein Radio. Deine Musik.';
  String? _coverUrl;

  String _lastReceivedSong = '';
  int _songGeneration = 0;

  @override
  void initState() {
    super.initState();

    _playerSubscription = _player.playerStateStream.listen((state) {
      if (!mounted) return;

      setState(() {
        _isPlaying = state.playing;
        _isBuffering =
            state.processingState == ProcessingState.buffering ||
                state.processingState == ProcessingState.loading;
      });
    });

    unawaited(_loadSongInfo());

    _metadataTimer = Timer.periodic(
      const Duration(seconds: 3),
          (_) => unawaited(_loadSongInfo()),
    );
  }

  // Aktuelle Titelinformationen laden.
  Future<void> _loadSongInfo() async {
    if (_requestRunning || !mounted) return;

    _requestRunning = true;

    try {
      final uri = Uri.parse(metadataUrl).replace(
        queryParameters: {
          't': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );

      final response = await http.get(uri).timeout(
        const Duration(seconds: 7),
      );

      if (!mounted || response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      if (data is! Map) return;

      final stats = data['icestats'];
      if (stats is! Map) return;

      final rawSources = stats['source'];

      final List<dynamic> sources = rawSources is List
          ? rawSources
          : rawSources is Map
          ? [rawSources]
          : [];

      if (sources.isEmpty) return;

      final source = sources.firstWhere(
            (item) =>
        item is Map &&
            item['mount']
                .toString()
                .replaceAll(RegExp(r'/$'), '')
                .endsWith('/stream320'),
        orElse: () => sources.firstWhere(
              (item) =>
          item is Map &&
              !item['mount'].toString().endsWith('/autodj'),
          orElse: () => sources.first,
        ),
      );

      if (source is! Map) return;

      final raw = (source['title'] ?? '').toString().trim();

      String artist;
      String title;

      if (raw.isEmpty) {
        artist = 'Gartenheim-Radio';
        title = 'Live Stream';
      } else {
        final hasSpacedSeparator = raw.contains(' - ');

        final separator = hasSpacedSeparator
            ? raw.indexOf(' - ')
            : raw.indexOf('-');

        if (separator >= 0) {
          artist = raw.substring(0, separator).trim();

          title = raw
              .substring(separator + (hasSpacedSeparator ? 3 : 1))
              .split('|')
              .first
              .trim();
        } else {
          artist = 'Gartenheim-Radio';
          title = raw;
        }

        if (artist.isEmpty) {
          artist = 'Gartenheim-Radio';
        }

        if (title.isEmpty) {
          title = 'Live Stream';
        }
      }

      _receiveSong(title, artist);
    } catch (e) {
      debugPrint('Metadatenfehler: $e');
    } finally {
      _requestRunning = false;
    }
  }

  // Titelwechsel während der Wiedergabe verzögert anzeigen.
  void _receiveSong(String title, String artist) {
    if (!mounted) return;

    final key = '$artist|$title';
    if (key == _lastReceivedSong) return;

    _lastReceivedSong = key;
    _displayTimer?.cancel();

    final generation = ++_songGeneration;

    void displaySong() {
      if (!mounted || generation != _songGeneration) return;

      setState(() {
        _title = title;
        _artist = artist;
        _coverUrl = null;
      });

      if (title != 'Live Stream' && artist != 'Gartenheim-Radio') {
        unawaited(_loadCover(title, artist, generation));
      }
    }

    if (_isPlaying) {
      _displayTimer = Timer(
        const Duration(seconds: 10),
        displaySong,
      );
    } else {
      displaySong();
    }
  }

  // Albumcover von Apple iTunes laden.
  Future<void> _loadCover(
      String title,
      String artist,
      int generation,
      ) async {
    try {
      final uri = Uri.https(
        'itunes.apple.com',
        '/search',
        {
          'term': '$artist $title',
          'entity': 'song',
          'limit': '1',
        },
      );

      final response = await http.get(uri).timeout(
        const Duration(seconds: 7),
      );

      if (response.statusCode != 200) return;

      final data = jsonDecode(response.body);
      if (data is! Map) return;

      final results = data['results'];
      if (results is! List || results.isEmpty) return;

      final first = results.first;
      if (first is! Map) return;

      final artwork = first['artworkUrl100']?.toString();
      if (artwork == null || artwork.isEmpty) return;

      final coverUrl = artwork.replaceFirst(
        '100x100bb',
        '600x600bb',
      );

      if (!mounted || generation != _songGeneration) return;

      setState(() {
        _coverUrl = coverUrl;
      });
    } catch (e) {
      debugPrint('Coverfehler: $e');
    }
  }

  void _showPlayerError(Object error) {
    if (!mounted) return;

    setState(() {
      _errorMessage = 'Stream konnte nicht geladen werden.';
    });

    debugPrint('Radiofehler: $error');
  }

  // play() endet erst beim Pausieren, Stoppen oder bei einem Fehler.
  Future<void> _startPlayback() async {
    try {
      await _player.play();
    } catch (e) {
      _showPlayerError(e);
    }
  }

  // Radio starten oder pausieren.
  Future<void> _toggleRadio() async {
    if (_isConnecting) return;

    if (_isPlaying) {
      try {
        await _player.pause();
      } catch (e) {
        _showPlayerError(e);
      }
      return;
    }

    setState(() {
      _isConnecting = true;
      _errorMessage = null;
    });

    try {
      if (_player.audioSource == null) {
        await _player.setUrl(streamUrl);
      }

      if (!mounted) return;

      unawaited(_startPlayback());
    } catch (e) {
      _showPlayerError(e);
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _metadataTimer?.cancel();
    _displayTimer?.cancel();
    _playerSubscription?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final compact = screenHeight < 720;

    final logoSize = compact ? 170.0 : 210.0;
    final coverSize = compact ? 135.0 : 165.0;
    final buttonSize = compact ? 90.0 : 104.0;

    return Scaffold(
      backgroundColor: const Color(0xFF030714),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF030714),
              Color(0xFF08132C),
              Color(0xFF170A35),
              Color(0xFF080619),
            ],
          ),
        ),
        child: Stack(
          children: [
            // Neon-Wellen am unteren Bildschirmrand.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 170,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: NeonWavesPainter(),
                ),
              ),
            ),

            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  24,
                  12,
                  24,
                  110,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Originales Gartenheim-Radio-Logo.
                    Image.asset(
                      'assets/gartenheim_logo.png',
                      width: logoSize,
                      height: logoSize,
                      fit: BoxFit.contain,
                    ),

                    SizedBox(height: compact ? 12 : 17),

                    // Karte für Cover, Titel und Interpret.
                    Container(
                      width: double.infinity,
                      decoration: BoxDecoration(
                        color: const Color(0xD9141C39),
                        borderRadius: BorderRadius.circular(22),
                        border: const GradientBorder(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xB800E5FF),
                              Color(0x9ED83DFF),
                            ],
                          ),
                          width: 1,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 15,
                      ),
                      child: Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(15),
                            child: Container(
                              width: coverSize,
                              height: coverSize,
                              color: const Color(0xFF111A36),
                              child: _coverUrl != null
                                  ? Image.network(
                                _coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (
                                    context,
                                    error,
                                    stackTrace,
                                    ) {
                                  return _coverPlaceholder();
                                },
                              )
                                  : _coverPlaceholder(),
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Lange Musiktitel laufen automatisch.
                          MarqueeText(
                            text: _title,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Lange Interpreten laufen unabhängig davon.
                          MarqueeText(
                            text: _artist,
                            style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFFC4CEE8),
                            ),
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: compact ? 12 : 17),

                    // Play-/Pause-Button im bisherigen Design.
                    Semantics(
                      button: true,
                      label: _isPlaying
                          ? 'Radio pausieren'
                          : 'Radio starten',
                      child: GestureDetector(
                        onTap: _isConnecting ? null : _toggleRadio,
                        child: Container(
                          width: buttonSize,
                          height: buttonSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Color(0xFFB8FFFF),
                                Color(0xFF30DCEB),
                                Color(0xFF00A9C8),
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: neonBlue.withValues(alpha: 0.18),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            _isPlaying
                                ? Icons.pause
                                : Icons.play_arrow,
                            size: compact ? 52 : 60,
                            color: darkBlue,
                          ),
                        ),
                      ),
                    ),

                    SizedBox(height: compact ? 12 : 17),

                    Text(
                      _statusText(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: _errorMessage != null
                            ? const Color(0xFFFF8B9A)
                            : neonBlue,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _statusText() {
    if (_errorMessage != null) {
      return _errorMessage!;
    }

    if (_isConnecting) {
      return 'Verbinde mit dem Radiodienst...';
    }

    if (_isBuffering) {
      return 'Verbinde mit dem Sender...';
    }

    if (_isPlaying) {
      return '♪ Viel Spaß beim Zuhören!';
    }

    return 'Drücke Play zum Einschalten';
  }

  Widget _coverPlaceholder() {
    return Image.asset(
      'assets/kein_cover.png',
      width: double.infinity,
      height: double.infinity,
      fit: BoxFit.contain,
    );
  }
}

// Automatische Laufschrift ohne zusätzliches Paket.
//
// Kurze Texte bleiben zentriert.
// Lange Texte laufen mit gleichbleibender Geschwindigkeit.
// Nach jedem Durchlauf folgt eine Pause von 1,6 Sekunden.
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.speed = 30,
    this.gap = 48,
    this.pause = const Duration(milliseconds: 1600),
  })  : assert(speed > 0),
        assert(gap >= 0);

  final String text;
  final TextStyle style;

  // Logische Pixel pro Sekunde.
  final double speed;

  // Abstand zwischen zwei Textkopien.
  final double gap;

  final Duration pause;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  Timer? _pauseTimer;

  Object? _configuration;
  int _revision = 0;
  bool _shouldScroll = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(vsync: this);
    _controller.addStatusListener(_onAnimationStatus);
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // Die zweite Textkopie steht jetzt genau am Anfang.
      // Deshalb ist das Zurücksetzen optisch nahtlos.
      _controller.reset();
      _scheduleStart();
    }
  }

  void _scheduleStart() {
    _pauseTimer?.cancel();

    if (!_shouldScroll) return;

    _pauseTimer = Timer(widget.pause, () {
      if (!mounted || !_shouldScroll) return;
      _controller.forward(from: 0);
    });
  }

  void _configure({
    required Object configuration,
    required bool shouldScroll,
    required double distance,
  }) {
    if (_configuration == configuration) return;

    _configuration = configuration;
    final revision = ++_revision;

    // Änderungen am Controller erst nach dem Layout anwenden.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;

      _pauseTimer?.cancel();
      _shouldScroll = shouldScroll;

      _controller.stop();
      _controller.reset();

      if (!shouldScroll) return;

      final milliseconds = math.max(
        1,
        (distance / widget.speed * 1000).round(),
      );

      _controller.duration = Duration(
        milliseconds: milliseconds,
      );

      _scheduleStart();
    });
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    _controller.removeStatusListener(_onAnimationStatus);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(
      widget.style,
    );

    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final painter = TextPainter(
          text: TextSpan(
            text: widget.text,
            style: style,
          ),
          maxLines: 1,
          textDirection: textDirection,
          textScaler: textScaler,
          locale: locale,
        )..layout();

        // Aufrunden verhindert, dass einzelne Glyphen abgeschnitten werden.
        final textWidth = painter.width.ceilToDouble();
        final textHeight = painter.height.ceilToDouble();
        painter.dispose();

        final availableWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : textWidth;

        final shouldScroll = !reduceMotion &&
            availableWidth > 0 &&
            textWidth > availableWidth;

        final distance = textWidth + widget.gap;

        // Änderungen an Text, Breite oder Schrift starten neu.
        final configuration = (
        widget.text,
        style,
        textScaler,
        textDirection,
        locale,
        availableWidth,
        textWidth,
        widget.speed,
        widget.gap,
        widget.pause,
        shouldScroll,
        );

        _configure(
          configuration: configuration,
          shouldScroll: shouldScroll,
          distance: distance,
        );

        if (!shouldScroll) {
          return SizedBox(
            width: availableWidth,
            child: Text(
              widget.text,
              style: style,
              textScaler: textScaler,
              textDirection: textDirection,
              locale: locale,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          );
        }

        Widget textCopy() {
          return SizedBox(
            width: textWidth,
            child: Text(
              widget.text,
              style: style,
              textScaler: textScaler,
              textDirection: textDirection,
              locale: locale,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
            ),
          );
        }

        return Semantics(
          label: widget.text,
          child: ExcludeSemantics(
            child: SizedBox(
              width: availableWidth,
              height: textHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.centerLeft,
                  minWidth: textWidth * 2 + widget.gap,
                  maxWidth: textWidth * 2 + widget.gap,
                  child: AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return Transform.translate(
                        offset: Offset(
                          -_controller.value * distance,
                          0,
                        ),
                        child: child,
                      );
                    },
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      textDirection: TextDirection.ltr,
                      children: [
                        textCopy(),
                        SizedBox(width: widget.gap),
                        textCopy(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// Dünner türkis-violetter Farbverlaufsrahmen.
class GradientBorder extends BoxBorder {
  const GradientBorder({
    required this.gradient,
    required this.width,
  });

  final Gradient gradient;
  final double width;

  @override
  BorderSide get top => BorderSide.none;

  @override
  BorderSide get bottom => BorderSide.none;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  bool get isUniform => true;

  @override
  void paint(
      Canvas canvas,
      Rect rect, {
        TextDirection? textDirection,
        BoxShape shape = BoxShape.rectangle,
        BorderRadius? borderRadius,
      }) {
    final radius = borderRadius ?? BorderRadius.zero;

    final paint = Paint()
      ..shader = gradient.createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;

    canvas.drawRRect(
      radius.toRRect(rect.deflate(width / 2)),
      paint,
    );
  }

  @override
  ShapeBorder scale(double t) {
    return GradientBorder(
      gradient: gradient,
      width: width * t,
    );
  }
}

// Zwölf geschwungene Neon-Wellen.
class NeonWavesPainter extends CustomPainter {
  const NeonWavesPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const colors = [
      Color(0xFF00E5FF),
      Color(0xFF00AFFF),
      Color(0xFF7752FF),
      Color(0xFFD83DFF),
    ];

    for (int index = 0; index < 12; index++) {
      final path = Path();

      final baseline = size.height * 0.55 + index * 5.0;

      final amplitude =
          size.height * (0.10 + index * 0.005);

      for (int step = 0; step <= 120; step++) {
        final progress = step / 120.0;
        final x = size.width * progress;

        final wave = math.sin(
          progress * math.pi * 2 - 0.35,
        );

        final y = baseline + wave * amplitude;

        if (step == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }

      final colorIndex = (index * colors.length ~/ 12)
          .clamp(0, colors.length - 1);

      final strong = index % 3 == 0;

      final paint = Paint()
        ..color = colors[colorIndex].withValues(
          alpha: strong ? 0.85 : 0.28,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = strong ? 2.5 : 1.0
        ..strokeCap = StrokeCap.round;

      canvas.drawPath(path, paint);
    }

    final center = Offset(
      size.width * 0.75,
      size.height * 0.75,
    );

    final radius = size.width * 0.55;

    final glowPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFD83DFF).withValues(alpha: 0.14),
          Colors.transparent,
        ],
      ).createShader(
        Rect.fromCircle(
          center: center,
          radius: radius,
        ),
      );

    canvas.drawCircle(center, radius, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}