import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:cross_file/cross_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../theme/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/api_service.dart';

extension _LMI<T> on List<T> {
  List<R> mapIndexed<R>(R Function(int i, T item) f) =>
      List.generate(length, (i) => f(i, this[i]));
}

class InterviewSessionScreen extends StatefulWidget {
  const InterviewSessionScreen({super.key});
  @override
  State<InterviewSessionScreen> createState() => _ISState();
}

class _ISState extends State<InterviewSessionScreen> {
  // Phase: 0=skill extraction, 1=setup, 2=active interview, 3=complete
  int _phase = 0;
  int _qIndex = 0;
  bool _recording = false;
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _questionPlayer = AudioPlayer();
  late final String _talkingHeadViewType;
  html.IFrameElement? _talkingHeadFrame;

  // Skills
  List<String> _extractedSkills = [];
  Map<String, dynamic>? _candidateProfile;
  final _skillCtrl = TextEditingController();
  final _githubCtrl = TextEditingController();
  String? _resumeFileName;
  bool _extracting = false;

  // Interview config
  final _roles = ['Software Engineer', 'Data Scientist', 'Product Manager', 'UI/UX Designer', 'DevOps Engineer'];
  int _selectedRole = 0;
  final _levels = ['Junior', 'Mid-Level', 'Senior'];
  int _selectedLevel = 0;
  final _types = ['Behavioral', 'Technical'];
  int _selectedType = 0;
  final _questionCounts = [5, 10, 15];
  int _selectedQuestionCount = 0;

  // Active interview state
  String? _sessionId;
  List<dynamic> _questions = [];
  String? _reportId;
  Map<String, dynamic>? _avatarTalk;
  VideoPlayerController? _avatarController;
  bool _avatarVideoReady = false;
  bool _loadingAvatar = false;
  final Map<String, Map<String, dynamic>> _avatarTalkCache = {};
  List<int>? _answerAudioBytes;
  String? _answerAudioName;
  bool _submittingAnswer = false;
  bool _speakingQuestion = false;
  bool _ttsAvailable = true;
  bool _questionChanging = false;
  DateTime? _recordingStartedAt;
  final Map<String, dynamic> _answerEvaluations = {};
  final Set<String> _submittedQuestionIds = {};

