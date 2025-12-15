import 'dart:typed_data';

/// Parser dla Manufacturer Specific Data z urządzeń Hopla!
/// 
/// Zgodnie z BLE_Docs.md, payload to 8 bajtów:
/// - Offset 0: data_type (uint8) = 0x01 dla XYZ
/// - Offset 1-2: x_mg (int16 LE)
/// - Offset 3-4: y_mg (int16 LE)
/// - Offset 5-6: z_mg (int16 LE)
/// - Offset 7: seq (uint8)
/// 
/// flutter_reactive_ble zwraca manufacturerData jako Map<int, Uint8List>,
/// gdzie klucz to Company ID (0xFFFF dla Hopla!).
class HoplaAdvData {
  final int? xMg;
  final int? yMg;
  final int? zMg;
  final int? seq;
  final bool isValid;

  HoplaAdvData({
    this.xMg,
    this.yMg,
    this.zMg,
    this.seq,
    required this.isValid,
  });

  @override
  String toString() {
    if (!isValid) return 'Invalid data';
    return 'X: ${xMg ?? "N/A"} mg, Y: ${yMg ?? "N/A"} mg, Z: ${zMg ?? "N/A"} mg, Seq: ${seq ?? "N/A"}';
  }
}

class HoplaAdvParser {
  /// Company ID dla Hopla! (testowy, 0xFFFF)
  static const int companyId = 0xFFFF;

  /// Parsuje Manufacturer Specific Data z advertisingu
  /// 
  /// [manufacturerData] to Map<int, Uint8List> gdzie klucz to Company ID.
  /// Dla Hopla! szukamy klucza 0xFFFF i parsujemy payload 8 bajtów.
  static HoplaAdvData? parseManufacturerData(Map<int, Uint8List>? manufacturerData) {
    if (manufacturerData == null || manufacturerData.isEmpty) return null;

    // Szukaj danych dla Company ID Hopla!
    final hoplaData = manufacturerData[companyId];
    if (hoplaData == null || hoplaData.isEmpty) return null;

    // Konwertuj Uint8List na List<int> dla łatwiejszej pracy
    final data = hoplaData.toList();

    // Sprawdź czy payload ma odpowiednią długość (8 bajtów)
    if (data.length < 8) return null;

    // Parsuj zgodnie z BLE_Docs.md
    final dataType = data[0];
    if (dataType != 0x01) {
      // Nie jest to typ XYZ
      return null;
    }

    // Parsuj int16 LE (little-endian)
    final xMg = _parseInt16LE(data, 1);
    final yMg = _parseInt16LE(data, 3);
    final zMg = _parseInt16LE(data, 5);
    final seq = data[7];

    return HoplaAdvData(
      xMg: xMg,
      yMg: yMg,
      zMg: zMg,
      seq: seq,
      isValid: true,
    );
  }

  /// Parsuje int16 w formacie little-endian z listy bajtów
  static int _parseInt16LE(List<int> data, int offset) {
    if (offset + 1 >= data.length) return 0;
    final low = data[offset];
    final high = data[offset + 1];
    // Konwersja signed int16
    int value = low | (high << 8);
    if (value > 32767) {
      value = value - 65536; // Konwersja na signed
    }
    return value;
  }

  /// Formatuje bajty jako hex string dla wyświetlenia
  static String formatBytesAsHex(List<int>? data) {
    if (data == null || data.isEmpty) return 'Brak danych';
    return data.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
  }

  /// Formatuje Uint8List jako hex string dla wyświetlenia
  static String formatUint8ListAsHex(Uint8List? data) {
    if (data == null || data.isEmpty) return 'Brak danych';
    return formatBytesAsHex(data.toList());
  }

  /// Formatuje całą Map<int, Uint8List> jako czytelny string
  static String formatManufacturerDataMap(Map<int, Uint8List>? data) {
    if (data == null || data.isEmpty) return 'Brak danych';
    return data.entries.map((entry) {
      final companyIdHex = '0x${entry.key.toRadixString(16).padLeft(4, '0').toUpperCase()}';
      return '$companyIdHex: ${formatUint8ListAsHex(entry.value)}';
    }).join('\n');
  }
}

