import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class PhotoCaptureScreen extends StatefulWidget {
  final String vin;
  final int siraNo;

  /// Opsiyonel: PC API baseUrl (örn: http://192.168.1.10:5000).
  /// Verilirse çekilen fotoğrafı PC'ye upload eder: POST {apiBaseUrl}/upload-photo
  final String? apiBaseUrl;

  const PhotoCaptureScreen({
    super.key,
    required this.vin,
    required this.siraNo,
    this.apiBaseUrl,
  });

  @override
  State<PhotoCaptureScreen> createState() => _PhotoCaptureScreenState();
}

class _UploadResult {
  final bool ok;
  final String message;
  const _UploadResult(this.ok, this.message);
}

class _PhotoCaptureScreenState extends State<PhotoCaptureScreen> {
  CameraController? _controller;
  bool _ready = false;
  bool _capturing = false;

  // ✅ Flaş opsiyonel (varsayılan kapalı)
  bool _torchOn = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) Navigator.pop(context, false);
        return;
      }

      final cam = cameras.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _controller!.initialize();

      // ✅ Otomatik flash patlamasın: kesin kapat
      try {
        await _controller!.setFlashMode(FlashMode.off);
        _torchOn = false;
      } catch (_) {}

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) Navigator.pop(context, false);
    }
  }

  Future<void> _toggleTorch() async {
    if (_controller == null) return;

    final next = !_torchOn;
    try {
      await _controller!.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {
      // bazı cihazlarda torch desteklenmeyebilir
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Flaş/Işık bu cihazda desteklenmiyor.')),
      );
    }
  }

  Future<_UploadResult> _uploadPhotoIfNeeded(String photoPath) async {
    final base = (widget.apiBaseUrl ?? "").trim();
    if (base.isEmpty) return const _UploadResult(true, "Upload kapalı");

    final uri = Uri.parse("$base/upload-photo");
    final boundary = "----flutter_form_${DateTime.now().millisecondsSinceEpoch}";
    final vin = widget.vin.trim().toUpperCase();
    final sira = widget.siraNo.toString();
    final f = File(photoPath);

    if (!await f.exists()) return const _UploadResult(false, "Fotoğraf dosyası bulunamadı.");

    final fileBytes = await f.readAsBytes();
    final filename = "${vin}_$sira.jpg";

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, "multipart/form-data; boundary=$boundary");

      void write(String s) => req.add(Uint8List.fromList(s.codeUnits));

      // vin
      write("--$boundary\r\n");
      write('Content-Disposition: form-data; name="vin"\r\n\r\n');
      write("$vin\r\n");

      // siraNo
      write("--$boundary\r\n");
      write('Content-Disposition: form-data; name="siraNo"\r\n\r\n');
      write("$sira\r\n");

      // file
      write("--$boundary\r\n");
      write('Content-Disposition: form-data; name="file"; filename="$filename"\r\n');
      write("Content-Type: image/jpeg\r\n\r\n");
      req.add(fileBytes);
      write("\r\n--$boundary--\r\n");

      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode < 200 || res.statusCode >= 300) {
        return _UploadResult(false, "Upload başarısız (${res.statusCode}). $body");
      }

      // body JSON ise, kaydedilen yolu yakalamaya çalış
      try {
        final decoded = jsonDecode(body);
        if (decoded is Map) {
          final p = (decoded["savedPath"] ??
              decoded["path"] ??
              decoded["file"] ??
              decoded["saved"] ??
              decoded["message"])
              ?.toString();
          if (p != null && p.trim().isNotEmpty) {
            return _UploadResult(true, "Upload OK: $p");
          }
        }
      } catch (_) {}

      return const _UploadResult(true, "Upload OK");
    } catch (e) {
      return _UploadResult(false, "Upload hatası: $e");
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _capture() async {
    if (_controller == null || !_ready || _capturing) return;

    setState(() => _capturing = true);

    try {
      final file = await _controller!.takePicture();

      final dir = await getApplicationDocumentsDirectory();
      final vinDir = Directory("${dir.path}/${widget.vin.trim().toUpperCase()}");

      if (!await vinDir.exists()) {
        await vinDir.create(recursive: true);
      }

      final path = "${vinDir.path}/${widget.siraNo}.jpg";

      final existing = File(path);
      if (await existing.exists()) {
        await existing.delete(); // eski delil sil
      }

      await file.saveTo(path);

      // ✅ PC'ye upload (baseUrl verildiyse)
      final up = await _uploadPhotoIfNeeded(path);

      if (!up.ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(up.message)),
        );
        return; // ekranda kal: tekrar çekebilir
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context, false);
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text("Fotoğraf Çek - ${widget.siraNo}"),
        actions: [
          IconButton(
            tooltip: _torchOn ? "Işık kapat" : "Işık aç",
            icon: Icon(_torchOn ? Icons.flash_off : Icons.flash_on),
            onPressed: _capturing ? null : _toggleTorch,
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          Positioned(
            left: 12,
            right: 12,
            bottom: 110,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.92),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                "Doğru açıyı yakalayınca fotoğraf çek.\nFotoğraf delil niteliğinde olmalı.",
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Positioned(
            bottom: 35,
            left: 0,
            right: 0,
            child: Center(
              child: FloatingActionButton(
                onPressed: _capturing ? null : _capture,
                child: _capturing
                    ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                    : const Icon(Icons.camera_alt),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
