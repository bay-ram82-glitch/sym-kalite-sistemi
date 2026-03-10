
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import 'photo_capture_screen.dart';
import 'barcode_auto_capture_screen.dart';




// ✅ Proses için foto/barkod+foto seçimi

// ✅ JSON'a yazmak/okumak için yardımcı (Dart enum .name derdi yok)
String captureModeToStr(CaptureMode m) {
  switch (m) {
    case CaptureMode.normal:
      return 'none';
    case CaptureMode.photo:
      return 'photo';
    case CaptureMode.barcodePhoto:
      return 'barcodePhoto';
  }
}

CaptureMode captureModeFromStr(String s) {
  final t = s.trim().toLowerCase();

  if (t == 'none' || t == 'normal') return CaptureMode.normal;

  if (t == 'barcodephoto' || t == 'barcode_photo' || t.contains('barcode')) {
    return CaptureMode.barcodePhoto;
  }
  return CaptureMode.photo;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppStorage.init();
  await AppConfig.load();
  await InMemoryStore.load();

  // ✅ Açılışta API'den modeller + kontrol türlerini çek (hata olursa sessiz geç)
  await InMemoryStore.refreshModelsFromApi(silent: true);
  await InMemoryStore.refreshKontrolTurleriFromApi(silent: true);

  // Otomatik baglanti kontrolu (ayar sayfasina girmeden)
  ApiConnection.start();

  runApp(const KaliteKontrolApp());
}


// =====================
// KALICI DEPOLAMA (SharedPreferences)
// =====================
class AppStorage {
  static late SharedPreferences sp;

  static Future<void> init() async {
    sp = await SharedPreferences.getInstance();
  }
}

// =====================
// UYGULAMA AYARLARI (USB / WIFI)
// =====================
enum ConnectionMode { usb, wifi }
enum CaptureMode {
  normal,
  photo,
  barcodePhoto,
}

class AppConfig {
  static ConnectionMode mode = ConnectionMode.usb;

  // Ayrı ayarlar: USB ve Wi-Fi
  static String usbHost = '127.0.0.1';
  static int usbPort = 5000;

  static String wifiHost = '192.168.1.20';
  static int wifiPort = 5000;

  static const String defaultTestRaporKlasoru = 'C:/TEST_RAPORLARI';
  static const String defaultKaliteRaporKlasoru = 'C:/KALITE_RAPORLARI';

  // Test raporu PDF klasor yolu (varsayilan)
  static String testRaporKlasoru = 'C:/TEST_RAPORLARI';

  static String get baseUrl {
    switch (mode) {
      case ConnectionMode.usb:
        return 'http://$usbHost:$usbPort';
      case ConnectionMode.wifi:
        return 'http://$wifiHost:$wifiPort';
    }
  }

  // Kalici anahtarlar
  static const String _kMode = 'cfg_mode';
  static const String _kUsbHost = 'cfg_usb_host';
  static const String _kUsbPort = 'cfg_usb_port';
  static const String _kWifiHost = 'cfg_wifi_host';
  static const String _kWifiPort = 'cfg_wifi_port';
  static const String _kTestPath = 'cfg_test_path';

  // Eski surum uyumlulugu (legacy)
  static const String _kHostLegacy = 'cfg_host';
  static const String _kPortLegacy = 'cfg_port';

  static Future<void> load() async {
    final sp = AppStorage.sp;

    final m = sp.getString(_kMode);
    mode = (m == 'wifi') ? ConnectionMode.wifi : ConnectionMode.usb;

    // Yeni kayitlar
    if (sp.containsKey(_kUsbHost)) usbHost = sp.getString(_kUsbHost) ?? usbHost;
    if (sp.containsKey(_kUsbPort)) usbPort = sp.getInt(_kUsbPort) ?? usbPort;

    if (sp.containsKey(_kWifiHost)) wifiHost = sp.getString(_kWifiHost) ?? wifiHost;
    if (sp.containsKey(_kWifiPort)) wifiPort = sp.getInt(_kWifiPort) ?? wifiPort;

    // Legacy: eski tek host/port -> wifi tarafina tasinabilir
    if (!sp.containsKey(_kWifiHost) && sp.containsKey(_kHostLegacy)) {
      wifiHost = sp.getString(_kHostLegacy) ?? wifiHost;
    }
    if (!sp.containsKey(_kWifiPort) && sp.containsKey(_kPortLegacy)) {
      wifiPort = sp.getInt(_kPortLegacy) ?? wifiPort;
    }

    // Guvenlik: portlar
    if (usbPort <= 0) usbPort = 5000;
    if (wifiPort <= 0) wifiPort = 5000;

    testRaporKlasoru = sp.getString(_kTestPath) ?? testRaporKlasoru;
    kaliteRaporKlasoru = sp.getString(_kKalitePath) ?? kaliteRaporKlasoru;
  }


  // Kayıt/Kalite raporu PDF klasör yolu (varsayılan)
  static String kaliteRaporKlasoru = 'C:/KALITE_RAPORLARI';

  static Future<void> save() async {
    final sp = AppStorage.sp;
    await sp.setString(_kMode, mode == ConnectionMode.wifi ? 'wifi' : 'usb');

    await sp.setString(_kUsbHost, usbHost);
    await sp.setInt(_kUsbPort, usbPort);

    await sp.setString(_kWifiHost, wifiHost);
    await sp.setInt(_kWifiPort, wifiPort);

    // Legacy key'leri de guncelle (opsiyonel)
    await sp.setString(_kHostLegacy, wifiHost);
    await sp.setInt(_kPortLegacy, wifiPort);

    await sp.setString(_kTestPath, testRaporKlasoru);
    await sp.setString(_kKalitePath, kaliteRaporKlasoru);
  }
  static const String _kKalitePath = 'cfg_kalite_path';
}


// =====================
// MODELLER / BELLEK İÇİ
// =====================

class KontrolNoktasi {
  int siraNo;
  String process; // soru
  String kontrolTuru;
  String kontrolMetni; // uyumluluk için

  // ✅ YENİ: sadece iki seçenek
  CaptureMode captureMode; // photo veya barcodePhoto

  KontrolNoktasi({
    required this.siraNo,
    required this.process,
    required this.kontrolTuru,
    required this.kontrolMetni,
    this.captureMode = CaptureMode.normal, // ✅ eski kayıtlar bozul
  });
}

// ✅ Operator: AD + PIN
class Operator {
  final String ad;
  final String pin;

  Operator({required this.ad, required this.pin});

  Map<String, dynamic> toJson() => {'ad': ad, 'pin': pin};

  factory Operator.fromJson(Map<String, dynamic> j) {
    return Operator(
      ad: (j['ad'] ?? '').toString(),
      pin: (j['pin'] ?? '').toString(),
    );
  }
}

class InMemoryStore {
  static final List<KontrolNoktasi> kontrolNoktalari = [];
  // ✅ Yedek liste (kullanılmayan ama lazım olabilecek maddeler)
  static final List<KontrolNoktasi> yedekKontrolNoktalari = [];

  // ✅ Artık final değil: API’den güncellenebilir
  static List<String> kontrolTurleri = [
    'Fonksiyonel',
    'Gorsel',
    'Olçüsel',
    'Elektriksel',
    'Mekanik',
    'Diğer',
  ];
  static List<String> modeller = ['Seçiniz'];

  static const String _kModeller = 'modeller_list';

  // ✅ Operator listesi artık Operator tipinde
  static final List<Operator> operatorler = [
    Operator(ad: 'Seçiniz', pin: ''),
    Operator(ad: 'Ali', pin: '1111'),
    Operator(ad: 'Veli', pin: '2222'),
    Operator(ad: 'Ayşe', pin: '3333'),
  ];

  // Kontrolor listesi
  static final List<String> kontrolorler = [
    'Seçiniz',
    'Mehmet',
    'Ahmet',
    'Zeynep',
  ];

  // Kalıcı anahtarlar
  static const String _kOps = 'operatorler_json';
  static const String _kKos = 'kontrolorler_list';

  // ✅ Kontrol türleri de kalıcı olsun
  static const String _kKontrolTurleri = 'kontrol_turleri_list';

  static Future<void> load() async {
    final sp = AppStorage.sp;
    final ml = sp.getStringList(_kModeller);
    if (ml != null && ml.isNotEmpty) {
      modeller = [...ml];
    }
    if (modeller.isEmpty || modeller.first != 'Seçiniz') {
      modeller.remove('Seçiniz');
      modeller.insert(0, 'Seçiniz');
    }

    // Operatorler: json list
    final opsJsonList = sp.getStringList(_kOps);
    if (opsJsonList != null && opsJsonList.isNotEmpty) {
      final loaded = <Operator>[];
      for (final s in opsJsonList) {
        try {
          final m = jsonDecode(s);
          if (m is Map<String, dynamic>) loaded.add(Operator.fromJson(m));
        } catch (_) {}
      }
      if (loaded.isNotEmpty) {
        operatorler
          ..clear()
          ..addAll(loaded);
      }
    }

    // Kontrolorler: string list
    final kos = sp.getStringList(_kKos);
    if (kos != null && kos.isNotEmpty) {
      kontrolorler
        ..clear()
        ..addAll(kos);
    }

    // ✅ Kontrol türleri: string list
    final kt = sp.getStringList(_kKontrolTurleri);
    if (kt != null && kt.isNotEmpty) {
      kontrolTurleri = [...kt];
    }

    // Güvenlik: "Seçiniz" yoksa başa ekle
    if (operatorler.isEmpty || operatorler.first.ad != 'Seçiniz') {
      operatorler.removeWhere((x) => x.ad == 'Seçiniz');
      operatorler.insert(0, Operator(ad: 'Seçiniz', pin: ''));
    }
    if (kontrolorler.isEmpty || kontrolorler.first != 'Seçiniz') {
      kontrolorler.remove('Seçiniz');
      kontrolorler.insert(0, 'Seçiniz');
    }

    // ✅ Kontrol türlerinde Diğer yoksa sona ekle (yedek gibi düşün)
    if (!kontrolTurleri.any((e) =>
    e.trim().toLowerCase() == 'diğer' || e.trim().toLowerCase() == 'diger')) {
      kontrolTurleri.add('Diğer');
    }
  }

  static Future<void> save() async {
    final sp = AppStorage.sp;

    final opsJsonList = operatorler.map((o) => jsonEncode(o.toJson())).toList();
    await sp.setStringList(_kOps, opsJsonList);
    await sp.setStringList(_kKos, kontrolorler);
    await sp.setStringList(_kModeller, modeller);
    // ✅ Kontrol türlerini de kaydet
    await sp.setStringList(_kKontrolTurleri, kontrolTurleri);
  }

  static Future<bool> refreshModelsFromApi({bool silent = false}) async {
    try {
      final fetched = await ApiClient.fetchModels();

      final cleaned = <String>['Seçiniz'];
      for (final x in fetched) {
        final t = x.trim();
        if (t.isEmpty) continue;
        if (!cleaned.any((e) => e.toLowerCase() == t.toLowerCase())) cleaned.add(t);
      }

      modeller = cleaned;
      await save();
      return true;
    } catch (_) {
      if (!silent) {}
      return false;
    }
  }

  // ✅ API’den kontrol türlerini çek + kaydet
  static Future<bool> refreshKontrolTurleriFromApi({bool silent = false}) async {
    try {
      final fetched = await ApiClient.fetchKontrolTurleri();

      // temizle + uniq
      final cleaned = <String>[];
      for (final x in fetched) {
        final t = x.trim();
        if (t.isEmpty) continue;
        if (!cleaned.any((e) => e.toLowerCase() == t.toLowerCase())) cleaned.add(t);
      }

      if (cleaned.isEmpty) return false;

      // "Diğer" yoksa ekle
      if (!cleaned.any((e) => e.toLowerCase() == 'diğer' || e.toLowerCase() == 'diger')) {
        cleaned.add('Diğer');
      }

      kontrolTurleri = cleaned;
      await save();
      return true;
    } catch (_) {
      if (!silent) {
        // silent=false ise çağıran ekran snack basacak; burada sessiz kalıyoruz
      }
      return false;
    }
  }
}

// =====================
// MODEL-BAZLI ŞABLON (Kontrol noktaları) - Kalıcı
// =====================
class TemplateStore {
  static const String _kTemplates = 'model_templates_v1';
  static const String _kTemplateOrder = 'model_templates_order_v1';
  static const int _maxTemplates = 100;