  @override
  void initState() {
    super.initState();
    _registerTalkingHeadView();
    _configureTts();
    _questionPlayer.setReleaseMode(ReleaseMode.stop);
    _questionPlayer.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _speakingQuestion = false);
    });
    _questionPlayer.onPlayerStateChanged.listen((state) {
      if (!mounted) return;
      if (state == PlayerState.playing) {
        setState(() => _speakingQuestion = true);
      } else if (state == PlayerState.completed ||
          state == PlayerState.stopped ||
          state == PlayerState.disposed) {
        setState(() => _speakingQuestion = false);
      }
    });
    _loadUserSkills();
  }

  Future<void> _configureTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.46);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.08);
    await _preferFemaleVoice();
    _tts.setStartHandler(() {
      if (mounted) setState(() => _speakingQuestion = true);
    });
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speakingQuestion = false);
    });
    _tts.setCancelHandler(() {
      if (mounted) setState(() => _speakingQuestion = false);
    });
    _tts.setErrorHandler((message) {
      if (mounted) {
        setState(() {
          _speakingQuestion = false;
          _ttsAvailable = false;
        });
      }
      debugPrint('Question TTS failed: $message');
    });
  }

  void _registerTalkingHeadView() {
    _talkingHeadViewType = 'interviewmate-talkinghead-${DateTime.now().microsecondsSinceEpoch}';
    final frame = html.IFrameElement()
      ..src = 'talkinghead_avatar.html'
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..allow = 'autoplay; fullscreen';
    _talkingHeadFrame = frame;
    ui_web.platformViewRegistry.registerViewFactory(
      _talkingHeadViewType,
      (int viewId) => frame,
    );
  }

  void _sendTalkingHeadMessage(String type, {String? text}) {
    _talkingHeadFrame?.contentWindow?.postMessage({
      'source': 'interviewmate-flutter',
      'type': type,
      if (text != null) 'text': text,
    }, html.window.location.origin);
  }

  Future<void> _preferFemaleVoice() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is! List) return;

      const preferredNames = [
        'Jenny',
        'Zira',
        'Aria',
        'Samantha',
        'Google US English Female',
        'Microsoft',
        'Natural',
      ];

      Map<dynamic, dynamic>? selected;
      for (final name in preferredNames) {
        selected = voices.cast<Map<dynamic, dynamic>?>().firstWhere(
          (voice) {
            final voiceName = voice?['name']?.toString().toLowerCase() ?? '';
            final locale = voice?['locale']?.toString().toLowerCase() ?? '';
            return locale.startsWith('en') && voiceName.contains(name.toLowerCase());
          },
          orElse: () => null,
        );
        if (selected != null) break;
      }

      selected ??= voices.cast<Map<dynamic, dynamic>?>().firstWhere(
        (voice) => (voice?['locale']?.toString().toLowerCase() ?? '').startsWith('en'),
        orElse: () => null,
      );

      if (selected != null) {
        await _tts.setVoice({
          'name': selected['name'].toString(),
          'locale': selected['locale'].toString(),
        });
      }
    } catch (e) {
      debugPrint('Voice selection failed: $e');
    }
  }

  Future<void> _loadUserSkills() async {
    final uid = AuthService().uid;
    if (uid == null) return;
    try {
      final res = await ApiService().getSkills(uid);
      if (!mounted) return;
      final skills = res['skills'];
      if (skills != null && skills is List) {
        final names = skills
            .map((s) => s is Map ? s['name'].toString() : s.toString())
            .toList();
        setState(() => _extractedSkills = names);
      }
    } catch (e) {
      debugPrint('Error loading skills: $e');
    }
  }

  Future<void> _pickResume() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'doc', 'docx'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      setState(() { _resumeFileName = file.name; _extracting = true; });

      final uid = AuthService().uid ?? '';
      try {
        final res = await ApiService().uploadResume(file.bytes!, file.name, uid);
        final rawSkills = res['extractedSkills'] as List? ?? [];
        final skills = rawSkills.map((s) => s is Map ? s['name'].toString() : s.toString()).toList();
        setState(() {
          _extractedSkills = skills;
          _candidateProfile = _mergeProfile(null, res['candidateProfile']);
          _extracting = false;
        });
        _showSnack('${skills.length} skills extracted from resume!', AppTheme.successGreen);
      } catch (e) {
        setState(() {
          _extracting = false;
        });
        _showSnack('Resume extraction failed: $e', AppTheme.errorRed);
      }
    } catch (e) {
      setState(() => _extracting = false);
      _showSnack('Error: $e', AppTheme.errorRed);
    }
  }

  Future<void> _extractFromGitHub() async {
    final url = _githubCtrl.text.trim();
    if (url.isEmpty) { _showSnack('Please enter a GitHub username or URL', AppTheme.errorRed); return; }

    final username = url.contains('/') ? url.split('/').last : url;
    final uid = AuthService().uid ?? '';
    setState(() => _extracting = true);

    try {
      final res = await ApiService().extractGithubSkills(username, uid);
      final rawSkills = res['skills'] as List? ?? [];
      final skills = rawSkills.map((s) => s is Map ? s['name'].toString() : s.toString()).toList();
      setState(() {
        _extractedSkills = {..._extractedSkills, ...skills}.toList();
        _candidateProfile = _mergeProfile(_candidateProfile, res['candidateProfile']);
        _extracting = false;
      });
      _showSnack('${skills.length} skills extracted from GitHub!', AppTheme.successGreen);
    } catch (e) {
      setState(() {
        _extracting = false;
      });
      _showSnack('GitHub extraction failed: $e', AppTheme.errorRed);
    }
  }

  void _addSkill() {
    final skill = _skillCtrl.text.trim();
    if (skill.isEmpty) return;
    if (_extractedSkills.contains(skill)) { _showSnack('Skill already added', AppTheme.textGray); return; }
    setState(() { _extractedSkills.add(skill); _skillCtrl.clear(); });
  }

  void _removeSkill(String skill) => setState(() => _extractedSkills.remove(skill));

  Future<void> _saveSkillsAndContinue() async {
    if (_extractedSkills.isEmpty) { _showSnack('Please add at least one skill', AppTheme.errorRed); return; }
    // Save skills to backend
    final uid = AuthService().uid;
    if (uid != null) {
      try {
        await ApiService().updateSkills(uid, _extractedSkills);
      } catch (e) { debugPrint('Error saving skills: $e'); }
    }
    setState(() => _phase = 1);
  }

  Future<void> _startInterview() async {
    final uid = AuthService().uid ?? '';
    setState(() => _extracting = true);
    try {
      final profile = {
        if (_candidateProfile != null) ..._candidateProfile!,
        if (_candidateProfile == null || _candidateProfile!['field'] == null)
          'field': _roles[_selectedRole],
        if (_candidateProfile == null || _candidateProfile!['seniority'] == null)
          'seniority': _levels[_selectedLevel] == 'Junior' ? 'Beginner' : _levels[_selectedLevel],
        'interviewType': _types[_selectedType],
      };
      final res = await ApiService().startInterview(
        _extractedSkills,
        uid,
        candidateProfile: profile,
        questionCount: _questionCounts[_selectedQuestionCount],
      );
      setState(() {
        _sessionId = res['sessionId'];
        _questions = res['questions'] ?? [];
        _qIndex = 0;
        _phase = 2;
        _extracting = false;
        _answerAudioBytes = null;
        _answerAudioName = null;
        _answerEvaluations.clear();
        _submittedQuestionIds.clear();
      });
      await _prepareAvatarForCurrentQuestion();
    } catch (e) {
      setState(() {
        _extracting = false;
      });
      _showSnack('Could not start interview. Check backend login/session: $e', AppTheme.errorRed);
    }
  }

  Future<void> _nextQuestion() async {
    if (!await _submitCurrentAnswerIfReady()) return;
    if (_qIndex < _questions.length - 1) {
      await _goToQuestion(_qIndex + 1);
    } else {
      await _finishInterview();
    }
  }

  Future<void> _goToQuestion(int index) async {
    if (index < 0 || index >= _questions.length || index == _qIndex) return;
    await _questionPlayer.stop();
    await _tts.stop();
    _sendTalkingHeadMessage('stop');
    if (!mounted) return;
    setState(() {
      _questionChanging = true;
      _qIndex = index;
      _answerAudioBytes = null;
      _answerAudioName = null;
      _speakingQuestion = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 140));
    if (!mounted) return;
    setState(() => _questionChanging = false);
    await _prepareAvatarForCurrentQuestion();
  }

  Future<void> _pickAnswerAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final replacingDraft = _answerAudioName != null;
    final replacingSubmitted =
        _questions.isNotEmpty && _submittedQuestionIds.contains((_questions[_qIndex]['questionId'] ?? _questions[_qIndex]['question_id']).toString());
    setState(() {
      _answerAudioBytes = file.bytes;
      _answerAudioName = file.name;
      _recording = false;
    });
    _showSnack(
      replacingDraft
          ? 'New draft selected. Previous draft was replaced.'
          : replacingSubmitted
              ? 'New draft selected. It will replace the submitted answer when you continue.'
              : 'Answer draft selected',
      AppTheme.successGreen,
    );
  }

  Future<void> _toggleRecording() async {
    if (_submittingAnswer) return;

    try {
      if (_recording) {
        final path = await _recorder.stop();
        setState(() => _recording = false);
        final elapsed = _recordingStartedAt == null
            ? Duration.zero
            : DateTime.now().difference(_recordingStartedAt!);
        _recordingStartedAt = null;
        if (path == null || path.isEmpty) {
          _showSnack('Recording did not save. Try again.', AppTheme.errorRed);
          return;
        }
        if (elapsed < const Duration(milliseconds: 1500)) {
          setState(() {
            _answerAudioBytes = null;
            _answerAudioName = null;
          });
          _showSnack('Recording was too short. Please answer for at least a few seconds.', AppTheme.errorRed);
          return;
        }

        final replacingDraft = _answerAudioName != null;
        final replacingSubmitted =
            _questions.isNotEmpty && _submittedQuestionIds.contains((_questions[_qIndex]['questionId'] ?? _questions[_qIndex]['question_id']).toString());
        final bytes = await XFile(path).readAsBytes();
        setState(() {
          _answerAudioBytes = bytes;
          _answerAudioName = 'recorded_answer.m4a';
        });
        _showSnack(
          replacingDraft
              ? 'New recording saved. Previous draft was replaced.'
              : replacingSubmitted
                  ? 'New recording saved. It will replace the submitted answer when you continue.'
                  : 'Recording saved as draft',
          AppTheme.successGreen,
        );
        return;
      }

      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _showSnack('Microphone permission is required', AppTheme.errorRed);
        return;
      }

      await _tts.stop();
      await _questionPlayer.stop();
      _sendTalkingHeadMessage('stop');
      if (mounted) setState(() => _speakingQuestion = false);
      final path = await _recordingPath();
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 16000,
        ),
        path: path,
      );
      setState(() {
        _recording = true;
        _recordingStartedAt = DateTime.now();
        _answerAudioBytes = null;
        _answerAudioName = null;
      });
    } catch (e) {
      setState(() {
        _recording = false;
        _recordingStartedAt = null;
      });
      _showSnack('Recording failed: $e', AppTheme.errorRed);
    }
  }

  Future<String> _recordingPath() async {
    final fileName = 'interview_answer_${DateTime.now().millisecondsSinceEpoch}.m4a';
    if (kIsWeb) return fileName;
    final dir = await getTemporaryDirectory();
    return '${dir.path}/$fileName';
  }

  Future<bool> _submitCurrentAnswerIfReady() async {
    if (_sessionId == null || _questions.isEmpty) return true;
    final q = _questions[_qIndex];
    final questionId = q['questionId'] ?? q['question_id'];
    final uid = AuthService().uid ?? '';
    final id = questionId.toString();
    if (_answerAudioBytes == null && _submittedQuestionIds.contains(id)) {
      return true;
    }
    if (_answerAudioBytes == null) {
      _showSnack('Record or upload a new answer before continuing', AppTheme.errorRed);
      return false;
    }
    setState(() => _submittingAnswer = true);

    try {
      final res = await ApiService().submitAnswer(
        sessionId: _sessionId!,
        questionId: id,
        audioBytes: _answerAudioBytes!,
        uid: uid,
        audioFileName: _answerAudioName ?? 'answer.wav',
      );
      setState(() {
        _answerEvaluations[id] = res['evaluation'];
        _submittedQuestionIds.add(id);
        _answerAudioBytes = null;
        _answerAudioName = null;
        _submittingAnswer = false;
      });
      return true;
    } catch (e) {
      setState(() => _submittingAnswer = false);
      _showSnack('Could not submit answer: $e', AppTheme.errorRed);
      return false;
    }
  }

  Future<void> _prepareAvatarForCurrentQuestion() async {
    if (_questions.isEmpty) return;
    final q = _questions[_qIndex];
    final qText = q['questionText'] ?? q['question_text'] ?? '';
    final questionId = (q['questionId'] ?? q['question_id'] ?? qText).toString();
    if (qText.toString().trim().isEmpty) return;

    try {
      final talk = _avatarTalkCache[questionId] ?? await ApiService().createAvatarTalk(qText.toString());
      _avatarTalkCache[questionId] = talk;
      if (talk['provider'] == 'local-demo' || talk['configured'] == false) {
        if (mounted) {
          setState(() {
            _loadingAvatar = false;
            _avatarTalk = talk;
            _avatarVideoReady = false;
          });
        }
        await _speakQuestion(qText.toString());
        return;
      }

      setState(() {
        _loadingAvatar = true;
        _avatarTalk = null;
        _avatarVideoReady = false;
      });
      await _avatarController?.dispose();
      _avatarController = null;

      var latest = talk;
      final talkId = talk['talkId'];
      if (talkId != null && talk['videoUrl'] == null) {
        for (var i = 0; i < 40; i++) {
          if (mounted) setState(() => _avatarTalk = latest);
          await Future.delayed(const Duration(seconds: 3));
          latest = await ApiService().getAvatarTalkStatus(talkId.toString());
          _avatarTalkCache[questionId] = latest;
          if (latest['videoUrl'] != null) break;
          if (latest['status'] == 'error' || latest['status'] == 'failed') break;
        }
      }
      await _setAvatarTalk(latest);
    } catch (e) {
      if (mounted) {
        setState(() {
          _avatarTalk = {'message': 'Avatar video failed: $e'};
          _loadingAvatar = false;
        });
      }
    }
  }

  Future<void> _speakQuestion(String text) async {
    if (text.trim().isEmpty) return;
    _ttsAvailable = true;
    try {
      await _questionPlayer.stop();
      await _tts.stop();
      _sendTalkingHeadMessage('stop');
      if (mounted) setState(() => _speakingQuestion = true);
      _sendTalkingHeadMessage('speak', text: text);
      final audio = await ApiService().synthesizeQuestionSpeech(text);
      await _questionPlayer.play(BytesSource(Uint8List.fromList(audio)));
    } catch (e) {
      debugPrint('Piper question TTS failed, falling back to browser voice: $e');
      if (!_ttsAvailable) {
        if (mounted) setState(() => _speakingQuestion = false);
        return;
      }
      try {
        await _tts.stop();
        if (mounted) setState(() => _speakingQuestion = true);
        _sendTalkingHeadMessage('speak', text: text);
        await _tts.speak(text);
      } catch (fallbackError) {
        if (mounted) {
          setState(() {
            _speakingQuestion = false;
          });
        }
        debugPrint('Question TTS failed: $fallbackError');
      }
    }
  }

  Future<void> _repeatCurrentQuestion() async {
    if (_questions.isEmpty) return;
    final q = _questions[_qIndex];
    final qText = q['questionText'] ?? q['question_text'] ?? '';
    if (qText.toString().trim().isEmpty) return;
    await _speakQuestion(qText.toString());
  }

  Future<void> _setAvatarTalk(Map<String, dynamic> talk) async {
    final videoUrl = talk['videoUrl']?.toString();
    if (videoUrl == null || videoUrl.isEmpty) {
      if (mounted) setState(() { _avatarTalk = talk; _loadingAvatar = false; });
      return;
    }

    final controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
    try {
      await controller.initialize();
      await controller.setLooping(false);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await _avatarController?.dispose();
      setState(() {
        _avatarController = controller;
        _avatarVideoReady = true;
        _avatarTalk = talk;
        _loadingAvatar = false;
      });
      try {
        await controller.play();
      } catch (e) {
        debugPrint('Avatar autoplay blocked: $e');
      }
    } catch (e) {
      await controller.dispose();
      if (mounted) {
        setState(() {
          _avatarTalk = {
            ...talk,
            'message': 'Avatar video was created but could not play here. ${talk['videoUrl'] ?? ''} $e',
          };
          _loadingAvatar = false;
        });
      }
    }
  }

  Map<String, dynamic>? _mergeProfile(Map<String, dynamic>? current, dynamic next) {
    if (next is! Map) return current;
    final merged = <String, dynamic>{if (current != null) ...current};
    next.forEach((key, value) {
      if (value != null) merged[key.toString()] = value;
    });
    return merged;
  }

  String _profileValue(String key, String fallback) {
    final value = _candidateProfile?[key];
    if (value == null || value.toString().trim().isEmpty) return fallback;
    return value.toString();
  }

  String _projectSummary() {
    final projects = _candidateProfile?['projects'] ?? _candidateProfile?['significant_projects'];
    if (projects is! List || projects.isEmpty) return 'No projects detected yet';
    final names = projects.take(2).map((p) {
      if (p is Map) return (p['name'] ?? p['title'] ?? p['description'] ?? '').toString();
      return p.toString();
    }).where((p) => p.trim().isNotEmpty).toList();
    return names.isEmpty ? 'No projects detected yet' : names.join(', ');
  }

  Future<void> _finishInterview() async {
    if (_sessionId == null) return;
    final uid = AuthService().uid ?? '';
    setState(() => _extracting = true);
    try {
      final res = await ApiService().completeInterview(_sessionId!, uid);
      setState(() {
        _reportId = res['reportId'];
        _phase = 3;
        _extracting = false;
      });
    } catch (e) {
      setState(() => _extracting = false);
      _showSnack('Could not complete interview: $e', AppTheme.errorRed);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg), backgroundColor: color,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: _phase == 0 ? _skillExtractionView()
          : _phase == 1 ? _setupView()
          : _phase == 2 ? _activeMeetingView()
          : _completeView(),
    );
  }

  // ─── Phase 0: Skill Extraction ────────────────────────────────────────────
  Widget _skillExtractionView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _glassCard(padding: 22, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Mock Interview', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textDark)),
        const SizedBox(height: 4),
        const Text('Extract your skills from resume or GitHub to customize your interview',
            style: TextStyle(fontSize: 14, color: AppTheme.textGray)),
      ])),
      const SizedBox(height: 20),
      _glassCard(padding: 24, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Extract Skills', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
        const SizedBox(height: 16),

        // Resume upload
        _sourceBox(
          icon: Icons.upload_file, title: 'Upload Resume',
          subtitle: _resumeFileName != null ? 'Selected: $_resumeFileName' : 'PDF, DOC, DOCX supported',
          buttonLabel: _extracting ? 'Extracting...' : 'Choose File',
          onTap: _extracting ? null : _pickResume,
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Divider(color: Colors.grey.shade300)),
          const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('OR', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textGray))),
          Expanded(child: Divider(color: Colors.grey.shade300)),
        ]),
        const SizedBox(height: 16),

        // GitHub
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Icon(Icons.code, color: AppTheme.primaryCyan), const SizedBox(width: 8), const Text('GitHub Profile', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark))]),
            const SizedBox(height: 12),
            TextField(controller: _githubCtrl, decoration: AppTheme.inputDecoration('github.com/username', icon: Icons.link)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: _extracting ? null : _extractFromGitHub,
              icon: const Icon(Icons.download, size: 18),
              label: Text(_extracting ? 'Extracting...' : 'Extract Skills'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryCyan, foregroundColor: Colors.white),
            ),
          ]),
        ),
        const SizedBox(height: 24),
        const Divider(color: Colors.grey),
        const SizedBox(height: 18),

        const Text('Your Skills', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _skillCtrl, decoration: AppTheme.inputDecoration('Add a skill manually'), onSubmitted: (_) => _addSkill())),
          const SizedBox(width: 8),
          IconButton(onPressed: _addSkill, icon: const Icon(Icons.add_circle, color: AppTheme.primaryCyan, size: 32)),
        ]),
        const SizedBox(height: 12),
        if (_extractedSkills.isEmpty)
          const Text('No skills added yet. Upload resume, link GitHub, or add manually.',
              style: TextStyle(fontSize: 13, color: AppTheme.textGray))
        else
          Wrap(spacing: 8, runSpacing: 8, children: _extractedSkills.map(_skillChip).toList()),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity, height: 50,
          child: ElevatedButton(
            onPressed: _extractedSkills.isEmpty ? null : _saveSkillsAndContinue,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryCyan, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              disabledBackgroundColor: AppTheme.primaryCyan.withOpacity(0.5),
            ),
            child: const Text('Continue to Interview Setup', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ])),
    ]);
  }

  // ─── Phase 1: Setup ────────────────────────────────────────────────────────
  Widget _setupView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _glassCard(padding: 22, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Interview Profile', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textDark)),
        const SizedBox(height: 4),
        const Text('Review the resume and GitHub context before starting', style: TextStyle(fontSize: 14, color: AppTheme.textGray)),
      ])),
      const SizedBox(height: 20),
      _glassCard(padding: 24, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _profileTile('Detected Role', _profileValue('field', 'General Interview'))),
          const SizedBox(width: 12),
          Expanded(child: _profileTile('Experience Level', _profileValue('seniority', 'Beginner'))),
        ]),
        const SizedBox(height: 12),
        _profileTile('Projects Found', _projectSummary()),
        const SizedBox(height: 20),

        const Text('Interview Type', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: _types.mapIndexed((i, t) =>
            _choiceChip(t, _selectedType == i, () => setState(() => _selectedType = i))).toList()),
        const SizedBox(height: 20),

        const Text('Question Count', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: _questionCounts.mapIndexed((i, count) =>
            _choiceChip('$count questions', _selectedQuestionCount == i, () => setState(() => _selectedQuestionCount = i))).toList()),
        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: AppTheme.primaryCyan.withOpacity(0.05), borderRadius: BorderRadius.circular(10), border: Border.all(color: AppTheme.primaryCyan.withOpacity(0.2))),
          child: Row(children: [
            const Icon(Icons.check_circle_outline, color: AppTheme.primaryCyan, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text('${_extractedSkills.length} skills ready: ${_extractedSkills.take(3).join(', ')}${_extractedSkills.length > 3 ? '...' : ''}',
                style: const TextStyle(fontSize: 13, color: AppTheme.textDark))),
          ]),
        ),
        const SizedBox(height: 24),

        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () => setState(() => _phase = 0),
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: Colors.grey.shade300)),
            child: const Text('← Back', style: TextStyle(color: AppTheme.textGray, fontWeight: FontWeight.w600)),
          )),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton(
            onPressed: _extracting ? null : _startInterview,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryCyan, foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _extracting
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Generating Questions...'),
            ])
                : const Text('Start Interview 🎤', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          )),
        ]),
      ])),
    ]);
  }

  // ─── Phase 2: Active Interview ─────────────────────────────────────────────
  Widget _activeMeetingView() {
    if (_questions.isEmpty) return const Center(child: CircularProgressIndicator());
    final q = _questions[_qIndex];
    final total = _questions.length;
    final qText = (q['questionText'] ?? q['question_text'] ?? 'Loading question...').toString();
    final skillTag = (q['skillTag'] ?? q['skill_tag'] ?? '').toString();
    final questionId = (q['questionId'] ?? q['question_id'] ?? '').toString();
    final evaluation = _answerEvaluations[questionId];

    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 820;
      final stageHeight = compact ? 720.0 : 650.0;
      final hasDraftAnswer = _answerAudioName != null;
      final hasSubmittedAnswer = _submittedQuestionIds.contains(questionId);
      final hasAnswer = hasDraftAnswer || hasSubmittedAnswer;
      final answerStatus = _recording
          ? 'Recording'
          : hasDraftAnswer
              ? 'Draft ready'
              : hasSubmittedAnswer
                  ? 'Submitted'
                  : 'Listening';
      final canContinue = !_submittingAnswer && !_recording;

      return Container(
        height: stageHeight,
        decoration: BoxDecoration(
          color: const Color(0xFF020617),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.20),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF020617), Color(0xFF111827), Color(0xFF0F172A)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 16,
            child: Row(children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(color: AppTheme.successGreen, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Live interview',
                  style: TextStyle(color: Colors.white.withOpacity(0.92), fontSize: 14, fontWeight: FontWeight.w800),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.white.withOpacity(0.10), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  'Question ${_qIndex + 1}/$total',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800),
                ),
              ),
              if (skillTag.trim().isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: AppTheme.primaryCyan.withOpacity(0.18), borderRadius: BorderRadius.circular(8)),
                  child: Text(
                    skillTag,
                    style: const TextStyle(color: AppTheme.primaryCyan, fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ]),
          ),
          Positioned(
            left: 18,
            right: 18,
            top: 56,
            bottom: compact ? 230 : 154,
            child: Stack(children: [
              Positioned.fill(
                child: _callTile(
                  name: 'AI Interviewer',
                  subtitle: _loadingAvatar ? 'Preparing' : (_speakingQuestion ? 'Speaking' : 'Ready'),
                  child: _avatarView(),
                ),
              ),
              Positioned(
                right: 14,
                bottom: 14,
                width: compact ? 190 : 280,
                height: compact ? 132 : 176,
                child: _callTile(
                  name: AuthService().fullName ?? 'You',
                  subtitle: answerStatus,
                  child: _candidateView(compact: true),
                ),
              ),
            ]),
          ),
          Positioned(
            left: 18,
            right: 18,
            bottom: compact ? 142 : 86,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.70),
                border: Border.all(color: Colors.white.withOpacity(0.10)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 280),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.18),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  );
                },
                child: Text(
                  qText,
                  key: ValueKey('${_qIndex}_$qText'),
                  textAlign: TextAlign.center,
                  maxLines: compact ? 4 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    height: 1.35,
                  ),
                ),
              ),
            ),
          ),
          if (_questionChanging)
            Positioned(
              left: 18,
              right: 18,
              bottom: compact ? 142 : 86,
              child: IgnorePointer(
                child: Container(
                  height: compact ? 104 : 78,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(
                      colors: [
                        AppTheme.primaryCyan.withOpacity(0.20),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if ((_loadingAvatar || _shouldShowAvatarStatus()) && !_avatarVideoReady)
            Positioned(
              left: 18,
              right: 18,
              bottom: compact ? 104 : 48,
              child: Text(
                _avatarStatusText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white.withOpacity(0.58), fontSize: 12),
              ),
            ),
          if (evaluation is Map)
            Positioned(
              left: 18,
              right: 18,
              bottom: compact ? 104 : 48,
              child: Text(
                'Score: ${evaluation['overallScore'] ?? '-'}%  ${evaluation['feedback'] ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.successGreen, fontSize: 12, fontWeight: FontWeight.w700),
              ),
            ),
          Positioned(
            left: 18,
            right: 18,
            bottom: 18,
            child: compact
                ? Column(children: [
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      _roundControl(
                        icon: Icons.upload_file,
                        tooltip: 'Upload answer audio',
                        onPressed: _submittingAnswer || _recording ? null : _pickAnswerAudio,
                      ),
                      const SizedBox(width: 10),
                      _roundControl(
                        icon: _recording ? Icons.stop : Icons.mic,
                        tooltip: _recording ? 'Stop recording' : 'Record answer',
                        onPressed: _submittingAnswer ? null : _toggleRecording,
                        active: _recording,
                        large: true,
                      ),
                      const SizedBox(width: 10),
                      _roundControl(
                        icon: Icons.volume_up,
                        tooltip: 'Repeat question',
                        onPressed: _recording ? null : _repeatCurrentQuestion,
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      if (_qIndex > 0) ...[
                        Expanded(
                          child: _meetingButton(
                            label: 'Previous',
                            icon: Icons.arrow_back,
                            onPressed: () => _goToQuestion(_qIndex - 1),
                            outlined: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        flex: 2,
                        child: _meetingButton(
                          label: _qIndex == total - 1 ? 'Finish' : 'Next',
                          icon: _qIndex == total - 1 ? Icons.check : Icons.arrow_forward,
                          onPressed: canContinue ? _nextQuestion : null,
                          success: _qIndex == total - 1,
                        ),
                      ),
                    ]),
                  ])
                : Row(children: [
                    if (_qIndex > 0) ...[
                      _meetingButton(
                        label: 'Previous',
                        icon: Icons.arrow_back,
                        onPressed: () => _goToQuestion(_qIndex - 1),
                        outlined: true,
                      ),
                      const SizedBox(width: 12),
                    ],
                    const Spacer(),
                    _roundControl(
                      icon: Icons.upload_file,
                      tooltip: 'Upload answer audio',
                      onPressed: _submittingAnswer || _recording ? null : _pickAnswerAudio,
                    ),
                    const SizedBox(width: 12),
                    _roundControl(
                      icon: _recording ? Icons.stop : Icons.mic,
                      tooltip: _recording ? 'Stop recording' : 'Record answer',
                      onPressed: _submittingAnswer ? null : _toggleRecording,
                      active: _recording,
                      large: true,
                    ),
                    const SizedBox(width: 12),
                    _roundControl(
                      icon: Icons.volume_up,
                      tooltip: 'Repeat question',
                      onPressed: _recording ? null : _repeatCurrentQuestion,
                    ),
                    const Spacer(),
                    _meetingButton(
                      label: _qIndex == total - 1 ? 'Finish' : 'Next',
                      icon: _qIndex == total - 1 ? Icons.check : Icons.arrow_forward,
                      onPressed: canContinue ? _nextQuestion : null,
                      success: _qIndex == total - 1,
                    ),
                  ]),
          ),
          Positioned(
            left: 18,
            bottom: compact ? 104 : 50,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: hasAnswer && !compact ? 1 : 0,
              child: Text(
                hasDraftAnswer ? _answerAudioName! : 'Submitted answer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.58), fontSize: 12),
              ),
            ),
          ),
        ]),
      );
    });
  }

  Widget _activeView() {
    if (_questions.isEmpty) return const Center(child: CircularProgressIndicator());
    final q = _questions[_qIndex];
    final total = _questions.length;
    final qText = q['questionText'] ?? q['question_text'] ?? 'Loading question...';
    final skillTag = q['skillTag'] ?? q['skill_tag'] ?? '';
    final questionId = (q['questionId'] ?? q['question_id'] ?? '').toString();
    final evaluation = _answerEvaluations[questionId];
    final hasDraftAnswer = _answerAudioName != null;
    final hasSubmittedAnswer = _submittedQuestionIds.contains(questionId);
    final hasAnswer = hasDraftAnswer || hasSubmittedAnswer;
    final answerStatus = _recording
        ? 'Recording answer...'
        : hasDraftAnswer
            ? 'Draft ready'
            : hasSubmittedAnswer
                ? 'Submitted'
                : 'Listening';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _glassCard(padding: 20, child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Question ${_qIndex + 1} of $total', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: AppTheme.textDark)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(color: AppTheme.primaryCyan.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
            child: Text(skillTag, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryCyan)),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
          value: (_qIndex + 1) / total, minHeight: 6,
          backgroundColor: Colors.grey.shade200,
          valueColor: const AlwaysStoppedAnimation(AppTheme.primaryCyan),
        )),
      ])),
      const SizedBox(height: 20),

      _glassCard(padding: 18, child: Column(children: [
        Row(children: [
          Expanded(child: _callTile(
            name: 'AI Interviewer',
            subtitle: _loadingAvatar ? 'Preparing question...' : (_speakingQuestion ? 'Speaking' : 'Ready'),
            child: _avatarView(),
          )),
          const SizedBox(width: 14),
          Expanded(child: _callTile(
            name: AuthService().fullName ?? 'You',
            subtitle: answerStatus,
            child: _candidateView(),
          )),
        ]),
        if ((_loadingAvatar || _shouldShowAvatarStatus()) && !_avatarVideoReady) ...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.grey.shade200)),
            child: Text(
              _avatarStatusText(),
              style: const TextStyle(fontSize: 12, color: AppTheme.textGray),
            ),
          ),
        ],
        const SizedBox(height: 20),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.primaryCyan.withOpacity(0.05),
            borderRadius: BorderRadius.circular(16),
            border: const Border(left: BorderSide(color: AppTheme.primaryCyan, width: 3)),
          ),
          child: Text('"$qText"', style: const TextStyle(fontSize: 16, color: AppTheme.textDark, fontStyle: FontStyle.italic, height: 1.5)),
        ),
        const SizedBox(height: 28),

        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          TextButton.icon(
            onPressed: _submittingAnswer || _recording ? null : _pickAnswerAudio,
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Upload audio file instead'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.primaryCyan),
          ),
          if (hasAnswer) ...[
            const SizedBox(width: 12),
            Text(hasDraftAnswer ? _answerAudioName! : 'Submitted answer', style: const TextStyle(fontSize: 13, color: AppTheme.textGray)),
          ],
        ],
        ),
        TextButton.icon(
          onPressed: _recording ? null : _repeatCurrentQuestion,
          icon: const Icon(Icons.volume_up, size: 18),
          label: const Text('Repeat question'),
          style: TextButton.styleFrom(foregroundColor: AppTheme.textGray),
        ),
        if (evaluation is Map) ...[
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: AppTheme.successGreen.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: AppTheme.successGreen.withOpacity(0.25))),
            child: Text(
              'Score: ${evaluation['overallScore'] ?? '-'}%  ${evaluation['feedback'] ?? ''}',
              style: const TextStyle(fontSize: 13, color: AppTheme.textDark),
            ),
          ),
        ],
        const SizedBox(height: 24),

        Row(children: [
          if (_qIndex > 0) ...[
            Expanded(child: OutlinedButton(
              onPressed: () => _goToQuestion(_qIndex - 1),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: Colors.grey.shade300)),
              child: const Text('← Previous', style: TextStyle(color: AppTheme.textGray)),
            )),
            const SizedBox(width: 12),
          ],
          Expanded(flex: 2, child: ElevatedButton(
            onPressed: _submittingAnswer ? null : _nextQuestion,
            style: ElevatedButton.styleFrom(
              backgroundColor: _qIndex == total - 1 ? AppTheme.successGreen : AppTheme.primaryCyan,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: Text(_qIndex == total - 1 ? 'Finish Interview ✓' : 'Next Question →',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          )),
        ]),
      ])),
    ]);
  }

  // ─── Phase 3: Complete ─────────────────────────────────────────────────────
  Widget _completeView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _glassCard(padding: 40, child: Column(children: [
        Container(width: 88, height: 88,
            decoration: BoxDecoration(color: AppTheme.successGreen.withOpacity(0.12), shape: BoxShape.circle),
            child: const Icon(Icons.check_circle_outline, color: AppTheme.successGreen, size: 50)),
        const SizedBox(height: 20),
        const Text('Interview Complete! 🎉',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppTheme.textDark), textAlign: TextAlign.center),
        const SizedBox(height: 10),
        const Text('Great job! Your answers have been recorded and evaluated.',
            style: TextStyle(fontSize: 14, color: AppTheme.textGray), textAlign: TextAlign.center),
        const SizedBox(height: 32),

        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: AppTheme.primaryCyan.withOpacity(0.05), borderRadius: BorderRadius.circular(14), border: Border.all(color: AppTheme.primaryCyan.withOpacity(0.2))),
          child: Column(children: [
            _summaryRow('Questions Answered', '${_submittedQuestionIds.length}/${_questions.length}'),
            const SizedBox(height: 10),
            _summaryRow('Skills Covered', _extractedSkills.take(3).join(', ')),
            const SizedBox(height: 10),
            _summaryRow('Report ID', _reportId ?? '—'),
          ]),
        ),
        const SizedBox(height: 28),

        Column(children: [
          SizedBox(width: double.infinity, height: 50,
            child: ElevatedButton(
              onPressed: () => context.go('/performance-report'),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryCyan, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('View Performance Report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, height: 50,
            child: OutlinedButton(
              onPressed: () => setState(() {
                _phase = 0;
                _qIndex = 0;
                _sessionId = null;
                _questions = [];
                _reportId = null;
                _answerAudioBytes = null;
                _answerAudioName = null;
                _answerEvaluations.clear();
                _submittedQuestionIds.clear();
              }),
              style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: Colors.grey.shade300)),
              child: const Text('Start New Interview', style: TextStyle(color: AppTheme.textGray, fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.go('/dashboard'),
            child: const Text('← Back to Dashboard', style: TextStyle(color: AppTheme.primaryCyan, fontWeight: FontWeight.w600)),
          ),
        ]),
      ])),
    ]);
  }

  // ── Shared Widgets ─────────────────────────────────────────────────────────

  Widget _sourceBox({required IconData icon, required String title, required String subtitle, required String buttonLabel, VoidCallback? onTap}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.grey.shade200)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Icon(icon, color: AppTheme.primaryCyan), const SizedBox(width: 8), Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppTheme.textDark))]),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(fontSize: 13, color: AppTheme.textGray)),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.file_upload, size: 18),
          label: Text(buttonLabel),
          style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryCyan, foregroundColor: Colors.white),
        ),
      ]),
    );
  }

  Widget _skillChip(String skill) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: AppTheme.primaryCyan.withOpacity(0.1), border: Border.all(color: AppTheme.primaryCyan), borderRadius: BorderRadius.circular(18)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(skill, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.primaryCyan)),
      const SizedBox(width: 6),
      GestureDetector(onTap: () => _removeSkill(skill), child: const Icon(Icons.close, size: 16, color: AppTheme.primaryCyan)),
    ]),
  );

  Widget _choiceChip(String label, bool selected, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? AppTheme.primaryCyan : Colors.white,
        border: Border.all(color: selected ? AppTheme.primaryCyan : Colors.grey.shade300),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : AppTheme.textGray)),
    ),
  );

  Widget _roundControl({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool active = false,
    bool large = false,
  }) {
    final size = large ? 66.0 : 48.0;
    final color = active ? AppTheme.errorRed : AppTheme.primaryCyan;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: size,
        height: size,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            shape: const CircleBorder(),
            padding: EdgeInsets.zero,
            backgroundColor: onPressed == null ? Colors.white.withOpacity(0.10) : color,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
          child: Icon(icon, size: large ? 30 : 22),
        ),
      ),
    );
  }

  Widget _meetingButton({
    required String label,
    required IconData icon,
    required VoidCallback? onPressed,
    bool outlined = false,
    bool success = false,
  }) {
    final bg = success ? AppTheme.successGreen : AppTheme.primaryCyan;
    if (outlined) {
      return OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: BorderSide(color: Colors.white.withOpacity(0.20)),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.white.withOpacity(0.12),
        disabledForegroundColor: Colors.white.withOpacity(0.45),
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        elevation: 0,
      ),
    );
  }

  Widget _avatarView() {
    if (_avatarVideoReady && _avatarController != null) {
      return GestureDetector(
        onTap: () {
          final controller = _avatarController;
          if (controller == null) return;
          controller.value.isPlaying ? controller.pause() : controller.play();
          setState(() {});
        },
        child: Stack(
          alignment: Alignment.center,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.black,
                child: AspectRatio(
                  aspectRatio: _avatarController!.value.aspectRatio,
                  child: VideoPlayer(_avatarController!),
                ),
              ),
            ),
            if (!_avatarController!.value.isPlaying)
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.play_arrow, color: Colors.white, size: 34),
              ),
          ],
          ),
      );
    }

    return Container(
      height: double.infinity,
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              image: DecorationImage(
                image: AssetImage('assets/images/interview_room.jpg'),
                fit: BoxFit.cover,
                opacity: 0.55,
              ),
              gradient: LinearGradient(
                colors: [Color(0xCC0F172A), Color(0x991D4ED8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: HtmlElementView(
            viewType: _talkingHeadViewType,
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.black.withOpacity(0.10),
                  Colors.black.withOpacity(0.34),
                ],
                stops: const [0.0, 0.62, 1.0],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ),
        if (_loadingAvatar)
          const Center(
            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          ),
        if (_speakingQuestion)
          Positioned(
            top: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.successGreen.withOpacity(0.9),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.volume_up, color: Colors.white, size: 14),
                SizedBox(width: 5),
                Text('Speaking', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _candidateView({bool compact = false}) {
    return GestureDetector(
      onTap: _submittingAnswer ? null : _toggleRecording,
      child: Container(
        height: double.infinity,
        width: double.infinity,
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: compact ? 58 : 88,
              height: compact ? 58 : 88,
              decoration: BoxDecoration(
                color: _recording ? AppTheme.errorRed : AppTheme.primaryCyan,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: (_recording ? AppTheme.errorRed : AppTheme.primaryCyan).withOpacity(0.35), blurRadius: 18)],
              ),
              child: Icon(_recording ? Icons.stop : Icons.mic, color: Colors.white, size: compact ? 28 : 40),
            ),
            SizedBox(height: compact ? 8 : 14),
            Text(
              _answerAudioName ?? (_recording ? 'Recording...' : 'Tap to record'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: compact ? 12 : 14),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _callTile({required String name, required String subtitle, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF020617),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        child,
        Positioned(
          left: 10,
          right: 10,
          bottom: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              Icon(subtitle.contains('Recording') ? Icons.fiber_manual_record : Icons.mic,
                  size: 14, color: subtitle.contains('Recording') ? AppTheme.errorRed : AppTheme.successGreen),
              const SizedBox(width: 7),
              Expanded(child: Text('$name · $subtitle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
            ]),
          ),
        ),
      ]),
    );
  }

  String _avatarStatusText() {
    if (_loadingAvatar) {
      final status = _avatarTalk?['status']?.toString();
      final talkId = _avatarTalk?['talkId']?.toString();
      if (status != null && status.isNotEmpty) {
        return 'Preparing avatar video... status: $status${talkId != null ? ' ($talkId)' : ''}';
      }
      return 'Preparing avatar question video...';
    }
    return _avatarTalk?['message']?.toString()
        ?? _avatarTalk?['videoUrl']?.toString()
        ?? 'Avatar video is still processing. Try waiting a few seconds.';
  }

  bool _shouldShowAvatarStatus() {
    final message = _avatarTalk?['message']?.toString() ?? '';
    if (message.startsWith('Local avatar mode is active')) return false;
    return _avatarTalk != null;
  }

  Widget _profileTile(String label, String value) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.65),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.grey.shade200),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.textGray)),
      const SizedBox(height: 6),
      Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppTheme.textDark),
      ),
    ]),
  );

  Widget _summaryRow(String key, String value) => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
    children: [
      Text(key, style: const TextStyle(fontSize: 13, color: AppTheme.textGray)),
      Flexible(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.textDark), overflow: TextOverflow.ellipsis)),
    ],
  );

  @override
  void dispose() {
    _sendTalkingHeadMessage('stop');
    _talkingHeadFrame?.src = 'about:blank';
    _tts.stop();
    _questionPlayer.dispose();
    _avatarController?.dispose();
    _recorder.dispose();
    _skillCtrl.dispose();
    _githubCtrl.dispose();
    super.dispose();
  }
}

Widget _glassCard({required Widget child, double padding = 20}) {
  return Container(
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.75),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: Colors.white.withOpacity(0.8), width: 1.5),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 24, offset: const Offset(0, 6))],
    ),
    padding: EdgeInsets.all(padding),
    child: child,
  );
}
