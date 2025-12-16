import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'package:hopla/ble/hopla_adv_parser.dart';
import 'package:hopla/ble/hopla_gatt.dart';

class BleDeviceScreen extends StatefulWidget {
  const BleDeviceScreen({
    super.key,
    required this.device,
  });

  final DiscoveredDevice device;

  @override
  State<BleDeviceScreen> createState() => _BleDeviceScreenState();
}

class _BleDeviceScreenState extends State<BleDeviceScreen> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  StreamSubscription<ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<DiscoveredDevice>? _advScanSub;
  ConnectionStateUpdate? _connection;
  String? _error;
  bool _busy = false;
  bool _liveAdvScan = true;
  bool _servicesDiscovered = false;
  final Map<Uuid, _CharMeta> _charMeta = {};

  DiscoveredDevice? _lastSeenAdv;
  HoplaAdvData? _lastAdvParsed;
  DateTime? _lastAdvAt;

  // Ensures we never run multiple GATT ops concurrently (discovery/read/write),
  // which is a common source of Android status 22 disconnects.
  Future<void> _gattQueue = Future<void>.value();

  // Form controllers
  final _sampleRateCtrl = TextEditingController();
  final _logIntervalCtrl = TextEditingController();
  final _advIntervalCtrl = TextEditingController();
  final _txPowerCtrl = TextEditingController();
  final _deviceNameCtrl = TextEditingController();
  final _accelThreshCtrl = TextEditingController();
  int? _accelRange; // 2/4/8/16
  final _calibXCtrl = TextEditingController();
  final _calibYCtrl = TextEditingController();
  final _calibZCtrl = TextEditingController();
  int? _mode; // 0/1/2

  // Logs
  String _logsText = '';

  String get _deviceId => widget.device.id;

  bool get _isConnected => _connection?.connectionState == DeviceConnectionState.connected;

  @override
  void initState() {
    super.initState();
    _deviceNameCtrl.text = widget.device.name;
    _lastSeenAdv = widget.device;
    _lastAdvParsed = HoplaAdvParser.parseManufacturerData(widget.device.manufacturerData);
    _startAdvScan();
  }

  @override
  void dispose() {
    _connectionSub?.cancel();
    _advScanSub?.cancel();
    _sampleRateCtrl.dispose();
    _logIntervalCtrl.dispose();
    _advIntervalCtrl.dispose();
    _txPowerCtrl.dispose();
    _deviceNameCtrl.dispose();
    _accelThreshCtrl.dispose();
    _calibXCtrl.dispose();
    _calibYCtrl.dispose();
    _calibZCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _error = null;
      _busy = true;
    });

    // Avoid scan+connect concurrently.
    await _stopAdvScan();

    await _connectionSub?.cancel();
    _connectionSub = _ble
        .connectToDevice(
          id: _deviceId,
          connectionTimeout: const Duration(seconds: 8),
        )
        .listen(
          (update) {
            if (!mounted) return;
            setState(() {
              _connection = update;
              _busy = update.connectionState == DeviceConnectionState.connecting;
            });
            if (update.connectionState == DeviceConnectionState.connected) {
              // Reset discovery flag for the new connection. Discovery happens on-demand
              // under the GATT mutex to avoid concurrent operations.
              _servicesDiscovered = false;
            }
          },
          onError: (e) {
            if (!mounted) return;
            setState(() {
              _error = 'Błąd połączenia: $e';
              _busy = false;
            });
          },
        );
  }

  Future<void> _disconnect() async {
    await _connectionSub?.cancel();
    _connectionSub = null;
    if (!mounted) return;
    setState(() {
      _connection = ConnectionStateUpdate(
        deviceId: _deviceId,
        connectionState: DeviceConnectionState.disconnected,
        failure: null,
      );
      _servicesDiscovered = false;
    });
    if (_liveAdvScan) {
      _startAdvScan();
    }
  }

  void _startAdvScan() {
    if (!_liveAdvScan) return;
    _advScanSub?.cancel();
    _advScanSub = _ble
        .scanForDevices(
          withServices: const [],
          scanMode: ScanMode.lowPower,
          requireLocationServicesEnabled: false,
        )
        .listen(
          (d) {
            if (!mounted) return;
            if (d.id != _deviceId) return;
            setState(() {
              _lastSeenAdv = d;
              _lastAdvParsed = HoplaAdvParser.parseManufacturerData(d.manufacturerData);
              _lastAdvAt = DateTime.now();
            });
          },
          onError: (e) {
            if (!mounted) return;
            setState(() {
              _error = 'Błąd skanowania (live adv): $e';
            });
          },
        );
  }

  Future<void> _stopAdvScan() async {
    await _advScanSub?.cancel();
    _advScanSub = null;
  }

  Future<T> _runGatt<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _gattQueue = _gattQueue.then((_) async {
      try {
        final v = await op();
        completer.complete(v);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  bool _looksLikeStatus22(Object e) {
    final s = e.toString();
    return s.contains('status 22') ||
        s.contains('GATT_CONN_TERMINATE_LOCAL_HOST') ||
        s.contains('disconnected');
  }

  Future<void> _waitUntilConnected({Duration timeout = const Duration(seconds: 8)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_isConnected) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw Exception('Timeout waiting for BLE connection');
  }

  Future<T> _runGattWithReconnect<T>(Future<T> Function() op) async {
    try {
      return await _runGatt(op);
    } catch (e) {
      if (!_looksLikeStatus22(e)) rethrow;

      // One retry: reconnect and try again.
      await _disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _connect();
      await _waitUntilConnected(timeout: const Duration(seconds: 10));
      return await _runGatt(op);
    }
  }

  Future<void> _ensureServicesDiscovered() async {
    if (!_isConnected || _servicesDiscovered) return;

    // Pause scanning during discovery to reduce Android BLE stack flakiness.
    final wasLive = _liveAdvScan;
    if (wasLive) {
      await _stopAdvScan();
    }

    try {
      Object? lastError;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          if (!_isConnected) {
            throw Exception('Rozłączono w trakcie service discovery');
          }
          // On some stacks discovery right after connect is flaky.
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          }
          await _ble.discoverAllServices(_deviceId);
          final services = await _ble.getDiscoveredServices(_deviceId);
          final hopla = services.where((s) => s.id == HoplaGattUuids.service).toList();
          if (hopla.isEmpty) throw Exception('Nie znaleziono XYZ Config Service: ${HoplaGattUuids.service}');

          _charMeta
            ..clear()
            ..addEntries(
              hopla.expand((s) => s.characteristics).map(
                    (c) => MapEntry(
                      c.id,
                      _CharMeta(
                        isReadable: c.isReadable,
                        isWritableWithResponse: c.isWritableWithResponse,
                        isWritableWithoutResponse: c.isWritableWithoutResponse,
                        isNotifiable: c.isNotifiable,
                        isIndicatable: c.isIndicatable,
                      ),
                    ),
                  ),
            );

          _servicesDiscovered = true;
          return;
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
        }
      }
      throw Exception('Service discovery failure: $lastError');
    } finally {
      if (wasLive) {
        _startAdvScan();
      }
    }
  }

  _CharMeta? _meta(Uuid charId) => _charMeta[charId];

  String _docForChar(Uuid charId) {
    if (charId == HoplaGattUuids.sampleRate) {
      return [
        'Sample Rate (0x0002)',
        '- Typ: uint16 LE (ms)',
        '- Default: 200',
        '- Zakres: 10..10000',
        '',
        'Przykład zapisu 1000 ms:',
        '- wartość: 0x03E8',
        '- bajty (LE): E8 03',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.logInterval) {
      return [
        'Log Interval (0x0003)',
        '- Typ: uint16 LE (ms)',
        '- Default: 200',
        '- Zakres: 100..60000',
        '',
        'To steruje jak często aktualizuje się Manufacturer Data w reklamie. Czyli praktycznie czas odświeżania rozgłaszania Akkcelerometru',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.advInterval) {
      return [
        'Adv Interval (0x0004)',
        '- Typ: uint16 LE (ms)',
        '- Default: 100',
        '- Zakres: 20..4000',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.txPower) {
      return [
        'TX Power (0x0005)',
        '- Typ: int8 (dBm)',
        '- Default: 0',
        '- Zakres: -40..4',
        '- Typowe wartości: -40,-20,-16,-12,-8,-4,0,3,4',
        '',
        'Wpisanie "4" oznacza +4 dBm (int8 -> 0x04).',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.deviceName) {
      return [
        'Device Name (0x0006)',
        '- Typ: UTF-8 bytes (bez \\0)',
        '- Rozmiar: 1..20 bajtów',
        '- Default: Hopla!',
        '',
        'Zapis restartuje advertising z nową nazwą.',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.accelThresh) {
      return [
        'Accel Thresh (0x0007)',
        '- Typ: uint16 LE (mg)',
        '- Default: 500',
        '- Zakres: 50..8000',
        '',
        'Używany też w trybie ARMED (czerwona dioda gdy max(|x|,|y|,|z|) >= threshold).',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.accelRange) {
      return [
        'Accel Range (0x0008)',
        '- Typ: uint8 (±g)',
        '- Default: 2',
        '- Zakres: 2..16',
        '',
        'Firmware normalizuje do: 2 / 4 / 8 / 16.',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.accelCalib) {
      return [
        'Accel Calib (0x0009)',
        '- Typ: 3×int16 LE (mg) => X,Y,Z',
        '- Default: (0,0,0)',
        '- Zakres: dowolne int16 (mg)',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.mode) {
      return [
        'Mode (0x000A)',
        '- Typ: uint8',
        '- Default: 0',
        '- Wartości: 0=Normal, 1=Eco, 2=Armed',
        '',
        'Semantyka (wartości efektywne):',
        '- Normal: bazowe',
        '- Eco: sample/log/adv ×2 (z clampem), TX max -8 dBm',
        '- Armed: sample/log ÷2 (clamp), adv ÷2 (jeśli > min)',
      ].join('\n');
    }
    if (charId == HoplaGattUuids.logs) {
      return [
        'Logs (0x000B)',
        '- Typ: ASCII bytes (linie zakończone \\n)',
        '- Rozmiar: 0..1024 (ring buffer w RAM; nadpisuje najstarsze)',
        '',
        'Odczyt (w aplikacji): pobieramy jedną porcję i pokazujemy pierwszą linię.',
      ].join('\n');
    }
    return 'Brak opisu dla tej charakterystyki.';
  }

  Future<void> _showDescriptorDialog(Uuid charId, {required String title}) async {
    final meta = _meta(charId);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Text(
            [
              _docForChar(charId),
              '',
              'Characteristic UUID:',
              '$charId',
              '',
              'Properties:',
              if (meta == null) '— (brak danych z discovery)' else ...[
                '- readable: ${meta.isReadable}',
                '- write (with response): ${meta.isWritableWithResponse}',
                '- write (without response): ${meta.isWritableWithoutResponse}',
                '- notify: ${meta.isNotifiable}',
                '- indicate: ${meta.isIndicatable}',
              ],
            ].join('\n'),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  Future<void> _descriptorPressed(Uuid charId, {required String title}) async {
    if (!_isConnected) return;
    if (!_servicesDiscovered) {
      await _writeField(() async {
        await _ensureServicesDiscovered();
      });
    }
    await _showDescriptorDialog(charId, title: title);
  }

  Future<Uint8List> _readRaw(Uuid charId) async {
    final qc = HoplaBleQualified.qc(deviceId: _deviceId, characteristicId: charId);
    final bytes = await _ble.readCharacteristic(qc);
    return Uint8List.fromList(bytes);
  }

  Future<void> _writeRaw(Uuid charId, Uint8List value) async {
    final qc = HoplaBleQualified.qc(deviceId: _deviceId, characteristicId: charId);
    await _ble.writeCharacteristicWithResponse(qc, value: value);
  }

  Future<Uint8List> _read(Uuid charId) async {
    return _runGattWithReconnect(() async {
      await _ensureServicesDiscovered();
      return _readRaw(charId);
    });
  }

  Future<void> _write(Uuid charId, Uint8List value) async {
    await _runGattWithReconnect(() async {
      await _ensureServicesDiscovered();
      await _writeRaw(charId, value);
      return null;
    });
  }

  int? _normalizeRange(int? range) {
    if (range == null) return null;
    if (range <= 2) return 2;
    if (range <= 4) return 4;
    if (range <= 8) return 8;
    return 16;
  }

  Future<void> _writeField(Future<void> Function() op) async {
    if (!_isConnected) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _runGattWithReconnect(() async {
        await _ensureServicesDiscovered();
        await op();
        return null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Błąd zapisu: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  int? _parseInt(String s) => int.tryParse(s.trim());

  Future<void> _readU16To(TextEditingController ctrl, Uuid charId) async {
    final v = HoplaBleCodec.readU16le(await _readRaw(charId));
    if (!mounted) return;
    setState(() => ctrl.text = v.toString());
  }

  Future<void> _writeU16From(TextEditingController ctrl, Uuid charId) async {
    final v = _parseInt(ctrl.text) ?? 0;
    await _writeRaw(charId, HoplaBleCodec.u16le(v));
  }

  Future<void> _readI8To(TextEditingController ctrl, Uuid charId) async {
    final v = HoplaBleCodec.readI8(await _readRaw(charId));
    if (!mounted) return;
    setState(() => ctrl.text = v.toString());
  }

  Future<void> _writeI8From(TextEditingController ctrl, Uuid charId) async {
    final v = _parseInt(ctrl.text) ?? 0;
    await _writeRaw(charId, HoplaBleCodec.i8(v));
  }

  Future<void> _readNameTo(TextEditingController ctrl, Uuid charId) async {
    final s = HoplaBleCodec.readUtf8(await _readRaw(charId));
    if (!mounted) return;
    setState(() => ctrl.text = s);
  }

  Future<void> _writeNameFrom(TextEditingController ctrl, Uuid charId) async {
    final bytes = HoplaBleCodec.utf8Bytes(ctrl.text);
    if (bytes.length > 20) throw Exception('Max 20 bajtów UTF-8. Teraz: ${bytes.length}.');
    await _writeRaw(charId, bytes);
  }

  Future<void> _readU8ToRange(Uuid charId) async {
    final bytes = await _readRaw(charId);
    final v = bytes.isEmpty ? null : bytes[0];
    if (!mounted) return;
    setState(() => _accelRange = _normalizeRange(v));
  }

  Future<void> _writeU8FromRange(Uuid charId) async {
    if (_accelRange == null) return;
    await _writeRaw(charId, HoplaBleCodec.u8(_accelRange!));
  }

  Future<void> _readMode(Uuid charId) async {
    final bytes = await _readRaw(charId);
    final v = bytes.isEmpty ? null : bytes[0];
    if (!mounted) return;
    setState(() => _mode = v);
  }

  Future<void> _writeMode(Uuid charId) async {
    if (_mode == null) return;
    await _writeRaw(charId, HoplaBleCodec.u8(_mode!));
  }

  Future<void> _readCalib(Uuid charId) async {
    final b = await _readRaw(charId);
    final x = HoplaBleCodec.readI16leAt(b, 0);
    final y = HoplaBleCodec.readI16leAt(b, 2);
    final z = HoplaBleCodec.readI16leAt(b, 4);
    if (!mounted) return;
    setState(() {
      _calibXCtrl.text = x.toString();
      _calibYCtrl.text = y.toString();
      _calibZCtrl.text = z.toString();
    });
  }

  Future<void> _writeCalib(Uuid charId) async {
    final x = _parseInt(_calibXCtrl.text) ?? 0;
    final y = _parseInt(_calibYCtrl.text) ?? 0;
    final z = _parseInt(_calibZCtrl.text) ?? 0;
    final bytes = Uint8List.fromList([
      ...HoplaBleCodec.i16le(x),
      ...HoplaBleCodec.i16le(y),
      ...HoplaBleCodec.i16le(z),
    ]);
    await _writeRaw(charId, bytes);
  }

  Future<void> _readLogsFirstLine() async {
    // Simplified: read a single chunk and show only the first line (up to '\n').
    final bytes = await _readRaw(HoplaGattUuids.logs);
    final text = HoplaBleCodec.readUtf8(bytes);
    final firstLine = text.split('\n').first;
    if (!mounted) return;
    setState(() {
      _logsText = firstLine.trim().isEmpty ? '(brak / nie odczytano)' : firstLine;
    });
  }

  @override
  Widget build(BuildContext context) {
    final adv = _lastAdvParsed;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name.isNotEmpty ? widget.device.name : 'Hopla! Device'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildHeaderCard(adv),
          const SizedBox(height: 12),
          _buildConnectionCard(),
          const SizedBox(height: 12),
          _buildConfigCard(),
          const SizedBox(height: 12),
          _buildLogsCard(),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHeaderCard(HoplaAdvData? adv) {
    final dev = _lastSeenAdv ?? widget.device;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              dev.name.isNotEmpty ? dev.name : 'Bez nazwy',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text('ID: ${dev.id}'),
            Text('RSSI: ${dev.rssi} dBm'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Live advertising (XYZ)'),
                    subtitle: Text(_lastAdvAt == null ? 'brak update' : 'ostatnio: $_lastAdvAt'),
                    value: _liveAdvScan,
                    onChanged: (v) async {
                      setState(() => _liveAdvScan = v);
                      if (v) {
                        _startAdvScan();
                      } else {
                        await _stopAdvScan();
                      }
                    },
                  ),
                ),
              ],
            ),
            if (adv != null && adv.isValid) ...[
              const Divider(height: 24),
              Text(
                'Advertising XYZ (mg)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              _row('X', adv.xMg?.toString() ?? '—'),
              _row('Y', adv.yMg?.toString() ?? '—'),
              _row('Z', adv.zMg?.toString() ?? '—'),
              _row('Seq', adv.seq?.toString() ?? '—'),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    final state = _connection?.connectionState ?? DeviceConnectionState.disconnected;
    final stateText = switch (state) {
      DeviceConnectionState.connected => 'Połączono',
      DeviceConnectionState.connecting => 'Łączenie…',
      DeviceConnectionState.disconnecting => 'Rozłączanie…',
      DeviceConnectionState.disconnected => 'Rozłączono',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Połączenie (GATT)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: Text('Status: $stateText')),
                if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy || _isConnected ? null : _connect,
                  child: const Text('Połącz'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : _disconnect,
                  child: const Text('Rozłącz'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'XYZ Config Service',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            _fieldU16(
              label: 'Sample Rate (ms)',
              controller: _sampleRateCtrl,
              onRead: () => _readU16To(_sampleRateCtrl, HoplaGattUuids.sampleRate),
              onWrite: () => _writeU16From(_sampleRateCtrl, HoplaGattUuids.sampleRate),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.sampleRate, title: 'Sample Rate'),
            ),
            _fieldU16(
              label: 'Log Interval (ms)',
              controller: _logIntervalCtrl,
              onRead: () => _readU16To(_logIntervalCtrl, HoplaGattUuids.logInterval),
              onWrite: () => _writeU16From(_logIntervalCtrl, HoplaGattUuids.logInterval),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.logInterval, title: 'Log Interval'),
            ),
            _fieldU16(
              label: 'Adv Interval (ms)',
              controller: _advIntervalCtrl,
              onRead: () => _readU16To(_advIntervalCtrl, HoplaGattUuids.advInterval),
              onWrite: () => _writeU16From(_advIntervalCtrl, HoplaGattUuids.advInterval),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.advInterval, title: 'Adv Interval'),
            ),
            _fieldI8(
              label: 'TX Power (dBm)',
              controller: _txPowerCtrl,
              helper: 'Typowe: -40,-20,-16,-12,-8,-4,0,3,4',
              onRead: () => _readI8To(_txPowerCtrl, HoplaGattUuids.txPower),
              onWrite: () => _writeI8From(_txPowerCtrl, HoplaGattUuids.txPower),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.txPower, title: 'TX Power'),
            ),
            _fieldText(
              label: 'Device Name (1..20 bajtów UTF-8)',
              controller: _deviceNameCtrl,
              onRead: () => _readNameTo(_deviceNameCtrl, HoplaGattUuids.deviceName),
              onWrite: () => _writeNameFrom(_deviceNameCtrl, HoplaGattUuids.deviceName),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.deviceName, title: 'Device Name'),
            ),
            _fieldU16(
              label: 'Accel Threshold (mg)',
              controller: _accelThreshCtrl,
              onRead: () => _readU16To(_accelThreshCtrl, HoplaGattUuids.accelThresh),
              onWrite: () => _writeU16From(_accelThreshCtrl, HoplaGattUuids.accelThresh),
              onDescriptor: () => _descriptorPressed(HoplaGattUuids.accelThresh, title: 'Accel Threshold'),
            ),
            const SizedBox(height: 12),
            _rangeDropdown(),
            const SizedBox(height: 12),
            _modeDropdown(),
            const SizedBox(height: 12),
            Text(
              'Accel Calib (mg, int16 LE)',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _smallNumberField('X', _calibXCtrl)),
                const SizedBox(width: 8),
                Expanded(child: _smallNumberField('Y', _calibYCtrl)),
                const SizedBox(width: 8),
                Expanded(child: _smallNumberField('Z', _calibZCtrl)),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Pobierz',
                  onPressed: _busy || !_isConnected ? null : () => _writeField(() => _readCalib(HoplaGattUuids.accelCalib)),
                  icon: const Icon(Icons.download),
                ),
                IconButton(
                  tooltip: 'Zapisz',
                  onPressed: _busy || !_isConnected ? null : () => _writeField(() => _writeCalib(HoplaGattUuids.accelCalib)),
                  icon: const Icon(Icons.upload),
                ),
                IconButton(
                  tooltip: 'Descriptor',
                  onPressed: _busy || !_isConnected
                      ? null
                      : () => _descriptorPressed(HoplaGattUuids.accelCalib, title: 'Accel Calib'),
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldU16({
    required String label,
    required TextEditingController controller,
    Future<void> Function()? onRead,
    Future<void> Function()? onWrite,
    Future<void> Function()? onDescriptor,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      onRead: onRead,
      onWrite: onWrite,
      onDescriptor: onDescriptor,
    );
  }

  Widget _fieldI8({
    required String label,
    required TextEditingController controller,
    String? helper,
    Future<void> Function()? onRead,
    Future<void> Function()? onWrite,
    Future<void> Function()? onDescriptor,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      helper: helper,
      onRead: onRead,
      onWrite: onWrite,
      onDescriptor: onDescriptor,
    );
  }

  Widget _fieldText({
    required String label,
    required TextEditingController controller,
    Future<void> Function()? onRead,
    Future<void> Function()? onWrite,
    Future<void> Function()? onDescriptor,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.text,
      onRead: onRead,
      onWrite: onWrite,
      onDescriptor: onDescriptor,
    );
  }

  Widget _fieldRow({
    required String label,
    required TextEditingController controller,
    required TextInputType keyboardType,
    String? helper,
    Future<void> Function()? onRead,
    Future<void> Function()? onWrite,
    Future<void> Function()? onDescriptor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              decoration: InputDecoration(
                labelText: label,
                helperText: helper,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Pobierz',
            onPressed: _busy || !_isConnected || onRead == null ? null : () => _writeField(() => onRead()),
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Zapisz',
            onPressed: _busy || !_isConnected || onWrite == null ? null : () => _writeField(() => onWrite()),
            icon: const Icon(Icons.upload),
          ),
          IconButton(
            tooltip: 'Descriptor',
            onPressed: _busy || !_isConnected || onDescriptor == null ? null : () async => await onDescriptor(),
            icon: const Icon(Icons.info_outline),
          ),
        ],
      ),
    );
  }

  Widget _smallNumberField(String label, TextEditingController ctrl) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  Widget _rangeDropdown() {
    const options = [2, 4, 8, 16];
    return Row(
      children: [
        Expanded(
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Accel Range (±g)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _accelRange,
                hint: const Text('Wybierz'),
                isExpanded: true,
                items: options
                    .map(
                      (v) => DropdownMenuItem<int>(
                        value: v,
                        child: Text('±$v g'),
                      ),
                    )
                    .toList(),
                onChanged: _busy ? null : (v) => setState(() => _accelRange = v),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Pobierz',
          onPressed: _busy || !_isConnected
              ? null
              : () => _writeField(() => _readU8ToRange(HoplaGattUuids.accelRange)),
          icon: const Icon(Icons.download),
        ),
        IconButton(
          tooltip: 'Zapisz',
          onPressed: _busy || !_isConnected || _accelRange == null
              ? null
              : () => _writeField(() => _writeU8FromRange(HoplaGattUuids.accelRange)),
          icon: const Icon(Icons.upload),
        ),
        IconButton(
          tooltip: 'Descriptor',
          onPressed: _busy || !_isConnected
              ? null
              : () => _descriptorPressed(HoplaGattUuids.accelRange, title: 'Accel Range'),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    );
  }

  Widget _modeDropdown() {
    final labels = <int, String>{0: 'Normal', 1: 'Eco', 2: 'Armed'};
    return Row(
      children: [
        Expanded(
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Mode',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                value: _mode,
                hint: const Text('Wybierz'),
                isExpanded: true,
                items: labels.entries
                    .map((e) => DropdownMenuItem<int>(value: e.key, child: Text('${e.key} = ${e.value}')))
                    .toList(),
                onChanged: _busy ? null : (v) => setState(() => _mode = v),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Pobierz',
          onPressed: _busy || !_isConnected ? null : () => _writeField(() => _readMode(HoplaGattUuids.mode)),
          icon: const Icon(Icons.download),
        ),
        IconButton(
          tooltip: 'Zapisz',
          onPressed: _busy || !_isConnected || _mode == null
              ? null
              : () => _writeField(() => _writeMode(HoplaGattUuids.mode)),
          icon: const Icon(Icons.upload),
        ),
        IconButton(
          tooltip: 'Descriptor',
          onPressed: _busy || !_isConnected ? null : () => _descriptorPressed(HoplaGattUuids.mode, title: 'Mode'),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    );
  }

  Widget _buildLogsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Logs (GATT)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Pobieramy jedną porcję logów i pokazujemy tylko pierwszą linię.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(child: Text('Logs (0x000B)')),
                IconButton(
                  tooltip: 'Pobierz',
                  onPressed: _busy || !_isConnected ? null : () => _writeField(_readLogsFirstLine),
                  icon: const Icon(Icons.download),
                ),
                IconButton(
                  tooltip: 'Zapisz (niedostępne)',
                  onPressed: null,
                  icon: const Icon(Icons.upload),
                ),
                IconButton(
                  tooltip: 'Descriptor',
                  onPressed: _busy || !_isConnected ? null : () => _descriptorPressed(HoplaGattUuids.logs, title: 'Logs'),
                  icon: const Icon(Icons.info_outline),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _logsText.isEmpty ? '(brak / nie odczytano)' : _logsText,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 56, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value, style: const TextStyle(fontFamily: 'monospace'))),
        ],
      ),
    );
  }
}

class _CharMeta {
  final bool isReadable;
  final bool isWritableWithResponse;
  final bool isWritableWithoutResponse;
  final bool isNotifiable;
  final bool isIndicatable;

  const _CharMeta({
    required this.isReadable,
    required this.isWritableWithResponse,
    required this.isWritableWithoutResponse,
    required this.isNotifiable,
    required this.isIndicatable,
  });
}