  static Map<String, dynamic> _readAll() {
    final raw = AppStorage.sp.getString(_kTemplates);
    if (raw == null || raw.trim().isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return <String, dynamic>{};
  }

  static List<String> _readOrder() {
    final list = AppStorage.sp.getStringList(_kTemplateOrder);
    if (list == null) return <String>[];
    return list.where((e) => e.trim().isNotEmpty).toList();
  }

  static List<String> getSavedModelKeysOrdered() {
    final all = _readAll();
    final order = _readOrder();

    // order'da olanları once getir (varsa)
    final out = <String>[];
    final seen = <String>{};

    for (final k in order) {
      final key = k.toString().trim();
      if (key.isEmpty) continue;

      // all içinde case-insensitive var mı?
      String? realKey;
      for (final ak in all.keys) {
        final aks = ak.toString();
        if (aks.toLowerCase() == key.toLowerCase()) {
          realKey = aks;
          break;
        }
      }
      if (realKey != null && seen.add(realKey.toLowerCase())) out.add(realKey);
    }

    // order'da yok ama all'da olanları sona ekle
    for (final ak in all.keys) {
      final aks = ak.toString();
      if (seen.add(aks.toLowerCase())) out.add(aks);
    }

    return out;
  }

  static int getTemplateItemCount(String model) {
    final m = model.trim();
    if (m.isEmpty) return 0;
    final all = _readAll();

    for (final k in all.keys) {
      final ks = k.toString();
      if (ks.toLowerCase() == m.toLowerCase()) {
        final arr = all[ks];
        if (arr is List) return arr.length;
        return 0;
      }
    }
    return 0;
  }

  static Future<void> _writeAll(Map<String, dynamic> data) async {
    await AppStorage.sp.setString(_kTemplates, jsonEncode(data));
  }

  static Future<void> _writeOrder(List<String> order) async {
    await AppStorage.sp.setStringList(_kTemplateOrder, order);
  }

  static List<String> getSavedModelKeys() {
    final all = _readAll();
    return all.keys.map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList();
  }

  static List<KontrolNoktasi> getTemplateForModel(String model) {
    final m = model.trim();
    if (m.isEmpty) return [];

    final all = _readAll();

    // ✅ Case-insensitive key bul
    String? realKey;
    for (final k in all.keys) {
      final ks = k.toString();
      if (ks.toLowerCase() == m.toLowerCase()) {
        realKey = ks;
        break;
      }
    }
    if (realKey == null) return [];

    final arr = all[realKey];
    if (arr is! List) return [];

    final out = <KontrolNoktasi>[];
    for (final e in arr) {
      if (e is Map) {
        final sira = int.tryParse((e['siraNo'] ?? '').toString()) ?? 0;
        final process = (e['process'] ?? '').toString();
        final tur = (e['kontrolTuru'] ?? '').toString();
        final metin = (e['kontrolMetni'] ?? '').toString();
        final cmStr = (e['captureMode'] ?? '').toString();
        final cm = captureModeFromStr(cmStr);
        if (sira > 0 && process.trim().isNotEmpty && tur.trim().isNotEmpty) {
          out.add(KontrolNoktasi(
            siraNo: sira,
            process: process,
            kontrolTuru: tur,
            kontrolMetni: metin,
            captureMode: cm, // ✅ NEW
          ));
        }
      }
    }
    out.sort((a, b) => a.siraNo.compareTo(b.siraNo));
    return out;
  }

  static Future<void> saveTemplateForModel(String model, List<KontrolNoktasi> list) async {
    final m = model.trim();
    if (m.isEmpty) return;

    final all = _readAll();
    final order = _readOrder();

    // ✅ Aynı model farklı büyük/küçük harfle kayıtlı olabilir: mevcut anahtarı bul
    String key = m;
    for (final k in all.keys) {
      final ks = k.toString();
      if (ks.toLowerCase() == m.toLowerCase()) {
        key = ks;
        break;
      }
    }

    final isNew = !all.keys.any((k) => k.toString().toLowerCase() == m.toLowerCase());

    // ✅ Limit doluysa: otomatik silme YOK. Yetkili silmeden yeni model kaydedilemez.
    if (isNew && order.length >= _maxTemplates) {
      throw Exception('Şablon arşivi dolu ($_maxTemplates). Yetkili silme yapmadan yeni model kaydedilemez.');
    }

    final payload = list
        .map((k) => {
      'siraNo': k.siraNo,
      'process': k.process,
      'kontrolTuru': k.kontrolTuru,
      'kontrolMetni': k.kontrolMetni,
      // ✅ NEW: Normal/Foto/Barkod+Foto kaydı
      'captureMode': captureModeToStr(k.captureMode),
    })
        .toList();

    all[key] = payload;

    // order güncelle: en üste al
    order.removeWhere((x) => x.toLowerCase() == key.toLowerCase());
    order.insert(0, key);

    await _writeAll(all);
    await _writeOrder(order);
  }

  static Future<void> deleteTemplateForModel(String model) async {
    final m = model.trim();
    if (m.isEmpty) return;

    final all = _readAll();
    final order = _readOrder();

    // ✅ case-insensitive gerçek anahtarı bul
    String? realKey;
    for (final k in all.keys) {
      final ks = k.toString();
      if (ks.toLowerCase() == m.toLowerCase()) {
        realKey = ks;
        break;
      }
    }

    if (realKey != null) {
      all.remove(realKey);
    }

    order.removeWhere((x) => x.toLowerCase() == m.toLowerCase());

    await _writeAll(all);
    await _writeOrder(order);
  }
}

// =====================
// GÜVENLİK (Ayarlar PIN)
// =====================
class SecurityStore {
  static const String _kAdminPin = 'admin_pin';

  static String get adminPin => AppStorage.sp.getString(_kAdminPin) ?? '1234';

  static Future<void> setAdminPin(String newPin) async {
    await AppStorage.sp.setString(_kAdminPin, newPin);
  }
}

// =====================
// SON OTURUM + FORM OZETİ + KONTROL CEVAPLARI
// =====================
class SessionStore {

  static List<Map<String, dynamic>> nokHatalar = [];

  // ---- Son girilenler (form ekranı)
  static String lastVin = '';
  static String lastMotorNo = '';
  static String lastKontrolor = '';
  static String lastModel = '';
  static String lastPartiNo = '';
  static String lastRenk = '';
  static String lastStokKodu = '';
  static String lastTarihSaat = '';
  static String lastMarka = "";

  // ---- Operator oturum
  static String operatorLoggedInAd = '';
  static String activeModel = '';
  static String kontrolorLoggedInAd = '';

  // ---- Kontrol sonucu ("OK" / "NOK")
  static String finalSonuc = '';

  // ---- Kontrol cevapları (soru bazında)
  // key: siraNo (1,2,3...)  value: "OK" / "NOK"
  static final Map<int, String> kontrolCevaplari = {};

  // ---- Kontrol şablonunun snapshot'ı
  static List<Map<String, dynamic>> kontrolItemsSnapshot = [];

  // ---- NOK Detay
  static String lastNokAciklama = '';
  static String lastNokKaynak = '';
  static String lastNokIstasyon = '';
  static int lastNokSiraNo = 0;

  static void setFormHeader({
    required String vin,
    required String motorNo,
    required String model,
    required String partiNo,
    required String renk,
    required String stokKodu,
    required String kontrolor,
    required String tarihSaat,
  }) {
    lastVin = vin;
    lastMotorNo = motorNo;
    lastModel = model;
    lastPartiNo = partiNo;
    lastRenk = renk;
    lastStokKodu = stokKodu;
    lastKontrolor = kontrolor;
    lastTarihSaat = tarihSaat;

    activeModel = model.trim();
  }

  static void setKontrolItemsSnapshot(List<Map<String, dynamic>> items) {
    kontrolItemsSnapshot = List<Map<String, dynamic>>.from(items);
  }

  static void setCevap({
    required int siraNo,
    required String cevap, // "OK" / "NOK"
  }) {
    kontrolCevaplari[siraNo] = cevap;
  }

  static void clearKontrolCevaplari() {
    kontrolCevaplari.clear();
    finalSonuc = '';
  }

  static void clearFormOnly() {
    lastVin = '';
    lastMotorNo = '';
    lastKontrolor = '';
    lastModel = '';
    lastMarka = '';
    lastPartiNo = '';
    lastRenk = '';
    lastStokKodu = '';
    lastTarihSaat = '';
    activeModel = '';

    clearKontrolCevaplari();
    kontrolItemsSnapshot = [];
  }

  static void clearAllIncludingOperator() {
    clearFormOnly();
    operatorLoggedInAd = '';
    kontrolorLoggedInAd = '';
  }

  static void resetForm({bool includeOperator = false}) {
    if (includeOperator) {
      clearAllIncludingOperator();
    } else {
      clearFormOnly();
    }
  }
}

// =====================
// VIN LOOKUP RESPONSE MODELI
// =====================
class ColorStock {
  final String renk;
  final String stokKodu;

  ColorStock({required this.renk, required this.stokKodu});

  factory ColorStock.fromJson(Map<String, dynamic> j) {
    return ColorStock(
      renk: (j['renk'] ?? '').toString(),
      stokKodu: (j['stokKodu'] ?? '').toString(),
    );
  }
}

enum ApiConn { unknown, ok, fail }

class ApiConnection {
  static final ValueNotifier<ApiConn> status = ValueNotifier<ApiConn>(ApiConn.unknown);
  static Timer? _t;

  static void start() {
    _t ??= Timer.periodic(const Duration(seconds: 4), (_) => checkNow());
    checkNow();
  }

  static Future<void> checkNow() async {
    final ok = await ApiClient.ping();
    status.value = ok ? ApiConn.ok : ApiConn.fail;
  }

  static void stop() {
    _t?.cancel();
    _t = null;
  }
}

class VinLookupResult {
  final String vin;
  final String marka;
  final String model;
  final String partiNo;
  final List<ColorStock> renkler;
  final bool testRaporuVar;

  VinLookupResult({
    required this.vin,
    required this.marka,
    required this.model,
    required this.partiNo,
    required this.renkler,
    required this.testRaporuVar,
  });

  factory VinLookupResult.fromJson(Map<String, dynamic> j) {
    final renklerRaw = (j['renkler'] as List?) ?? const [];

    return VinLookupResult(
      vin: (j['vin'] ?? '').toString(),
      marka: (j['marka'] ?? '').toString(),   // ✅ EKLENDİ
      model: (j['model'] ?? '').toString(),
      partiNo: (j['partiNo'] ?? '').toString(),
      renkler: renklerRaw
          .map((e) => ColorStock.fromJson(e as Map<String, dynamic>))
          .toList(),
      testRaporuVar: (j['testRaporuVar'] == true),
    );
  }
}

// =====================
// NETWORK HELPER (HttpClient)
// =====================
class ApiClient {
  // Baglanti testi (PC API ayakta mi?)
  static Future<bool> ping() async {
    final uri = Uri.parse('${AppConfig.baseUrl}/where');
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 2);

    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  static Future<VinLookupResult> vinLookup(String vin) async {
    final uri = Uri.parse(
      '${AppConfig.baseUrl}/vin-lookup'
          '?vin=${Uri.encodeQueryComponent(vin)}'
          '&testPath=${Uri.encodeQueryComponent(AppConfig.testRaporKlasoru)}',
    );

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);

    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();

      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('API format hatası');
      }

