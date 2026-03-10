import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_commons/google_mlkit_commons.dart';
import 'package:path_provider/path_provider.dart';

/// Barkodu/VIN'i otomatik okur:
/// - Okunan VIN, expectedVin ile eşleşirse:
///   - VIN'in kısa süre stabil kaldığını doğrular (bulanık foto riskini azaltır)
///   - Otomatik foto çeker
///   - Fotoğrafı uygulama dizinine kaydeder: Documents/<VIN>/<siraNo>.jpg
///   - (opsiyonel) PC'ye upload eder: POST {apiBaseUrl}/upload-photo
///   - true döndürür (KontrolScreen -> OK -> sonraki kontrole geçer)
/// - Eşleşmiyorsa:
///   - Uyarı gösterir
///   - Ekrandan çıkmaz (sonraki kontrole geçirmez)
class BarcodeAutoCaptureScreen extends StatefulWidget {
  final String expectedVin;
  final int siraNo;

  /// Opsiyonel: PC API baseUrl (örn: http://192.168.1.10:5000)
  /// Verilirse çekilen fotoğrafı PC'ye upload eder: POST {apiBaseUrl}/upload-photo
  final String? apiBaseUrl;

  const BarcodeAutoCaptureScreen({
    super.key,
    required this.expectedVin,
    required this.siraNo,
    this.apiBaseUrl,
  });

  @override
  State<BarcodeAutoCaptureScreen> createState() => _BarcodeAutoCaptureScreenState();
}

class _UploadResult {
  final bool ok;
  final String message;
  const _UploadResult(this.ok, this.message);
}

class _BarcodeAutoCaptureScreenState extends State<BarcodeAutoCaptureScreen> {
  CameraController? _controller;
  late final BarcodeScanner _scanner;

  bool _ready = false;
  bool _busy = false;
  bool _closing = false;
  bool _capturing = false;

  // ✅ Flaş opsiyonel (varsayılan kapalı)
  bool _torchOn = false;

  String _status = "Barkodu/VIN'i kadraja getir.\nEşleşince otomatik foto çekilecek.";
  Color _statusColor = Colors.black87;

  // VIN: 17 karakter, I/O/Q yok
  final RegExp _vinInside = RegExp(r'[A-HJ-NPR-Z0-9]{17}');
  final RegExp _vinStrict = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

  // stabil okuma (QR çok erken yakalanıp bulanık foto çekmesin)
  String? _matchCandidate;
  DateTime? _matchStart;
  static const Duration _stableNeeded = Duration(milliseconds: 900);

  // mismatch mesajı spam olmasın
  DateTime _cooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  int _frame = 0;

