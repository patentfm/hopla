import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// UUID base: 12340000-1234-5678-ABCD-1234567890AB
/// Full UUID: 1234NNNN-1234-5678-ABCD-1234567890AB
class HoplaGattUuids {
  static const String _base = '12340000-1234-5678-abcd-1234567890ab';

  static Uuid fullFromShort(int short) {
    final nnnn = short.toRadixString(16).padLeft(4, '0').toLowerCase();
    // 1234NNNN-1234-5678-ABCD-1234567890AB
    final full = '1234$nnnn-1234-5678-abcd-1234567890ab';
    return Uuid.parse(full);
  }

  static final Uuid service = fullFromShort(0x0001);

  // Characteristics (short UUIDs from BLE_Docs.md)
  static final Uuid sampleRate = fullFromShort(0x0002);
  static final Uuid logInterval = fullFromShort(0x0003);
  static final Uuid advInterval = fullFromShort(0x0004);
  static final Uuid txPower = fullFromShort(0x0005);
  static final Uuid deviceName = fullFromShort(0x0006);
  static final Uuid accelThresh = fullFromShort(0x0007);
  static final Uuid accelRange = fullFromShort(0x0008);
  static final Uuid accelCalib = fullFromShort(0x0009);
  static final Uuid mode = fullFromShort(0x000a);
  static final Uuid logs = fullFromShort(0x000b);
  static final Uuid logCtrl = fullFromShort(0x000c);

  // Kept for readability / future asserts.
  static final Uuid base = Uuid.parse(_base);
}

class HoplaBleCodec {
  static Uint8List u16le(int v) => Uint8List.fromList([v & 0xFF, (v >> 8) & 0xFF]);

  static int readU16le(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    return bytes[0] | (bytes[1] << 8);
  }

  static Uint8List i16le(int v) {
    final vv = v & 0xFFFF;
    return Uint8List.fromList([vv & 0xFF, (vv >> 8) & 0xFF]);
  }

  static int readI16leAt(Uint8List bytes, int offset) {
    if (bytes.length < offset + 2) return 0;
    final raw = bytes[offset] | (bytes[offset + 1] << 8);
    return raw >= 0x8000 ? raw - 0x10000 : raw;
  }

  static int readI8(Uint8List bytes) {
    if (bytes.isEmpty) return 0;
    final b = bytes[0];
    return b >= 0x80 ? b - 0x100 : b;
  }

  static Uint8List i8(int v) => Uint8List.fromList([v & 0xFF]);

  static Uint8List u8(int v) => Uint8List.fromList([v & 0xFF]);

  static String readUtf8(Uint8List bytes) {
    // Firmware stores raw UTF-8 bytes without \0.
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));

  static String hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}

class HoplaBleQualified {
  static QualifiedCharacteristic qc({
    required String deviceId,
    required Uuid characteristicId,
  }) {
    return QualifiedCharacteristic(
      deviceId: deviceId,
      serviceId: HoplaGattUuids.service,
      characteristicId: characteristicId,
    );
  }
}