      return VinLookupResult.fromJson(decoded);
    } finally {
      client.close(force: true);
    }
  }

  // ✅ KONTROL TÜRLERİ
  static Future<List<String>> fetchKontrolTurleri() async {
    final uri = Uri.parse('${AppConfig.baseUrl}/kontrol-turleri');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);

    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();

      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('API format hatası');
      }

      final items = (decoded['items'] as List?) ?? const [];
      return items.map((e) => e.toString()).toList();
    } finally {
      client.close(force: true);
    }
  }

  // ✅ MODEL LİSTESİ
  static Future<List<String>> fetchModels() async {
    final uri = Uri.parse('${AppConfig.baseUrl}/models');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);

    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();

      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) throw Exception('API format hatası');

      final items = (decoded['items'] as List?) ?? const [];
      return items.map((e) => e.toString()).toList();
    } finally {
      client.close(force: true);
    }
  }

  // ✅ PC'deki API'ye test rapor klasorünü kaydet
  static Future<void> setTestReportsDir(String dir) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/config');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

      final payload = jsonEncode({"testReportsDir": dir});
      req.add(utf8.encode(payload));

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> setConfig(Map<String, dynamic> cfg) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/config');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 6);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

      req.add(utf8.encode(jsonEncode(cfg)));

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }
    } finally {
      client.close(force: true);
    }
  }

  // ✅ EXCEL -> "Kontrol Processleri" genel şablon
  static Future<List<KontrolNoktasi>> fetchGenelKontrolProcessleri() async {
    final uri = Uri.parse('${AppConfig.baseUrl}/kontrol-processleri');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 8);


    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close();

      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('API format hatası');
      }

      final items = (decoded['items'] as List?) ?? const [];
      final out = <KontrolNoktasi>[];


      for (final e in items) {
        if (e is Map) {
          final sira = int.tryParse((e['siraNo'] ?? '').toString()) ?? 0;
          final process = (e['process'] ?? '').toString();
          final tur = (e['kontrolTuru'] ?? '').toString();


          if (sira > 0 && process.trim().isNotEmpty && tur.trim().isNotEmpty) {
            out.add(
              KontrolNoktasi(
                siraNo: sira,
                process: process,
                kontrolTuru: tur,
                kontrolMetni: process, // uyumluluk

              ),
            );
          }
        }
      }

      out.sort((a, b) => a.siraNo.compareTo(b.siraNo));
      return out;
    } finally {
      client.close(force: true);
    }
  }
  // ✅ Kalite raporu PDF üret (PC API: /submit-report)
  static Future<Map<String, dynamic>> submitReport({
    required String tarihSaat,
    required String vin,
    required String motorNo,
    required String model,
    required String marka,
    required String partiNo,
    required String renk,
    required String stokKodu,
    required String operatorAd,
    required String kontrolorAd,
    required String sonuc, // "OK" / "NOK"
    required List<Map<String, dynamic>> items, // [{siraNo, process, kontrolTuru, cevap}]

    String? nokAciklama,
    String? nokKaynak,
    String? nokIstasyon,
    int? nokSiraNo,
    String? nokTur,
    String? nokSeviye,
    String? nokParca,
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/submit-report');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

      final payload = {
        "tarihSaat": tarihSaat,
        "vin": vin,
        "motorNo": motorNo,
        "model": model,
        "marka": marka,
        "partiNo": partiNo,
        "renk": renk,
        "stokKodu": stokKodu,
        "operator": operatorAd,
        "kontrolor": kontrolorAd,
        "sonuc": sonuc,
        "items": items,

        // 👇 BURASI ÖNEMLİ
        "hatalar": sonuc == "NOK"
            ? [
          {
            "parca": nokParca ?? "",
            "aciklama": nokAciklama ?? "",
            "tur": nokTur ?? "",
            "seviye": nokSeviye ?? "",
            "kaynak": nokKaynak ?? "",
            "istasyon": nokIstasyon ?? "",
            "kontrol_id": nokSiraNo ?? 0,
            "kontrolAdi": items
                .firstWhere(
                    (e) => e["siraNo"] == nokSiraNo,
                orElse: () => {})
            ["process"],
          }
        ]
            : [],
      };



      req.add(utf8.encode(jsonEncode(payload)));

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('API format hatası');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
  // ✅ OK kaydını DB'ye yaz (PC API: /ok-kaydet)
  static Future<Map<String, dynamic>> okKaydet({
    required String testTarihi,
    required String vin,
    required String motorNo,
    required String model,
    required String partiNo,
    required String operatorAd,
    required String kontrolorAd,
    String durum = "",
    String uretimSonuKaydi = "",
    String belgeNo = "",
    String istasyon = "",
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/ok-kaydet');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

      final payload = {
        "testTarihi": testTarihi,
        "vin": vin,
        "motorNo": motorNo,
        "model": model,
        "partiNo": partiNo,
        "operator": operatorAd,
        "kontrolor": kontrolorAd,
        "durum": durum,
        "uretimSonuKaydi": uretimSonuKaydi,
        "belgeNo": belgeNo,
        "istasyon": istasyon,
      };

      req.add(utf8.encode(jsonEncode(payload)));

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) throw Exception('API format hatası');
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  // ✅ Etiket bastır (PC API: /print-label)
  static Future<Map<String, dynamic>> printLabel({
    required String vin,
    required String motorNo,
    required String model,
    required String sonuc, // "OK" / "NOK"
    required String tarihSaat,
  }) async {
    final uri = Uri.parse('${AppConfig.baseUrl}/print-label');

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 12);

    try {
      final req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');

      final payload = {
        "vin": vin,
        "motorNo": motorNo,
        "model": model,
        "sonuc": sonuc,
        "tarihSaat": tarihSaat,
      };

      req.add(utf8.encode(jsonEncode(payload)));

      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();

      if (res.statusCode != 200) {
        throw Exception('API Hata (${res.statusCode}): $body');
      }

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) throw Exception('API format hatası');
      return decoded;
    } finally {
      client.close(force: true);
    }
  }
}

// =====================
// APP
// =====================
class KaliteKontrolApp extends StatelessWidget {
  const KaliteKontrolApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kalite Kontrol',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),

        // 🔥 TÜM YAZI SİSTEMİ TEK AĞIRLIK
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          bodyMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          bodySmall: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),

        // 🔥 TEXTFIELD İÇ YAZIYI ZORLA
        inputDecorationTheme: const InputDecorationTheme(
          labelStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          floatingLabelStyle: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          hintStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          border: OutlineInputBorder(),
        ),

        // 🔥 DROPDOWN YAZIYI ZORLA
        dropdownMenuTheme: const DropdownMenuThemeData(
          textStyle: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        ),

        // 🔥 BUTON YAZIYI ZORLA
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            textStyle: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),

        textSelectionTheme: const TextSelectionThemeData(
          cursorColor: Colors.green,
        ),
      ),
      initialRoute: '/',
      routes: {
        '/': (_) => const HomeScreen(),
        '/new': (_) => const FormBilgileriScreen(),
        '/personel': (_) => const PersonelTanimScreen(),
        '/kontrol': (_) => const KontrolScreen(),
        '/ok': (_) => const OkScreen(),
        '/nok': (_) => const SizedBox(),
        '/settings_auth': (_) => const SettingsAuthScreen(),
        '/settings': (_) => const SettingsHomeScreen(),
        '/settings_connection': (_) => const ConnectionSettingsScreen(),
        '/settings_reports': (_) => const ReportSettingsScreen(),
        '/settings_security': (_) => const SecuritySettingsScreen(),
        '/template_editor': (_) => const KontrolNoktasiEditorScreen(),
        '/template_manager': (_) => const TemplateManagerScreen(),
      },
    );
  }
}

// =====================
// ANA EKRAN
// =====================
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _showExitDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Uygulamadan Çıkış"),
        content: const Text(
          "Uygulamadan çıkmak istediğinize emin misiniz?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("İptal"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade600,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () {
              Navigator.pop(context);
              Future.delayed(const Duration(milliseconds: 200), () {
                SystemNavigator.pop();
              });
            },
            child: const Text("Evet"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kalite Kontrol')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pushNamed(context, '/new'),
                child: const Text('Yeni Kontrol Formu'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.pushNamed(context, '/settings_auth'),
                child: const Text('Ayarlar'),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFF28B82),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => _showExitDialog(context),
                child: const Text('Çıkış'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// =====================
// YENİ FORM (VIN + TEST RAPORU + SCANNER + OPERATOR PIN)
// =====================
class FormBilgileriScreen extends StatefulWidget {
  const FormBilgileriScreen({super.key});

  @override
  State<FormBilgileriScreen> createState() => _FormBilgileriScreenState();
}

class _FormBilgileriScreenState extends State<FormBilgileriScreen> {
  final _formKey = GlobalKey<FormState>();

  final _vin = TextEditingController();
  final _marka = TextEditingController();
  final _model = TextEditingController();
  final _partiNo = TextEditingController();
  final _stokKodu = TextEditingController();
  final _motorNo = TextEditingController();

  Operator? _selectedOperator;
  String? _selectedKontrolor = 'Seçiniz';

  List<ColorStock> _renkOps = [];
  String? _selectedRenk;

  bool _loading = false;
  bool? _testRaporuVar;

  Timer? _vinDebounce;
  String? _lastQueriedVin;
  static const int _vinLen = 17;

  bool _manualEntry = false;
  final FocusNode _vinFocus = FocusNode();
  final FocusNode _motorFocus = FocusNode();

  final FocusNode _scanInputFocus = FocusNode();
  final TextEditingController _scanInputCtrl = TextEditingController();
  Timer? _scanCommitTimer;
  Timer? _scanFocusKeepTimer;

  final RegExp _vinRegex = RegExp(r'^[A-Z0-9]{17}$');
  final RegExp _motorRegex = RegExp(r'^[A-Z0-9]{4,12}-[A-Z0-9]{6,12}$');

  late final String _tarihSaat;

  @override
  void initState() {
    super.initState();

    final dt = DateTime.now();
    _tarihSaat =
    '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

    _vin.addListener(_onVinChanged);
    _applyLoggedInOperator();
    _applyLoggedInKontrolor();


    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _requestScanFocus();
    });

    // Scanner fokusunu ekranda tut (ayar sayfasina girmeden barkod okusun)
    _scanFocusKeepTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_manualEntry) return;
      final r = ModalRoute.of(context);
      if (r != null && r.isCurrent != true) return;
      if (!_scanInputFocus.hasFocus) {
        _requestScanFocus();
      }
    });
  }

  void _applyLoggedInOperator() {
    final logged = (SessionStore.operatorLoggedInAd).trim();
    if (logged.isEmpty) {
      _selectedOperator = InMemoryStore.operatorler.first;
      return;
    }
    final match = InMemoryStore.operatorler.where((o) => o.ad == logged).toList();
    _selectedOperator = match.isNotEmpty ? match.first : InMemoryStore.operatorler.first;
  }