  static const Map<DeviceOrientation, int> _orientations = <DeviceOrientation, int>{
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _scanner = BarcodeScanner();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) Navigator.pop(context, null);
        return;
      }

      final cam = cams.firstWhere(
            (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );

      // ✅ ML Kit canlı tarama için önerilen format:
      // Android: nv21 (tek plane), iOS: bgra8888 (tek plane)
      _controller = CameraController(
        cam,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();

      // ✅ Otomatik flash patlamasın: kesin kapat
      try {
        await _controller!.setFlashMode(FlashMode.off);
        _torchOn = false;
      } catch (_) {}

      await _controller!.startImageStream(_processCameraImage);

      if (!mounted) return;
      setState(() => _ready = true);
    } catch (_) {
      if (mounted) Navigator.pop(context, null);
    }
  }

  Future<void> _toggleTorch() async {
    if (_controller == null) return;

    final next = !_torchOn;
    try {
      await _controller!.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {
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
    final vin = _normalizeVin(widget.expectedVin);
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

  Future<void> _finish(bool? result) async {
    if (_closing) return;
    _closing = true;

    try {
      if (_controller?.value.isStreamingImages == true) {
        await _controller?.stopImageStream();
      }
    } catch (_) {}

    try {
      await _scanner.close();
    } catch (_) {}

    if (!mounted) return;
    Navigator.pop(context, result);
  }

  String _normalizeVin(String s) {
    return s.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }

  String? _extractVin(String raw) {
    final up = _normalizeVin(raw);

    if (up.length == 17 && _vinStrict.hasMatch(up)) return up;

    final m = _vinInside.firstMatch(up);
    final inside = m?.group(0);
    if (inside != null && _vinStrict.hasMatch(inside)) return inside;

    return null;
  }

  InputImageRotation? _getImageRotation(CameraDescription camera) {
    final sensorOrientation = camera.sensorOrientation;

    if (Platform.isIOS) {
      return InputImageRotationValue.fromRawValue(sensorOrientation);
    }

    final rotationCompensation = _orientations[_controller!.value.deviceOrientation];
    if (rotationCompensation == null) return null;

    int corrected;
    if (camera.lensDirection == CameraLensDirection.front) {
      corrected = (sensorOrientation + rotationCompensation) % 360;
    } else {
      corrected = (sensorOrientation - rotationCompensation + 360) % 360;
    }

    return InputImageRotationValue.fromRawValue(corrected);
  }

  /// ✅ google_mlkit_commons yeni sürümlerle uyumlu InputImage üretimi
  InputImage? _toInputImage(CameraImage image) {
    if (_controller == null) return null;

    final rotation = _getImageRotation(_controller!.description);
    if (rotation == null) return null;

    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;

    // Android nv21, iOS bgra8888 bekliyoruz
    if (Platform.isAndroid && format != InputImageFormat.nv21) return null;
    if (Platform.isIOS && format != InputImageFormat.bgra8888) return null;

    // Bu formatlarda tek plane olmalı
    if (image.planes.length != 1) return null;

    final plane = image.planes.first;

    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void _resetMatch() {
    _matchCandidate = null;
    _matchStart = null;
  }

  Future<String> _savePhotoToAppDir(XFile file, String vinUpper) async {
    final dir = await getApplicationDocumentsDirectory();
    final vinDir = Directory("${dir.path}/$vinUpper");
    if (!await vinDir.exists()) await vinDir.create(recursive: true);

    final path = "${vinDir.path}/${widget.siraNo}.jpg";
    final existing = File(path);
    if (await existing.exists()) await existing.delete(); // eski delil sil

    await file.saveTo(path);
    return path;
  }

  Future<void> _captureAndSave(String vinUpper) async {
    if (_controller == null || _capturing) return;
    _capturing = true;

    if (mounted) {
      setState(() {
        _status = "VIN eşleşti ✅\nFotoğraf çekiliyor...";
        _statusColor = Colors.green.shade800;
      });
    }

    try {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }

      // ✅ netlik için kısa bekleme (AF/AE otursun)
      await Future.delayed(const Duration(milliseconds: 350));

      final file = await _controller!.takePicture();
      final savedPath = await _savePhotoToAppDir(file, vinUpper);

      // ✅ PC'ye upload (baseUrl verildiyse) - başarısızsa ekranda kal
      final up = await _uploadPhotoIfNeeded(savedPath);
      if (!up.ok) {
        _resetMatch();
        _cooldownUntil = DateTime.now().add(const Duration(seconds: 1));

        if (mounted) {
          setState(() {
            _status = "Fotoğraf çekildi ama PC'ye kaydedilemedi ❌\n${up.message}\n\nWi‑Fi/host ayarını kontrol et ve tekrar okut.";
            _statusColor = Colors.red.shade700;
          });
        }

        try {
          if (_controller != null && _controller!.value.isInitialized) {
            await _controller!.startImageStream(_processCameraImage);
          }
        } catch (_) {}

        return;
      }

      await _finish(true);
    } catch (_) {
      // Hata: ekranda kal, tekrar tara
      _resetMatch();
      _cooldownUntil = DateTime.now().add(const Duration(seconds: 1));

      if (mounted) {
        setState(() {
          _status = "Fotoğraf çekilemedi ❌\nTekrar deneyin.";
          _statusColor = Colors.red.shade700;
        });
      }

      try {
        if (_controller != null && _controller!.value.isInitialized) {
          await _controller!.startImageStream(_processCameraImage);
        }
      } catch (_) {}
    } finally {
      _capturing = false;
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_closing || _busy || _capturing) return;
    if (DateTime.now().isBefore(_cooldownUntil)) return;

    // CPU için: her 2 frame'de 1
    _frame++;
    if (_frame.isOdd) return;

    _busy = true;

    try {
      if (_controller == null || !_controller!.value.isInitialized) return;

      final inputImage = _toInputImage(image);
      if (inputImage == null) return;

      final barcodes = await _scanner.processImage(inputImage);
      if (barcodes.isEmpty) return;

      final expected = _normalizeVin(widget.expectedVin);

      // ilk anlamlı rawValue
      String? raw;
      for (final b in barcodes) {
        final v = b.rawValue;
        if (v != null && v.trim().isNotEmpty) {
          raw = v;
          break;
        }
      }
      if (raw == null) return;

      final vin = _extractVin(raw);
      if (vin == null) return;

      if (vin != expected) {
        _resetMatch();
        _cooldownUntil = DateTime.now().add(const Duration(seconds: 2));

        if (mounted) {
          setState(() {
            _status = "Eşleşme yok ❌\nOkunan: $vin\nBeklenen: $expected\n\nDoğru parçayı okut.";
            _statusColor = Colors.red.shade700;
          });
        }
        return;
      }

      // VIN eşleşti → stabil mi?
      final now = DateTime.now();
      if (_matchCandidate != vin) {
        _matchCandidate = vin;
        _matchStart = now;

        if (mounted) {
          setState(() {
            _status = "VIN eşleşti ✅\nKadrajı sabit tut...";
            _statusColor = Colors.green.shade800;
          });
        }
        return;
      }

      final start = _matchStart ?? now;
      if (now.difference(start) >= _stableNeeded) {
        await _captureAndSave(vin);
      }
    } catch (_) {
      _resetMatch();
      _cooldownUntil = DateTime.now().add(const Duration(milliseconds: 800));

      if (mounted) {
        setState(() {
          _status = "Okuma hatası ❌\nTekrar deneyin.";
          _statusColor = Colors.red.shade700;
        });
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    try {
      _scanner.close();
    } catch (_) {}
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final expected = _normalizeVin(widget.expectedVin);

    return WillPopScope(
      onWillPop: () async {
        await _finish(null);
        return false;
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Barkod + Otomatik Foto"),
          actions: [
            IconButton(
              tooltip: _torchOn ? "Işık kapat" : "Işık aç",
              icon: Icon(_torchOn ? Icons.flash_off : Icons.flash_on),
              onPressed: _capturing ? null : _toggleTorch,
            ),
            TextButton(
              onPressed: () => _finish(null),
              child: const Text("İptal", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
        body: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_controller!),

            // üst bilgi
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: Card(
                elevation: 3,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Icon(Icons.qr_code_scanner),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Beklenen VIN: $expected\nSıra No: ${widget.siraNo}",
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // durum mesajı
            Positioned(
              left: 12,
              right: 12,
              bottom: 20,
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.92),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _status,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _statusColor,
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