// 👇 BURAYA EKLEYECEKSİN
  void _applyLoggedInKontrolor() {
    final logged = SessionStore.kontrolorLoggedInAd.trim();

    if (logged.isEmpty) {
      _selectedKontrolor = 'Seçiniz';
      return;
    }

    final match = InMemoryStore.kontrolorler
        .where((k) => k == logged)
        .toList();

    _selectedKontrolor =
    match.isNotEmpty ? match.first : 'Seçiniz';
  }

  @override
  void dispose() {
    _vinDebounce?.cancel();
    _scanCommitTimer?.cancel();
    _scanFocusKeepTimer?.cancel();

    _vin.removeListener(_onVinChanged);

    _vin.dispose();
    _marka.dispose();
    _model.dispose();
    _partiNo.dispose();
    _stokKodu.dispose();
    _motorNo.dispose();

    _vinFocus.dispose();
    _motorFocus.dispose();
    _scanInputFocus.dispose();
    _scanInputCtrl.dispose();

    super.dispose();
  }

  void _requestScanFocus() {
    if (_manualEntry) return;
    FocusManager.instance.primaryFocus?.unfocus();
    Future.delayed(const Duration(milliseconds: 50), () {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_scanInputFocus);
      SystemChannels.textInput.invokeMethod('TextInput.hide');
      // Soft keyboard'i gizle (scanner input icin TextInputType.text kullanacagiz)
      SystemChannels.textInput.invokeMethod('TextInput.hide');
    });
  }

  InputDecoration _dec(String label) =>
      InputDecoration(labelText: label, border: const OutlineInputBorder());

  void _clearAutoFields() {
    _model.clear();
    _partiNo.clear();
    _stokKodu.clear();
    _renkOps = [];
    _selectedRenk = null;

    _testRaporuVar = null;
    _lastQueriedVin = null;
  }

  /// ✅ OK ekranında "-" gormemek için: tüm form ozetini SessionStore’a yaz.
  void _snapshotToSessionStore() {
    final vin = _vin.text.trim().toUpperCase();
    final motor = _motorNo.text.trim().toUpperCase();
    final model = _model.text.trim();
    final parti = _partiNo.text.trim();
    final renk = (_selectedRenk ?? '').trim();
    final stok = _stokKodu.text.trim();
    final koAd = (_selectedKontrolor ?? 'Seçiniz').trim();


    SessionStore.setFormHeader(
      vin: vin,
      motorNo: motor,
      model: model,
      partiNo: parti,
      renk: renk,
      stokKodu: stok,
      kontrolor: koAd,
      tarihSaat: _tarihSaat,
    );
  }

  void _onVinChanged() {
    final v = _vin.text.trim().toUpperCase();

    if (v.isEmpty) {
      _vinDebounce?.cancel();
      setState(() {
        _loading = false;
        _clearAutoFields();
      });
      return;
    }

    if (v.length != _vinLen) {
      _vinDebounce?.cancel();
      setState(() {
        _testRaporuVar = null;
        _model.clear();
        _partiNo.clear();
        _stokKodu.clear();
        _renkOps = [];
        _selectedRenk = null;
      });
      return;
    }

    _vinDebounce?.cancel();
    _vinDebounce = Timer(const Duration(milliseconds: 450), () {
      final vv = _vin.text.trim().toUpperCase();
      if (vv.length != _vinLen) return;

      if (_lastQueriedVin == vv) return;
      _lastQueriedVin = vv;

      _sorgulaVin(showSnack: false);
    });
  }

  Future<void> _sorgulaVin({bool showSnack = true}) async {
    final vin = _vin.text.trim().toUpperCase();

    if (vin.isEmpty) {
      if (showSnack) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('VIN/Şase boş olamaz')));
      }
      setState(() => _clearAutoFields());
      return;
    }

    setState(() {
      _loading = true;
      _clearAutoFields();
    });

    try {
      final r = await ApiClient.vinLookup(vin);

      setState(() {
        _model.text = r.model;

        // ✅ Model geldi: aktif modele yaz ve o modele ait şablonu otomatik yükle
        SessionStore.activeModel = r.model.trim();
        final tpl = TemplateStore.getTemplateForModel(SessionStore.activeModel);

        if (tpl.isNotEmpty) {
          InMemoryStore.kontrolNoktalari
            ..clear()
            ..addAll(tpl);
        }

        _partiNo.text = r.partiNo;

        _renkOps = r.renkler;
        _selectedRenk = null;
        _stokKodu.clear();

        _testRaporuVar = r.testRaporuVar;
      });

      // ✅ VIN’den gelenler SessionStore’a yazılsın (OK ekranı boş kalmasın)
      _snapshotToSessionStore();

      if (showSnack) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              r.testRaporuVar
                  ? 'VIN bulundu. Test raporu OK.'
                  : 'UYARI: Test raporu yok! Kalite başlatılamaz.',
            ),
          ),
        );
      }
    } catch (e) {
      setState(() => _testRaporuVar = null);
      if (showSnack) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('VIN sorgu hatası: $e')));
      }
    } finally {
      setState(() => _loading = false);
    }
  }

  void _handleScannedText(String raw) {
    final cleaned = raw.trim().toUpperCase();
    if (cleaned.isEmpty) return;

    final vinInside = RegExp(r'[A-Z0-9]{17}').firstMatch(cleaned)?.group(0);
    final motorInside =
    RegExp(r'[A-Z0-9]{4,15}-[A-Z0-9]{6,15}')
        .firstMatch(cleaned)
        ?.group(0);

    final isVin = vinInside != null && _vinRegex.hasMatch(vinInside);
    final isMotor = motorInside != null && _motorRegex.hasMatch(motorInside);

    if (!isVin && !isMotor) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Barkod tanınmadı: $raw')));
      _requestScanFocus();
      return;
    }

    if (isVin) {
      final vin = vinInside!;
      final current = _vin.text.trim().toUpperCase();
      if (current.isNotEmpty && current != vin) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('VIN zaten dolu. Üzerine yazılmadı. ($current)')),
        );
      } else {
        setState(() => _vin.text = vin);
        _sorgulaVin(showSnack: true);
      }
    }

    if (isMotor) {
      final motor = motorInside!;
      final current = _motorNo.text.trim().toUpperCase();
      if (current.isNotEmpty && current != motor) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Motor No zaten dolu. Üzerine yazılmadı. ($current)')),
        );
      } else {
        setState(() => _motorNo.text = motor);
        _snapshotToSessionStore();
      }
    }

    _requestScanFocus();
  }

  Future<void> _clearFormWithConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Verileri Temizle'),
        content: const Text('VIN / Motor ve otomatik alanlar temizlensin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Temizle')),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _vin.clear();
      _motorNo.clear();
      _clearAutoFields();
    });

    _snapshotToSessionStore();
    _requestScanFocus();
  }

  void _renkSec(String? renk) {
    setState(() {
      _selectedRenk = renk;
      final match = _renkOps.where((x) => x.renk == renk).toList();
      _stokKodu.text = match.isNotEmpty ? match.first.stokKodu : '';
    });

    _snapshotToSessionStore();
  }

  bool get _vinOk => _vinRegex.hasMatch(_vin.text.trim().toUpperCase());
  bool get _motorOk => _motorRegex.hasMatch(_motorNo.text.trim().toUpperCase());

  bool get _canStart {
    final opOk = SessionStore.operatorLoggedInAd.isNotEmpty;
    final koOk = SessionStore.kontrolorLoggedInAd.isNotEmpty;
    return _vinOk && _motorOk && opOk && koOk;
  }


  Future<bool> _askOperatorPin(Operator op) async {
    String enteredPin = '';

    return await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text('Operator Doğrulama: ${op.ad}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '*' * enteredPin.length,
                      style: const TextStyle(fontSize: 28, letterSpacing: 8),
                    ),
                  ),
                  const SizedBox(height: 16),
                  buildNumericKeypad(setState, (value) {
                    if (value == 'del') {
                      if (enteredPin.isNotEmpty) {
                        enteredPin =
                            enteredPin.substring(0, enteredPin.length - 1);
                      }
                    } else {
                      if (enteredPin.length < 6) {
                        enteredPin += value;
                      }
                    }
                  }),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('İptal'),
                ),
                ElevatedButton(
                  onPressed: () {
                    if (enteredPin != op.pin) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('PIN hatalı!')),
                      );
                      return; // ❗ dialog kapanmaz
                    }
                    Navigator.pop(context, true); // sadece doğruysa kapanır
                  },
                  child: const Text('Onayla'),
                ),
              ],
            );
          },
        );
      },
    ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final renkItems = _renkOps.map((e) => e.renk).toSet().toList();
    final operatorItems = InMemoryStore.operatorler;

    _selectedOperator ??= operatorItems.first;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Yeni Kontrol Formu'),
        actions: [
          ValueListenableBuilder<ApiConn>(
            valueListenable: ApiConnection.status,
            builder: (context, st, _) {
              final isUsb = AppConfig.mode == ConnectionMode.usb;
              final icon = isUsb ? Icons.usb : Icons.wifi;

              Color c;
              String tip;
              switch (st) {
                case ApiConn.ok:
                  c = Colors.green;
                  tip = 'Baglanti var';
                  break;
                case ApiConn.fail:
                  c = Colors.red;
                  tip = 'Baglanti yok';
                  break;
                default:
                  c = Colors.grey;
                  tip = 'Kontrol ediliyor';
              }

              return IconButton(
                tooltip: tip,
                icon: Icon(icon, color: c),
                onPressed: () async {
                  await ApiConnection.checkNow();
                  if (!context.mounted) return;
                  final ok = ApiConnection.status.value == ApiConn.ok;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text((ok ? 'Baglandi: ' : 'Baglanti yok: ') + AppConfig.baseUrl)),
                  );
                },
              );
            },
          ),
          IconButton(
            tooltip: 'Verileri Temizle',
            onPressed: _clearFormWithConfirm,
            icon: const Icon(Icons.cleaning_services_rounded),
          ),
        ],
      ),
      body: GestureDetector(
        onTap: _requestScanFocus,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                if (!_manualEntry)
                  Opacity(
                    opacity: 0.01,
                    child: SizedBox(
                      height: 48,
                      width: double.infinity,
                      child: TextField(
                        focusNode: _scanInputFocus,
                        controller: _scanInputCtrl,
                        autofocus: true,
                        keyboardType: TextInputType.none,
                        enableInteractiveSelection: false,
                        showCursor: false,
                        decoration: const InputDecoration(border: InputBorder.none),
                        onChanged: (_) {
                          _scanCommitTimer?.cancel();
                          _scanCommitTimer = Timer(const Duration(milliseconds: 120), () {
                            final raw = _scanInputCtrl.text.trim();
                            if (raw.isEmpty) return;
                            _scanInputCtrl.clear();
                            _handleScannedText(raw);
                          });
                        },
                        onSubmitted: (raw) {
                          final t = raw.trim();
                          if (t.isEmpty) return;
                          _scanInputCtrl.clear();
                          _handleScannedText(t);
                        },
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    physics: const ClampingScrollPhysics(),
                    children: [
                      Card(
                        elevation: 1,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Expanded(
                                    child: Text(
                                      'Şase / VIN',
                                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () {
                                      setState(() => _manualEntry = !_manualEntry);
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (!mounted) return;
                                        if (_manualEntry) {
                                          FocusScope.of(context).requestFocus(_vinFocus);
                                        } else {
                                          _requestScanFocus();
                                        }
                                      });
                                    },
                                    icon: Icon(_manualEntry ? Icons.lock_open : Icons.lock),
                                    label: Text(_manualEntry ? 'Manuel Açık' : 'Scanner Modu'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: _vin,
                                      focusNode: _vinFocus,
                                      readOnly: !_manualEntry,
                                      showCursor: _manualEntry,
                                      enableInteractiveSelection: _manualEntry,
                                      keyboardType: _manualEntry ? TextInputType.text : TextInputType.none,
                                      textInputAction: TextInputAction.done,
                                      decoration: _dec('VIN / Şase No').copyWith(
                                        prefixIcon:
                                        Icon(_vinOk ? Icons.verified_rounded : Icons.qr_code_scanner),
                                      ),
                                      validator: (v) {
                                        final t = (v ?? '').trim().toUpperCase();
                                        if (t.isEmpty) return 'Zorunlu alan';
                                        if (!_vinRegex.hasMatch(t)) return 'VIN 17 karakter olmalı';
                                        return null;
                                      },
                                      onTap: () {
                                        if (!_manualEntry) FocusScope.of(context).requestFocus(_scanInputFocus);
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  SizedBox(
                                    height: 56,
                                    child: ElevatedButton.icon(
                                      onPressed: _loading ? null : () => _sorgulaVin(showSnack: true),
                                      icon: _loading
                                          ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                          : const Icon(Icons.search),
                                      label: const Text('Sorgula'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _manualEntry
                                    ? 'Manuel mod açık. VIN/Motor elle girilebilir.'
                                    : 'Scanner mod açık. Barkod okut (VIN veya Motor).',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_testRaporuVar != null)
                        Card(
                          elevation: 0,
                          color: _testRaporuVar! ? const Color(0xFFEAF7EE) : const Color(0xFFFFEAEA),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: _testRaporuVar! ? const Color(0xFFB7E2C0) : const Color(0xFFF2B6B6),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  _testRaporuVar! ? Icons.verified_rounded : Icons.error_rounded,
                                  size: 26,
                                  color: _testRaporuVar! ? const Color(0xFF1B7F3A) : const Color(0xFFB42318),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _testRaporuVar! ? 'Test raporu doğrulandı' : 'Test raporu bulunamadı',
                                        style: TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w800,
                                          color: _testRaporuVar! ? const Color(0xFF1B7F3A) : const Color(0xFFB42318),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _testRaporuVar!
                                            ? 'Bu motor test istasyonundan geçmiş gorünüyor. Kalite kontrol başlatılabilir.'
                                            : 'Bu şase için PDF rapor bulunamadı. Once test tamamlanmalı.',
                                        style: TextStyle(
                                          fontSize: 12.5,
                                          color: _testRaporuVar! ? const Color(0xFF1B7F3A) : const Color(0xFFB42318),
                                          height: 1.25,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                TextFormField(
                                  controller: _motorNo,
                                  focusNode: _motorFocus,
                                  readOnly: !_manualEntry,
                                  showCursor: _manualEntry,
                                  enableInteractiveSelection: _manualEntry,
                                  keyboardType: _manualEntry ? TextInputType.text : TextInputType.none,
                                  textInputAction: TextInputAction.done,
                                  decoration: _dec('Motor No').copyWith(
                                    prefixIcon:
                                    Icon(_motorOk ? Icons.verified_rounded : Icons.qr_code_scanner),
                                  ),
                                  validator: (v) {
                                    final t = (v ?? '').trim().toUpperCase();
                                    if (t.isEmpty) return 'Zorunlu alan';
                                    if (!_motorRegex.hasMatch(t)) return 'Motor formatı hatalı';
                                    return null;
                                  },
                                  onTap: () {
                                    if (!_manualEntry) FocusScope.of(context).requestFocus(_scanInputFocus);
                                  },
                                ),

                                const SizedBox(height: 12),
                                Row(
                                  children: [

                                    Expanded(
                                      child: TextFormField(
                                        controller: _marka,
                                        decoration: _dec('Marka'),
                                        validator: (v) =>
                                        (v == null || v.isEmpty) ? 'Marka giriniz' : null,
                                      ),
                                    ),

                                    const SizedBox(width: 12),

                                    Expanded(
                                      child: TextFormField(
                                        controller: _model,
                                        enabled: false,
                                        decoration: _dec('Model (otomatik)'),
                                      ),
                                    ),

                                  ],
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  value: _selectedRenk,
                                  items: renkItems.map((r) => DropdownMenuItem(value: r, child: Text(r))).toList(),
                                  onChanged: _renkSec,
                                  decoration: _dec('Renk'),
                                  validator: (v) => (v == null || v.isEmpty) ? 'Renk seç' : null,
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _stokKodu,
                                  enabled: false,
                                  decoration: _dec('Stok Kodu (otomatik)'),
                                ),
                                const SizedBox(height: 12),
                                TextFormField(
                                  controller: _partiNo,
                                  enabled: false,
                                  decoration: _dec('Parti / Lot No (otomatik)'),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              children: [
                                TextFormField(
                                  enabled: false,
                                  initialValue: _tarihSaat,
                                  decoration: _dec('Tarih / Saat'),
                                ),
                                const SizedBox(height: 12),
                                InkWell(
                                  onTap: () async {
                                    if (SessionStore.operatorLoggedInAd.isNotEmpty) {
                                      return;
                                    }

                                    final selected = await showDialog<Operator>(
                                      context: context,
                                      builder: (_) {
                                        return AlertDialog(
                                          title: const Text("Operator Seç"),
                                          content: SizedBox(
                                            width: 300,
                                            height: 300,
                                            child: ListView(
                                              children: InMemoryStore.operatorler
                                                  .where((o) => o.ad != 'Seçiniz')
                                                  .map((op) => ListTile(
                                                title: Text(op.ad),
                                                onTap: () async {
                                                  final ok = await _askOperatorPin(op);
                                                  if (!ok) return;
                                                  Navigator.pop(context, op);
                                                },
                                              ))
                                                  .toList(),
                                            ),
                                          ),
                                        );
                                      },
                                    );

                                    if (selected == null) return;

                                    SessionStore.operatorLoggedInAd = selected.ad;

                                    setState(() {
                                      _selectedOperator = selected;
                                    });
                                  },
                                  child: InputDecorator(
                                    decoration: _dec('Operator'),
                                    child: Text(
                                      _selectedOperator?.ad ?? 'Seçiniz',
                                      style: const TextStyle(fontSize: 16),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                DropdownButtonFormField<String>(
                                  value: _selectedKontrolor,
                                  items: InMemoryStore.kontrolorler
                                      .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                                      .toList(),
                                  onChanged: (v) {
                                    setState(() => _selectedKontrolor = v);

                                    if (v != null && v != 'Seçiniz') {
                                      SessionStore.lastKontrolor = v;
                                    }

                                    _snapshotToSessionStore();
                                  },
                                  decoration: _dec('Kontrolor'),
                                  validator: (v) => (v == null || v == 'Seçiniz') ? 'Kontrolor seç' : null,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: ElevatedButton(
                      onPressed: _canStart
                          ? () {
                        if (_formKey.currentState?.validate() != true) return;

                        _snapshotToSessionStore();
                        Navigator.pushNamed(context, '/kontrol');
                      }
                          : null,
                      child: const Text('Kontrole Başla', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =====================
// KONTROL EKRANI
// =====================
enum KontrolCevap { ok, nok }

class KontrolScreen extends StatefulWidget {
  const KontrolScreen({super.key});

  @override
  State<KontrolScreen> createState() => _KontrolScreenState();
}

class _KontrolScreenState extends State<KontrolScreen> {
  late final List<KontrolNoktasi> _sorular;
  int index = 0;
  bool anyNok = false;

  @override
  void initState() {
    super.initState();

    SessionStore.clearKontrolCevaplari();

    _sorular = [...InMemoryStore.kontrolNoktalari]
      ..sort((a, b) => a.siraNo.compareTo(b.siraNo));

    final snap = _sorular
        .map((k) => {
      "siraNo": k.siraNo,
      "process": k.process,
      "kontrolTuru": k.kontrolTuru,
    })
        .toList();

    SessionStore.setKontrolItemsSnapshot(snap);
  }

  Future<void> _handleOk(KontrolNoktasi item) async {
    if (item.captureMode == CaptureMode.normal) {
      _next(KontrolCevap.ok);
      return;
    }

    if (item.captureMode == CaptureMode.photo) {
      final photoOk = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PhotoCaptureScreen(
            vin: SessionStore.lastVin,
            siraNo: item.siraNo,
            apiBaseUrl: AppConfig.baseUrl,
          ),
        ),
      );

      if (photoOk == true) _next(KontrolCevap.ok);
      if (photoOk == false) _next(KontrolCevap.nok);
      return;
    }

    if (item.captureMode == CaptureMode.barcodePhoto) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => BarcodeAutoCaptureScreen(
            expectedVin: SessionStore.lastVin,
            siraNo: item.siraNo,
            apiBaseUrl: AppConfig.baseUrl,
          ),
        ),
      );

      if (result == true) _next(KontrolCevap.ok);
      if (result == false) _next(KontrolCevap.nok);
      return; // null ise (iptal) hiçbir şey yapma
    }
  }

  void _next(KontrolCevap cevap) {
    final item = _sorular[index];

    // Cevabı kaydet
    SessionStore.setCevap(
      siraNo: item.siraNo,
      cevap: (cevap == KontrolCevap.ok) ? 'OK' : 'NOK',
    );

    // ❗ Eğer NOK ise test burada biter
    if (cevap == KontrolCevap.nok) {
      SessionStore.finalSonuc = 'NOK';

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => NokScreen(
            siraNo: item.siraNo,
            process: item.process,
            kontrolTuru: item.kontrolTuru,
          ),
        ),
      );

      return;
    }

    // OK ise devam et
    if (index < _sorular.length - 1) {
      setState(() => index++);
    } else {
      SessionStore.finalSonuc = 'OK';
      Navigator.pushReplacementNamed(context, '/ok');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sorular.isEmpty) {
      return const Scaffold(
        body: Center(child: Text("Kontrol noktası yok")),
      );
    }

    final item = _sorular[index];
    final total = _sorular.length;

    return Scaffold(
      appBar: AppBar(
        title: Text('KONTROL ${index + 1} / $total'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: Text(
                  item.process,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _handleOk(item),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                    ),
                    child: const Text(
                      "OK",
                      style: TextStyle(fontSize: 28),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => _next(KontrolCevap.nok),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red,
                    ),
                    child: const Text(
                      "NOK",
                      style: TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}


// =====================
// AYARLAR - PIN
// =====================
class SettingsAuthScreen extends StatefulWidget {
  const SettingsAuthScreen({super.key});

  @override
  State<SettingsAuthScreen> createState() => _SettingsAuthScreenState();
}

class _SettingsAuthScreenState extends State<SettingsAuthScreen> {
  final _pin = TextEditingController();

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _kontrol() {
    if (_pin.text.trim() == SecurityStore.adminPin) {
      Navigator.pushReplacementNamed(context, '/settings');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yetkisiz / PIN hatalı')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Yetkili Girişi')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(onPressed: _kontrol, child: const Text('Giriş')),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// AYARLAR ANA MENÜ
// =====================
class SettingsHomeScreen extends StatelessWidget {
  const SettingsHomeScreen({super.key});

  Widget _tile(BuildContext context, IconData icon, String title, String subtitle, String route) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.pushNamed(context, route),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            _tile(context, Icons.wifi, 'Bağlantı Ayarları', 'USB / Wi-Fi, IP, Port', '/settings_connection'),
            _tile(context, Icons.folder, 'Rapor Ayarları', 'Test raporu klasorü', '/settings_reports'),
            _tile(context, Icons.lock, 'Güvenlik', 'Ayarlar PIN değiştir', '/settings_security'),
            _tile(context, Icons.list_alt, 'Kontrol Noktaları', 'Kontrol noktası ekle/çıkar', '/template_editor'),
            _tile(context, Icons.inventory_2_outlined, 'Şablon Arşivi', 'Kaydedilen şablonları yonet', '/template_manager'),
            _tile(context, Icons.people, 'Personel', 'Operator/Kontrolor tanımla', '/personel'),
          ],
        ),
      ),
    );
  }
}

// =====================
// AYARLAR - BAĞLANTI
// =====================
class ConnectionSettingsScreen extends StatefulWidget {
  const ConnectionSettingsScreen({super.key});

  @override
  State<ConnectionSettingsScreen> createState() => _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  late ConnectionMode _mode;

  final _usbHost = TextEditingController();
  final _usbPort = TextEditingController();

  final _wifiHost = TextEditingController();
  final _wifiPort = TextEditingController();

  @override
  void initState() {
    super.initState();
    _mode = AppConfig.mode;

    _usbHost.text = AppConfig.usbHost;
    _usbPort.text = AppConfig.usbPort.toString();

    _wifiHost.text = AppConfig.wifiHost;
    _wifiPort.text = AppConfig.wifiPort.toString();
  }

  @override
  void dispose() {
    _usbHost.dispose();
    _usbPort.dispose();
    _wifiHost.dispose();
    _wifiPort.dispose();
    super.dispose();
  }

  InputDecoration _decSmall(String label, {String? hint}) {
    return InputDecoration(
      border: const OutlineInputBorder(),
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Future<void> _save() async {
    final usbPort = int.tryParse(_usbPort.text.trim());
    final wifiPort = int.tryParse(_wifiPort.text.trim());

    if (usbPort == null || usbPort <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('USB port gecersiz')));
      return;
    }
    if (wifiPort == null || wifiPort <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wi-Fi port gecersiz')));
      return;
    }

    AppConfig.mode = _mode;

    AppConfig.usbHost = (_usbHost.text.trim().isEmpty) ? AppConfig.usbHost : _usbHost.text.trim();
    AppConfig.usbPort = usbPort;

    AppConfig.wifiHost = (_wifiHost.text.trim().isEmpty) ? AppConfig.wifiHost : _wifiHost.text.trim();
    AppConfig.wifiPort = wifiPort;

    await AppConfig.save();

    // Baglanti durumunu da aninda yenile
    await ApiConnection.checkNow();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved. BaseURL: ${AppConfig.baseUrl}')),
      );
    }
    setState(() {});
  }

  Future<void> _testNow() async {
    await ApiConnection.checkNow();
    if (!mounted) return;
    final st = ApiConnection.status.value;
    final ok = st == ApiConn.ok;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'API OK' : 'API FAIL')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isUsb = _mode == ConnectionMode.usb;
    final isWifi = _mode == ConnectionMode.wifi;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Settings'),
        actions: [
          ValueListenableBuilder<ApiConn>(
            valueListenable: ApiConnection.status,
            builder: (_, st, __) {
              Color c;
              switch (st) {
                case ApiConn.ok:
                  c = Colors.green;
                  break;
                case ApiConn.fail:
                  c = Colors.red;
                  break;
                default:
                  c = Colors.grey;
              }
              return IconButton(
                tooltip: 'Test',
                icon: Icon(Icons.cloud_done, color: c),
                onPressed: _testNow,
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            DropdownButtonFormField<ConnectionMode>(
              value: _mode,
              items: const [
                DropdownMenuItem(value: ConnectionMode.usb, child: Text('USB (adb reverse / localhost)')),
                DropdownMenuItem(value: ConnectionMode.wifi, child: Text('Wi-Fi (PC IP)')),
              ],
              onChanged: (v) => setState(() => _mode = v ?? ConnectionMode.usb),
              decoration: _decSmall('Mode'),
            ),

            const SizedBox(height: 16),
            const Text('USB', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            TextField(
              controller: _usbHost,
              enabled: true,
              decoration: _decSmall('USB Host', hint: '127.0.0.1'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _usbPort,
              keyboardType: TextInputType.number,
              decoration: _decSmall('USB Port', hint: '5000'),
            ),

            const SizedBox(height: 18),
            const Text('Wi-Fi', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            TextField(
              controller: _wifiHost,
              enabled: true,
              decoration: _decSmall('Wi-Fi Host (PC IP)', hint: '192.168.1.20'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _wifiPort,
              keyboardType: TextInputType.number,
              decoration: _decSmall('Wi-Fi Port', hint: '5000'),
            ),

            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _save,
                      child: const Text('Save'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _testNow,
                    child: const Text('Test'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('Active BaseURL: ${AppConfig.baseUrl}'),
            const SizedBox(height: 6),
            Text(isUsb ? 'Active Mode: USB' : 'Active Mode: Wi-Fi'),
          ],
        ),
      ),
    );
  }
}


// =====================
// AYARLAR - RAPOR
// =====================
class ReportSettingsScreen extends StatefulWidget {
  const ReportSettingsScreen({super.key});

  @override
  State<ReportSettingsScreen> createState() => _ReportSettingsScreenState();
}

class _ReportSettingsScreenState extends State<ReportSettingsScreen> {
  final _testPath = TextEditingController();
  final _kalitePath = TextEditingController();

  @override
  void initState() {
    super.initState();
    _testPath.text = AppConfig.testRaporKlasoru;
    _kalitePath.text = AppConfig.kaliteRaporKlasoru;
  }

  @override
  void dispose() {
    _testPath.dispose();
    _kalitePath.dispose();
    super.dispose();
  }

  InputDecoration _decSmall(String label, {String? hint}) {
    return InputDecoration(
      border: const OutlineInputBorder(),
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding:
      const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
    );
  }

  ButtonStyle _mainButtonStyle({Color? color}) {
    return ElevatedButton.styleFrom(
      backgroundColor: color,
      minimumSize: const Size(double.infinity, 52),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      textStyle: const TextStyle(fontWeight: FontWeight.w500),
    );
  }

  Future<void> _kaydet() async {
    final p = _testPath.text.trim();
    if (p.isEmpty) return;
    final k = _kalitePath.text.trim();
    if (k.isEmpty) return;

    try {
      await ApiClient.setConfig({
        "testReportsDir": p,
        "kaliteReportsDir": k,
      });

      AppConfig.testRaporKlasoru = p;
      AppConfig.kaliteRaporKlasoru = k;
      await AppConfig.save();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
              Text('PC ve tablet için rapor klasörü kaydedildi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kaydedilemedi: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Rapor Ayarları')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _testPath,
              decoration: _decSmall(
                  'Test Rapor Klasörü',
                  hint: 'Orn: C:/TEST_RAPORLARI'),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: _mainButtonStyle(),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Gözat'),
                    onPressed: () async {
                      String tempPath = _testPath.text;

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dialogCtx) => AlertDialog(
                          title: const Text('Test rapor klasörü'),
                          content: TextField(
                            controller:
                            TextEditingController(text: tempPath),
                            onChanged: (v) => tempPath = v,
                            decoration:
                            _decSmall('Klasör yolu'),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, false),
                              child: const Text('Vazgeç'),
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, true),
                              child: const Text('Seç'),
                            ),
                          ],
                        ),
                      );

                      if (!mounted) return;
                      if (ok == true) {
                        setState(() {
                          _testPath.text = tempPath.trim();
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: _mainButtonStyle(),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Varsayılan'),
                    onPressed: () {
                      _testPath.text =
                          AppConfig.defaultTestRaporKlasoru;
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            TextField(
              controller: _kalitePath,
              decoration: _decSmall(
                  'Kayıt Rapor Klasörü',
                  hint: 'Orn: C:/KALITE_RAPORLARI'),
            ),
            const SizedBox(height: 10),

            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: _mainButtonStyle(),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Gözat'),
                    onPressed: () async {
                      String tempPath = _kalitePath.text;

                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (dialogCtx) => AlertDialog(
                          title:
                          const Text('Kayıt rapor klasörü'),
                          content: TextField(
                            controller:
                            TextEditingController(text: tempPath),
                            onChanged: (v) => tempPath = v,
                            decoration:
                            _decSmall('Klasör yolu'),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, false),
                              child: const Text('Vazgeç'),
                            ),
                            ElevatedButton(
                              onPressed: () =>
                                  Navigator.pop(dialogCtx, true),
                              child: const Text('Seç'),
                            ),
                          ],
                        ),
                      );

                      if (!mounted) return;
                      if (ok == true) {
                        setState(() {
                          _kalitePath.text =
                              tempPath.trim();
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    style: _mainButtonStyle(),
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('Varsayılan'),
                    onPressed: () {
                      _kalitePath.text =
                          AppConfig.defaultKaliteRaporKlasoru;
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            ElevatedButton(
              style: _mainButtonStyle(),
              onPressed: _kaydet,
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// AYARLAR - GÜVENLİK
// =====================
class SecuritySettingsScreen extends StatefulWidget {
  const SecuritySettingsScreen({super.key});

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  final _oldPin = TextEditingController();
  final _newPin = TextEditingController();
  final _newPin2 = TextEditingController();

  @override
  void dispose() {
    _oldPin.dispose();
    _newPin.dispose();
    _newPin2.dispose();
    super.dispose();
  }

  Future<void> _degistir() async {
    final oldPin = _oldPin.text.trim();
    final n1 = _newPin.text.trim();
    final n2 = _newPin2.text.trim();

    if (oldPin != SecurityStore.adminPin) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mevcut PIN hatalı.')));
      return;
    }
    if (n1.length < 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yeni PIN en az 4 haneli olmalı.')),
      );
      return;
    }
    if (n1 != n2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yeni PIN’ler uyuşmuyor.')));
      return;
    }

    await SecurityStore.setAdminPin(n1);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ayarlar PIN güncellendi.')));
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Güvenlik')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _oldPin,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Mevcut PIN'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newPin,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Yeni PIN'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _newPin2,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Yeni PIN (Tekrar)'),
            ),
            const SizedBox(height: 14),
            SizedBox(height: 52, child: ElevatedButton(onPressed: _degistir, child: const Text('PIN Değiştir'))),
          ],
        ),
      ),
    );
  }
}

// =====================
// KONTROL NOKTASI EKLE/ÇIKAR (Soru = Process) + Yedek Liste
// =====================
class KontrolNoktasiEditorScreen extends StatefulWidget {
  const KontrolNoktasiEditorScreen({super.key});

  @override
  State<KontrolNoktasiEditorScreen> createState() => _KontrolNoktasiEditorScreenState();
}

class _KontrolNoktasiEditorScreenState extends State<KontrolNoktasiEditorScreen> {
  final _process = TextEditingController();
  final _siraNo = TextEditingController();

  String? _selectedKontrolTuru;
  CaptureMode _selectedCaptureMode = CaptureMode.normal;
  int? _selectedIndex;
  int? _selectedBackupIndex;

  String _selectedModel = ''; // ✅ model seçimi

  @override
  void initState() {
    super.initState();

    _selectedKontrolTuru = InMemoryStore.kontrolTurleri.isNotEmpty ? InMemoryStore.kontrolTurleri.first : null;

    // ✅ aktif model varsa onu seç
    _selectedModel = (SessionStore.activeModel).trim();
    if (_selectedModel.isEmpty) {
      // kayıtlı şablon varsa onu seç
      final keys = TemplateStore.getSavedModelKeys();
      if (keys.isNotEmpty) _selectedModel = keys.first;
    }

    // ✅ Ekran açılınca API'den modeller + kontrol türlerini yenile
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_refreshMetaFromApi(silent: true));
    });
  }

  Future<void> _refreshMetaFromApi({bool silent = false}) async {
    final okModels = await InMemoryStore.refreshModelsFromApi(silent: true);
    final okTur = await InMemoryStore.refreshKontrolTurleriFromApi(silent: true);

    if (!mounted) return;

    setState(() {
      if (_selectedKontrolTuru == null || !InMemoryStore.kontrolTurleri.contains(_selectedKontrolTuru)) {
        _selectedKontrolTuru = InMemoryStore.kontrolTurleri.isNotEmpty ? InMemoryStore.kontrolTurleri.first : null;
      }

      if (InMemoryStore.modeller.isNotEmpty) {
        if (_selectedModel.isEmpty || !InMemoryStore.modeller.contains(_selectedModel)) {
          final saved = TemplateStore.getSavedModelKeys();
          final pick = saved.firstWhere(
                (k) => InMemoryStore.modeller.contains(k),
            orElse: () => InMemoryStore.modeller.first,
          );
          _selectedModel = pick;
        }
      }
    });

    if (!silent && mounted) {
      final msg = (okModels || okTur) ? 'API güncellendi.' : 'API’den veri alınamadı.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  void dispose() {
    _process.dispose();
    _siraNo.dispose();
    super.dispose();
  }

  InputDecoration _dec(String label) => InputDecoration(labelText: label, border: const OutlineInputBorder());

  void _resetInputs({bool resetModel = false}) {
    _process.clear();
    _siraNo.clear();

    _selectedKontrolTuru = InMemoryStore.kontrolTurleri.isNotEmpty ? InMemoryStore.kontrolTurleri.first : null;
    _selectedIndex = null;
    _selectedBackupIndex = null;

    if (resetModel) {
      _selectedModel = '';
      SessionStore.activeModel = '';
    }
  }

  void _temizleAll() {
    setState(() {
      _resetInputs(resetModel: true);
      InMemoryStore.kontrolNoktalari.clear();
      InMemoryStore.yedekKontrolNoktalari.clear();
    });
  }

  void _duzenle() {
    if (_selectedIndex == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aktif listeden satır seç')));
      return;
    }

    final sira = int.tryParse(_siraNo.text.trim());
    final soru = _process.text.trim();
    final kt = (_selectedKontrolTuru ?? '').trim();

    if (sira == null || soru.isEmpty || kt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sıra No, Process(Soru) ve Kontrol Türü zorunlu')),
      );
      return;
    }

    setState(() {
      final item = InMemoryStore.kontrolNoktalari[_selectedIndex!];
      item.siraNo = sira;
      item.process = soru;
      item.kontrolTuru = kt;
      item.kontrolMetni = soru;
      item.captureMode = _selectedCaptureMode;
      InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));
      _resetInputs();
    });
  }

  void _sil() {
    if (_selectedIndex == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aktif listeden satır seç')));
      return;
    }
    setState(() {
      InMemoryStore.kontrolNoktalari.removeAt(_selectedIndex!);
      _resetInputs();
    });
  }

  void _satirSec(int index) {
    final item = InMemoryStore.kontrolNoktalari[index];
    setState(() {
      _selectedIndex = index;
      _selectedBackupIndex = null;
      _siraNo.text = item.siraNo.toString();
      _process.text = item.process;
      _selectedKontrolTuru = item.kontrolTuru;

      _selectedCaptureMode = item.captureMode;
    });
  }

  void _yedekSatirSec(int index) {
    final item = InMemoryStore.yedekKontrolNoktalari[index];
    setState(() {
      _selectedBackupIndex = index;
      _selectedIndex = null;
      _siraNo.text = item.siraNo.toString();
      _process.text = item.process;
      _selectedKontrolTuru = item.kontrolTuru;

      _selectedCaptureMode = item.captureMode;
    });
  }

  void _yedegeAl() {
    if (_selectedIndex == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Yedeğe almak için aktif listeden satır seç')));
      return;
    }
    setState(() {
      final item = InMemoryStore.kontrolNoktalari.removeAt(_selectedIndex!);
      InMemoryStore.yedekKontrolNoktalari.add(item);
      _resetInputs();
    });
  }

  void _geriAl() {
    if (_selectedBackupIndex == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Geri almak için yedek listeden satır seç')));
      return;
    }
    setState(() {
      final item = InMemoryStore.yedekKontrolNoktalari.removeAt(_selectedBackupIndex!);
      InMemoryStore.kontrolNoktalari.add(item);
      InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));
      _resetInputs();
    });
  }

  void _ekle() {
    if (_selectedBackupIndex != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yedekten geri almak için "Geri Al" butonunu kullanın.')),
      );
      return;
    }

    final sira = int.tryParse(_siraNo.text.trim());
    final process = _process.text.trim();
    final kt = (_selectedKontrolTuru ?? '').trim();

    if (sira == null || process.isEmpty || kt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sıra No, Process ve Kontrol Türü zorunlu')),
      );
      return;
    }

    setState(() {
      InMemoryStore.kontrolNoktalari.add(
        KontrolNoktasi(
          siraNo: sira,
          process: process,
          kontrolTuru: kt,
          kontrolMetni: process,
          captureMode: _selectedCaptureMode,
        ),
      );

      InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));
      _resetInputs();
    });
  }

  Future<void> _exceldenGenelSablonCek() async {
    try {
      final list = await ApiClient.fetchGenelKontrolProcessleri();
      if (list.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Excel şablonu boş geldi.')));
        return;
      }
      setState(() {
        InMemoryStore.kontrolNoktalari
          ..clear()
          ..addAll(list);
        InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));
        InMemoryStore.yedekKontrolNoktalari.clear();
        _resetInputs();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Excel’den genel şablon yüklendi (${list.length} madde).')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Excel şablonu çekilemedi: $e')));
    }
  }

  Future<void> _seciliModeliYukle() async {
    final m = _selectedModel.trim();
    if (m.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Model seçiniz.')));
      return;
    }
    final tpl = TemplateStore.getTemplateForModel(m);
    setState(() {
      InMemoryStore.kontrolNoktalari
        ..clear()
        ..addAll(tpl);
      InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));
      InMemoryStore.yedekKontrolNoktalari.clear();
      _resetInputs();
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Şablon yüklendi: $m (${tpl.length})')));
  }

  Future<void> _seciliModeliKaydet() async {
    final m = _selectedModel.trim();
    if (m.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Model seçiniz.')));
      return;
    }
    if (InMemoryStore.kontrolNoktalari.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Aktif şablon boş. Once madde ekleyin.')));
      return;
    }

    try {
      await TemplateStore.saveTemplateForModel(m, InMemoryStore.kontrolNoktalari);
      final count = TemplateStore.getSavedModelKeys().length;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Şablon kaydedildi: $m ($count/100)')));
      setState(() {});
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kaydedilemedi: $e')));
    }
  }

  Future<bool> _requireAdminPin() async {
    final pinCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Yetkili Onayı'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Silme işlemi için yetkili PIN giriniz.'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Devam')),
        ],
      ),
    );

    if (ok != true) return false;

    final entered = pinCtrl.text.trim();
    if (entered == SecurityStore.adminPin) return true;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yetkisiz / PIN hatalı')));
    }
    return false;
  }

  Future<void> _seciliModeliSil() async {
    final m = _selectedModel.trim();
    if (m.isEmpty) return;

    final authed = await _requireAdminPin();
    if (!authed) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Şablonu Sil'),
        content: Text('$m şablonu silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
        ],
      ),
    );

    if (ok != true) return;

    await TemplateStore.deleteTemplateForModel(m);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Şablon silindi: $m')));

    final keys = TemplateStore.getSavedModelKeys();
    setState(() {
      _selectedModel = SessionStore.activeModel.trim();
      if (_selectedModel.isEmpty && keys.isNotEmpty) _selectedModel = keys.first;
    });
  }

  Future<void> _kontrolTurleriniYenile() async {
    final ok = await InMemoryStore.refreshKontrolTurleriFromApi(silent: true);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _selectedKontrolTuru = InMemoryStore.kontrolTurleri.first;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kontrol türleri güncellendi (${InMemoryStore.kontrolTurleri.length})')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kontrol türleri güncellenemedi.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final aktif = InMemoryStore.kontrolNoktalari;
    final yedek = InMemoryStore.yedekKontrolNoktalari;

    final savedModels = TemplateStore.getSavedModelKeys();
    final activeModel = SessionStore.activeModel.trim();

    final apiModels = InMemoryStore.modeller
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty && e.toLowerCase() != 'seçiniz')
        .toList();

    final seen = <String>{};
    final modelOptions = <String>[];

    void addOpt(String v) {
      final t = v.trim();
      if (t.isEmpty) return;
      final key = t.toLowerCase();
      if (seen.add(key)) modelOptions.add(t);
    }

    if (activeModel.isNotEmpty) addOpt(activeModel);
    for (final m in apiModels) {
      addOpt(m);
    }
    for (final m in savedModels) {
      addOpt(m);
    }

    if (_selectedModel.trim().isEmpty && modelOptions.isNotEmpty) {
      _selectedModel = modelOptions.first;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kontrol Noktaları'),
        actions: [
          IconButton(
            tooltip: 'Kontrol Türlerini Yenile (API)',
            onPressed: _kontrolTurleriniYenile,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: ListView(
                children: [
                  Card(
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          DropdownButtonFormField<String>(
                            value: _selectedModel.trim().isEmpty ? null : _selectedModel,
                            items: modelOptions.map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                            onChanged: (v) => setState(() => _selectedModel = (v ?? '').trim()),
                            decoration: _dec('Model Seç (aktif / kayıtlı / Excel modelleri)'),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _seciliModeliYukle,
                                  icon: const Icon(Icons.download),
                                  label: const Text('Yükle'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: ElevatedButton.icon(
                                  onPressed: _seciliModeliKaydet,
                                  icon: const Icon(Icons.save),
                                  label: const Text('Kaydet'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _seciliModeliSil,
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Şablonu Sil'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _exceldenGenelSablonCek,
                                  icon: const Icon(Icons.table_view),
                                  label: const Text('Excel’den Çek'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              activeModel.isEmpty ? 'Aktif model: (VIN okunmadı)' : 'Aktif model: $activeModel',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 10),
                  TextField(controller: _process, decoration: _dec('Process (Soru)')),

                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _selectedKontrolTuru,
                    items: InMemoryStore.kontrolTurleri.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                    onChanged: (v) => setState(() => _selectedKontrolTuru = v),
                    decoration: _dec('Kontrol Türü'),
                  ),

                  const SizedBox(height: 12),
                  DropdownButtonFormField<CaptureMode>(
                    value: _selectedCaptureMode,
                    items: const [
                      DropdownMenuItem(
                        value: CaptureMode.normal,
                        child: Text("Normal"),
                      ),
                      DropdownMenuItem(
                        value: CaptureMode.photo,
                        child: Text("Foto Çek"),
                      ),
                      DropdownMenuItem(
                        value: CaptureMode.barcodePhoto,
                        child: Text("Barkod + Foto"),
                      ),
                    ],
                    onChanged: (v) => setState(() => _selectedCaptureMode = v ?? CaptureMode.photo),
                    decoration: _dec('Ozel Kontrol'),
                  ),

                  const SizedBox(height: 12),
                  TextField(
                    controller: _siraNo,
                    decoration: _dec('Sıra No'),
                    keyboardType: TextInputType.number,
                  ),

                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: ElevatedButton(onPressed: _ekle, child: const Text('EKLE'))),
                      const SizedBox(width: 8),
                      Expanded(child: ElevatedButton(onPressed: _duzenle, child: const Text('DÜZENLE'))),
                    ],
                  ),

                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton(
                          onPressed: _sil,
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                          child: const Text('SİL', style: TextStyle(color: Colors.white)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton(onPressed: _temizleAll, child: const Text('TEMİZLE'))),
                    ],
                  ),

                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _yedegeAl,
                          icon: const Icon(Icons.archive_outlined),
                          label: const Text('Yedeğe Al'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _geriAl,
                          icon: const Icon(Icons.unarchive_outlined),
                          label: const Text('Geri Al'),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 16), // en alta biraz boşluk
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              flex: 6,
              child: Column(
                children: [
                  Expanded(
                    child: _listBox(
                      title: 'AKTİF ŞABLON',
                      emptyText: 'Aktif şablonda kayıt yok',
                      items: aktif,
                      selectedIndex: _selectedIndex,
                      selectedColor: Colors.blue.withOpacity(0.12),
                      onTap: _satirSec,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _listBox(
                      title: 'YEDEK LİSTE',
                      emptyText: 'Yedek listede kayıt yok',
                      items: yedek,
                      selectedIndex: _selectedBackupIndex,
                      selectedColor: Colors.orange.withOpacity(0.14),
                      onTap: _yedekSatirSec,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _listBox({
    required String title,
    required String emptyText,
    required List<KontrolNoktasi> items,
    required int? selectedIndex,
    required Color selectedColor,
    required void Function(int) onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black26),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.black26))),
            child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(child: Text(emptyText))
                : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = items[i];
                final selected = selectedIndex == i;
                return InkWell(
                  onTap: () => onTap(i),
                  child: Container(
                    color: selected ? selectedColor : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Row(
                      children: [
                        SizedBox(width: 70, child: Text(item.siraNo.toString())),
                        Expanded(child: Text(item.process)),
                        SizedBox(width: 120, child: Text(item.kontrolTuru)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// =====================
// ŞABLON ARŞİVİ
// =====================
class TemplateManagerScreen extends StatefulWidget {
  const TemplateManagerScreen({super.key});

  @override
  State<TemplateManagerScreen> createState() => _TemplateManagerScreenState();
}

class _TemplateManagerScreenState extends State<TemplateManagerScreen> {
  final _q = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  InputDecoration _decSmall(String label, {String? hint}) {
    return InputDecoration(
      border: const OutlineInputBorder(),
      labelText: label,
      hintText: hint,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }

  Future<bool> _requireAdminPin() async {
    final pinCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Yetkili Onayı'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Silme işlemi için yetkili PIN giriniz.'),
            const SizedBox(height: 12),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'PIN',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Devam')),
        ],
      ),
    );

    if (ok != true) {
      pinCtrl.dispose();
      return false;
    }

    final entered = pinCtrl.text.trim();
    pinCtrl.dispose();

    if (entered == SecurityStore.adminPin) return true;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yetkisiz / PIN hatalı')));
    }
    return false;
  }

  Future<void> _loadTemplate(String model) async {
    final tpl = TemplateStore.getTemplateForModel(model);

    setState(() {
      InMemoryStore.kontrolNoktalari
        ..clear()
        ..addAll(tpl);
      InMemoryStore.kontrolNoktalari.sort((a, b) => a.siraNo.compareTo(b.siraNo));

      InMemoryStore.yedekKontrolNoktalari.clear();

      SessionStore.activeModel = model.trim();
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Şablon yüklendi: $model (${tpl.length})')),
    );
  }

  Future<void> _deleteTemplate(String model) async {
    final authed = await _requireAdminPin();
    if (!authed) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Şablonu Sil'),
        content: Text('$model şablonu silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Vazgeç')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sil')),
        ],
      ),
    );

    if (ok != true) return;

    await TemplateStore.deleteTemplateForModel(model);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Şablon silindi: $model')),
    );

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final all = TemplateStore.getSavedModelKeysOrdered();

    final filtered = all.where((m) {
      final t = m.toLowerCase();
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      return t.contains(q);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Şablon Arşivi'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _q,
              decoration: _decSmall('Ara', hint: 'Model adına gore filtrele'),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('Kayıtlı şablon bulunamadı.'))
                  : ListView.separated(
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final model = filtered[i];
                  final count = TemplateStore.getTemplateItemCount(model);

                  final isActive = SessionStore.activeModel.trim().toLowerCase() ==
                      model.trim().toLowerCase();

                  return ListTile(
                    title: Text(
                      model,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: isActive ? Colors.green.shade800 : null,
                      ),
                    ),
                    subtitle: Text('Madde: $count${isActive ? '  •  Aktif' : ''}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Yükle',
                          icon: const Icon(Icons.download),
                          onPressed: () => _loadTemplate(model),
                        ),
                        IconButton(
                          tooltip: 'Sil (PIN)',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _deleteTemplate(model),
                        ),
                      ],
                    ),
                    onTap: () => _loadTemplate(model),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// OPERATOR / KONTROLOR TANIMLAMA (Kalıcı)
// =====================
class PersonelTanimScreen extends StatefulWidget {
  const PersonelTanimScreen({super.key});

  @override
  State<PersonelTanimScreen> createState() => _PersonelTanimScreenState();
}

class _PersonelTanimScreenState extends State<PersonelTanimScreen> {
  final _opCtrl = TextEditingController();
  final _opPinCtrl = TextEditingController();
  final _koCtrl = TextEditingController();

  @override
  void dispose() {
    _opCtrl.dispose();
    _opPinCtrl.dispose();
    _koCtrl.dispose();
    super.dispose();
  }

  Future<void> _ekleOperator() async {
    final ad = _opCtrl.text.trim();
    final pin = _opPinCtrl.text.trim();
    if (ad.isEmpty || pin.isEmpty) return;

    setState(() {
      final exists = InMemoryStore.operatorler.any((o) => o.ad.toLowerCase() == ad.toLowerCase());
      if (!exists) {
        InMemoryStore.operatorler.add(Operator(ad: ad, pin: pin));
      }
      _opCtrl.clear();
      _opPinCtrl.clear();
    });

    await InMemoryStore.save();
  }

  Future<void> _ekleKontrolor() async {
    final t = _koCtrl.text.trim();
    if (t.isEmpty) return;

    setState(() {
      if (!InMemoryStore.kontrolorler.contains(t)) {
        InMemoryStore.kontrolorler.add(t);
      }
      _koCtrl.clear();
    });

    await InMemoryStore.save();
  }

  Future<void> _silOperator(int i) async {
    if (i == 0) return;
    setState(() => InMemoryStore.operatorler.removeAt(i));
    await InMemoryStore.save();
  }

  Future<void> _silKontrolor(int i) async {
    if (i == 0) return;
    setState(() => InMemoryStore.kontrolorler.removeAt(i));
    await InMemoryStore.save();
  }

  @override
  Widget build(BuildContext context) {
    final ops = InMemoryStore.operatorler;
    final kos = InMemoryStore.kontrolorler;

    return Scaffold(
      appBar: AppBar(title: const Text('Operator / Kontrolor Tanımla')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Operatorler (PIN ile)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _opCtrl,
                          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Operator adı'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _opPinCtrl,
                          keyboardType: TextInputType.number,
                          obscureText: true,
                          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'PIN'),
                          onSubmitted: (_) => _ekleOperator(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(height: 56, child: ElevatedButton(onPressed: _ekleOperator, child: const Text('Ekle'))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: ops.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final op = ops[i];
                        return ListTile(
                          title: Text(op.ad),
                          subtitle: i == 0 ? const Text('Sabit seçenek') : const Text('PIN: ••••'),
                          trailing: i == 0
                              ? null
                              : IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _silOperator(i),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Kontrolorler', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _koCtrl,
                          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Kontrolor adı'),
                          onSubmitted: (_) => _ekleKontrolor(),
                        ),
                      ),
                      const SizedBox(width: 10),
                      SizedBox(height: 56, child: ElevatedButton(onPressed: _ekleKontrolor, child: const Text('Ekle'))),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: kos.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        return ListTile(
                          title: Text(kos[i]),
                          trailing: i == 0
                              ? null
                              : IconButton(
                            icon: const Icon(Icons.delete, color: Colors.red),
                            onPressed: () => _silKontrolor(i),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =====================
// OK / NOK
// =====================
class OkScreen extends StatelessWidget {
  const OkScreen({super.key});

  Widget _infoRow(String label, String value) {
    final v = value.trim().isEmpty ? "-" : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.black87),
            ),
          ),
          const Text(" : ", style: TextStyle(fontWeight: FontWeight.w700)),
          Expanded(
            child: Text(v, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F8),
      appBar: AppBar(
        backgroundColor: Colors.green,
        title: const Text("ÜRETİM SONU KALİTE KONTROL"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Column(
                children: [
                  Icon(Icons.check_circle, size: 60, color: Colors.white),
                  SizedBox(height: 10),
                  Text(
                    "ONAYLANDI",
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Card(
              elevation: 3,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    _infoRow("Tarih / Saat", SessionStore.lastTarihSaat),
                    _infoRow("VIN", SessionStore.lastVin),
                    _infoRow("Motor No", SessionStore.lastMotorNo),
                    _infoRow("Model", SessionStore.lastModel),
                    _infoRow("Renk + Stok", "${SessionStore.lastRenk}  -  ${SessionStore.lastStokKodu}"),
                    _infoRow("Parti No", SessionStore.lastPartiNo),
                    _infoRow("Operator", SessionStore.operatorLoggedInAd),
                    _infoRow("Kontrolor", SessionStore.lastKontrolor),
                  ],
                ),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.picture_as_pdf),
                label: const Text("PDF Olarak Kaydet", style: TextStyle(fontSize: 18)),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                onPressed: () async {
                  try {
                    // 1️⃣ Önce DB'ye OK kaydı
                    final okDb = await ApiClient.okKaydet(
                      testTarihi: SessionStore.lastTarihSaat,
                      vin: SessionStore.lastVin,
                      motorNo: SessionStore.lastMotorNo,
                      model: SessionStore.lastModel,
                      partiNo: SessionStore.lastPartiNo,
                      operatorAd: SessionStore.operatorLoggedInAd,
                      kontrolorAd: SessionStore.lastKontrolor,

                      // Şimdilik boş, sonra alan ekleriz
                      durum: "",
                      uretimSonuKaydi: "",
                      belgeNo: "",
                      istasyon: "",
                    );

                    if (okDb["ok"] != true) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("DB kaydı başarısız: ${okDb["error"] ?? okDb}")),
                      );
                      return;
                    }
                    // ✅ Snapshot'tan rapor item listesi üret
                    final items = SessionStore.kontrolItemsSnapshot.map((it) {
                      final sira = (it["siraNo"] as int?) ?? 0;
                      return {
                        "siraNo": sira,
                        "process": (it["process"] ?? "").toString(),
                        "kontrolTuru": (it["kontrolTuru"] ?? "").toString(),
                        "cevap": (SessionStore.kontrolCevaplari[sira] ?? "").toString(), // "OK"/"NOK"
                      };
                    }).toList();

                    if (items.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text("HATA: Kontrol maddeleri bulunamadı (items boş).")),
                      );
                      return;
                    }

                    // ✅ Sonuç yaz
                    final sonuc = (SessionStore.finalSonuc).trim().isEmpty ? "OK" : SessionStore.finalSonuc.trim();

                    print("OPERATÖR -> ${SessionStore.operatorLoggedInAd}");
                    print("KONTROLÖR -> ${SessionStore.lastKontrolor}");

                    final res = await ApiClient.submitReport(
                      tarihSaat: SessionStore.lastTarihSaat,
                      vin: SessionStore.lastVin,
                      motorNo: SessionStore.lastMotorNo,
                      model: SessionStore.lastModel,
                      marka: SessionStore.lastMarka,
                      partiNo: SessionStore.lastPartiNo,
                      renk: SessionStore.lastRenk,
                      stokKodu: SessionStore.lastStokKodu,
                      operatorAd: SessionStore.operatorLoggedInAd,
                      kontrolorAd: SessionStore.lastKontrolor,
                      sonuc: sonuc,
                      items: items,

                      nokAciklama: SessionStore.lastNokAciklama,
                      nokKaynak: SessionStore.lastNokKaynak,
                      nokIstasyon: SessionStore.lastNokIstasyon,
                      nokSiraNo: SessionStore.lastNokSiraNo,
                    );


                    final ok = (res["ok"] == true);
                    if (!ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text("Kaydedilemedi: ${res["error"] ?? "Bilinmeyen hata"}")),
                      );
                      return;
                    }

                    final path = (res["pdfPath"] ?? "").toString();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("PDF kaydedildi ✅\n$path")),
                    );
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text("PDF kaydetme hatası: $e")),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: OutlinedButton(
                onPressed: () {
                  SessionStore.resetForm(includeOperator: false);

                  Navigator.pushNamedAndRemoveUntil(
                    context,
                    '/new',
                        (route) => false,
                  );
                },
                child: const Text("Yeni Kontrole Don", style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



class NokScreen extends StatefulWidget {
  final int siraNo;
  final String process;
  final String kontrolTuru;

  const NokScreen({
    super.key,
    required this.siraNo,
    required this.process,
    required this.kontrolTuru,
  });

  @override
  State<NokScreen> createState() => _NokScreenState();
}

class _NokScreenState extends State<NokScreen> {
  // ------------------ API DATA ------------------
  List<Map<String, dynamic>> _apiHatalar = [];
  bool _isLoadingHatalar = true;

  // ------------------ Seçimler ------------------
  String? _seciliParca;
  String? _seciliAciklama;

  String _autoTur = '';
  String _autoSeviye = '';
  String _autoKaynak = '';
  String _autoIstasyon = '';

  @override
  void initState() {
    super.initState();
    _fetchHatalar();
  }

  Future<void> _fetchHatalar() async {
    print("FETCH BASLADI");
    try {
      final response = await http.get(
        Uri.parse("http://127.0.0.1:5000/hatalar-index"),
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);

        // decoded: List<dynamic> bekliyoruz
        final list = (decoded["items"] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

        setState(() {
          _apiHatalar = list;
          _isLoadingHatalar = false;
        });

        print("LIST DOLDU");
        print(_apiHatalar.first);
        // debug
        // ignore: avoid_print
        print("API Hata Sayısı: ${_apiHatalar.length}");
      } else {
        setState(() => _isLoadingHatalar = false);
        // ignore: avoid_print
        print("API Hata: ${response.statusCode}");
      }
    } catch (e) {
      setState(() => _isLoadingHatalar = false);
      // ignore: avoid_print
      print("API Exception: $e");
    }
  }

  Future<void> _sendNokEvent() async {
    final url = Uri.parse("http://127.0.0.1:5000/nok-event");

    try {
      final response = await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "report_id": 1,
          "control_id": widget.siraNo,
          "operator": SessionStore.operatorLoggedInAd,
          "controller": SessionStore.lastKontrolor,
          "timestamp": DateTime.now().toIso8601String(),
        }),
      );

      if (response.statusCode == 200) {
        print("✅ NOK DB’ye yazıldı");
      } else {
        print("❌ API hata: ${response.body}");
      }
    } catch (e) {
      print("❌ Bağlantı hatası: $e");
    }
  }

  // ------------------ Derived Lists ------------------
  List<String> get _parcalar {
    final set = <String>{};
    for (final h in _apiHatalar) {
      final p = (h["parca"] ?? "").toString().trim();
      if (p.isNotEmpty) set.add(p);
    }
    final list = set.toList()..sort();
    return list;
  }

  List<Map<String, dynamic>> get _filtreliHatalar {
    if (_seciliParca == null || _seciliParca!.trim().isEmpty) return [];
    return _apiHatalar
        .where((h) => (h["parca"] ?? "").toString() == _seciliParca)
        .toList();
  }

  // ------------------ UI Helpers ------------------
  Widget _infoRow(String label, String value) {
    final v = value.trim().isEmpty ? "-" : value.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          const Text(" : "),
          Expanded(child: Text(v)),
        ],
      ),
    );
  }

  Widget _smallField(String label, String value) {
    final v = value.trim().isEmpty ? "-" : value.trim();

    return TextFormField(
      readOnly: true,
      key: ValueKey(v), // BU ÇOK ÖNEMLİ
      initialValue: v,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _actionButton(
      String text,
      IconData icon,
      Color color,
      VoidCallback onTap, {
        bool outlined = false,
      }) {
    if (outlined) {
      return SizedBox(
        width: 200,
        height: 52,
        child: OutlinedButton.icon(
          icon: Icon(icon, color: Colors.black),
          label: Text(
            text,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black,
            ),
          ),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFFE57373), width: 1.5),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          onPressed: onTap,
        ),
      );
    }

    return SizedBox(
      width: 200,
      height: 52,
      child: ElevatedButton.icon(
        icon: Icon(icon, color: Colors.black),
        label: Text(
          text,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          elevation: 5,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: onTap,
      ),
    );
  }

  // ------------------ BUILD ------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFBE9E9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFE57373),
        title: const Text("ÜRETİM SONU KALİTE KONTROL"),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // HEADER
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFE57373),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Column(
                children: [
                  Icon(Icons.cancel, size: 50, color: Colors.white),
                  SizedBox(height: 6),
                  Text(
                    "REDDEDİLDİ",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // CONTENT CARD
            Expanded(
              child: Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // SOL PANEL
                      Expanded(
                        flex: 5,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _infoRow("Tarih / Saat", SessionStore.lastTarihSaat),
                            _infoRow("VIN", SessionStore.lastVin),
                            _infoRow("Motor No", SessionStore.lastMotorNo),
                            _infoRow("Model", SessionStore.lastModel),
                            _infoRow(
                              "Renk + Stok",
                              "${SessionStore.lastRenk}  -  ${SessionStore.lastStokKodu}",
                            ),
                            _infoRow("Parti No", SessionStore.lastPartiNo),
                            _infoRow("Operator", SessionStore.operatorLoggedInAd),
                            _infoRow("Kontrolor", SessionStore.lastKontrolor),

                            const SizedBox(height: 12),
                            const Divider(),

                            _infoRow("NOK Sıra", "${widget.siraNo}"),
                            _infoRow("NOK Madde", widget.process),
                            _infoRow("NOK Tür", widget.kontrolTuru),
                          ],
                        ),
                      ),

                      const SizedBox(width: 20),

                      // SAĞ PANEL
                      Expanded(
                        flex: 6,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_isLoadingHatalar) ...[
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Center(child: CircularProgressIndicator()),
                              ),
                              const SizedBox(height: 10),
                            ],

                            // PARÇA
                            DropdownButtonFormField<String>(
                              value: _seciliParca,
                              decoration: const InputDecoration(
                                labelText: "Parça",
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _parcalar
                                  .map<DropdownMenuItem<String>>((p) {
                                return DropdownMenuItem<String>(
                                  value: p,
                                  child: Text(p),
                                );
                              }).toList(),
                              onChanged: _isLoadingHatalar
                                  ? null
                                  : (v) {
                                setState(() {
                                  _seciliParca = v;
                                  _seciliAciklama = null;
                                  _autoTur = '';
                                  _autoSeviye = '';
                                  _autoKaynak = '';
                                  _autoIstasyon = '';
                                });
                              },
                            ),

                            const SizedBox(height: 10),

                            // HATA AÇIKLAMA
                            DropdownButtonFormField<String>(
                              value: _seciliAciklama,
                              decoration: const InputDecoration(
                                labelText: "Hata Açıklaması",
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: _filtreliHatalar
                                  .map<DropdownMenuItem<String>>((h) {
                                final aciklama = (h["aciklama"] ?? "").toString();
                                return DropdownMenuItem<String>(
                                  value: aciklama,
                                  child: Text(aciklama),
                                );
                              }).toList(),
                              onChanged: (_isLoadingHatalar || _seciliParca == null)
                                  ? null
                                  : (v) {
                                setState(() {
                                  _seciliAciklama = v;

                                  final sel = _filtreliHatalar.firstWhere(
                                        (h) =>
                                    (h["aciklama"] ?? "").toString() == v,
                                    orElse: () => <String, dynamic>{},
                                  );

                                  _autoTur = (sel["tur"] ?? "").toString();
                                  _autoSeviye = (sel["seviye"] ?? "").toString();
                                  _autoKaynak = (sel["kaynak"] ?? "").toString();
                                  _autoIstasyon =
                                      (sel["istasyon"] ?? "").toString();
                                });
                              },
                            ),

                            const SizedBox(height: 10),

                            // ALT BİLGİ SATIRLARI
                            Row(
                              children: [
                                Expanded(child: _smallField("Tür", _autoTur)),
                                const SizedBox(width: 8),
                                Expanded(child: _smallField("Seviye", _autoSeviye)),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(child: _smallField("Kaynak", _autoKaynak)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: _smallField("İstasyon", _autoIstasyon)),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            // BUTONLAR
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _actionButton(
                  "Kaydet",
                  Icons.save,
                  const Color(0xFFFFCDD2),
                      () async {
                    await _sendNokEvent();

                    await ApiClient.submitReport(
                      tarihSaat: SessionStore.lastTarihSaat,
                      vin: SessionStore.lastVin,
                      motorNo: SessionStore.lastMotorNo,
                      model: SessionStore.lastModel,
                      marka: SessionStore.lastMarka,
                      partiNo: SessionStore.lastPartiNo,
                      renk: SessionStore.lastRenk,
                      stokKodu: SessionStore.lastStokKodu,
                      operatorAd: SessionStore.operatorLoggedInAd,
                      kontrolorAd: SessionStore.lastKontrolor,
                      sonuc: "NOK",
                      items: [], // Şimdilik boş bırak
                      nokParca: _seciliParca,
                      nokAciklama: _seciliAciklama,
                      nokKaynak: _autoKaynak,
                      nokIstasyon: _autoIstasyon,
                      nokSiraNo: widget.siraNo,
                      nokTur: _autoTur,
                      nokSeviye: _autoSeviye,
                    );

                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Test NOK olarak kaydedildi")),
                    );
                  },
                ),
                _actionButton(
                  "Kaydet & Yazdır",
                  Icons.print,
                  const Color(0xFFE57373),
                      () {
                    // TODO: Kaydet & yazdır aksiyonu
                    // ignore: avoid_print
                    print("PRINT");
                  },
                ),
                const SizedBox(width: 12),
                _actionButton(
                  "Ana Ekran",
                  Icons.home,
                  Colors.white,
                      () {
                    Navigator.popUntil(context, ModalRoute.withName('/'));
                  },
                  outlined: true,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}



// =====================
// GLOBAL NUMERIC KEYPAD (Operator PIN)
// =====================

Widget buildNumericKeypad(
    void Function(void Function()) setState,
    void Function(String) onKey,
    ) {
  Widget buildButton(String text, {Color? color}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            padding: const EdgeInsets.symmetric(vertical: 18),
          ),
          onPressed: () {
            setState(() {
              onKey(text);
            });
          },
          child: Text(
            text == 'del' ? '⌫' : text,
            style: const TextStyle(fontSize: 22),
          ),
        ),
      ),
    );
  }

  return Column(
    children: [
      Row(children: [buildButton('1'), buildButton('2'), buildButton('3')]),
      Row(children: [buildButton('4'), buildButton('5'), buildButton('6')]),
      Row(children: [buildButton('7'), buildButton('8'), buildButton('9')]),
      Row(children: [
        const Spacer(),
        buildButton('0'),
        buildButton('del', color: Colors.redAccent),
      ]),
    ],
  );
}
