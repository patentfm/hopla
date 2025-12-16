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
          final services = await _ble.discoverServices(_deviceId);
          final hasService = services.any((s) => s.serviceId == HoplaGattUuids.service);
          if (!hasService) {
            throw Exception('Nie znaleziono XYZ Config Service: ${HoplaGattUuids.service}');
          }
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

  Future<void> _readAll() async {
    if (!_isConnected) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Do the whole sequence under a single GATT queue + one reconnect retry.
      final result = await _runGattWithReconnect(() async {
        await _ensureServicesDiscovered();

        // Optional: bigger MTU helps with Logs reads.
        try {
          await _ble.requestMtu(deviceId: _deviceId, mtu: 247);
        } catch (_) {
          // ignore
        }

        Future<void> tinyGap() => Future<void>.delayed(const Duration(milliseconds: 60));

        final sampleRate = HoplaBleCodec.readU16le(await _readRaw(HoplaGattUuids.sampleRate));
        await tinyGap();
        final logInterval = HoplaBleCodec.readU16le(await _readRaw(HoplaGattUuids.logInterval));
        await tinyGap();
        final advInterval = HoplaBleCodec.readU16le(await _readRaw(HoplaGattUuids.advInterval));
        await tinyGap();
        final txPower = HoplaBleCodec.readI8(await _readRaw(HoplaGattUuids.txPower));
        await tinyGap();
        final deviceName = HoplaBleCodec.readUtf8(await _readRaw(HoplaGattUuids.deviceName));
        await tinyGap();
        final accelThresh = HoplaBleCodec.readU16le(await _readRaw(HoplaGattUuids.accelThresh));
        await tinyGap();
        final accelRangeBytes = await _readRaw(HoplaGattUuids.accelRange);
        final accelRange = accelRangeBytes.isEmpty ? null : accelRangeBytes[0];
        await tinyGap();
        final calibBytes = await _readRaw(HoplaGattUuids.accelCalib);
        final calibX = HoplaBleCodec.readI16leAt(calibBytes, 0);
        final calibY = HoplaBleCodec.readI16leAt(calibBytes, 2);
        final calibZ = HoplaBleCodec.readI16leAt(calibBytes, 4);
        await tinyGap();
        final modeBytes = await _readRaw(HoplaGattUuids.mode);
        final mode = modeBytes.isEmpty ? null : modeBytes[0];

        return (
          sampleRate: sampleRate,
          logInterval: logInterval,
          advInterval: advInterval,
          txPower: txPower,
          deviceName: deviceName,
          accelThresh: accelThresh,
          accelRange: accelRange,
          calibX: calibX,
          calibY: calibY,
          calibZ: calibZ,
          mode: mode,
        );
      });

      if (!mounted) return;
      setState(() {
        _sampleRateCtrl.text = result.sampleRate.toString();
        _logIntervalCtrl.text = result.logInterval.toString();
        _advIntervalCtrl.text = result.advInterval.toString();
        _txPowerCtrl.text = result.txPower.toString();
        _deviceNameCtrl.text = result.deviceName;
        _accelThreshCtrl.text = result.accelThresh.toString();
        _accelRange = _normalizeRange(result.accelRange);
        _calibXCtrl.text = result.calibX.toString();
        _calibYCtrl.text = result.calibY.toString();
        _calibZCtrl.text = result.calibZ.toString();
        _mode = result.mode;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Błąd odczytu: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
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

  Future<void> _writeAll() async {
    await _writeField(() async {
      final sampleRate = _parseInt(_sampleRateCtrl.text);
      final logInterval = _parseInt(_logIntervalCtrl.text);
      final advInterval = _parseInt(_advIntervalCtrl.text);
      final txPower = _parseInt(_txPowerCtrl.text);
      final deviceName = _deviceNameCtrl.text;
      final accelThresh = _parseInt(_accelThreshCtrl.text);
      final calibX = _parseInt(_calibXCtrl.text);
      final calibY = _parseInt(_calibYCtrl.text);
      final calibZ = _parseInt(_calibZCtrl.text);

      if (sampleRate != null) {
        await _write(HoplaGattUuids.sampleRate, HoplaBleCodec.u16le(sampleRate));
      }
      if (logInterval != null) {
        await _write(HoplaGattUuids.logInterval, HoplaBleCodec.u16le(logInterval));
      }
      if (advInterval != null) {
        await _write(HoplaGattUuids.advInterval, HoplaBleCodec.u16le(advInterval));
      }
      if (txPower != null) {
        await _write(HoplaGattUuids.txPower, HoplaBleCodec.i8(txPower));
      }
      final nameBytes = HoplaBleCodec.utf8Bytes(deviceName);
      if (nameBytes.length > 20) {
        throw Exception('Device Name max 20 bajtów (UTF-8). Teraz: ${nameBytes.length}.');
      }
      await _write(HoplaGattUuids.deviceName, nameBytes);

      if (accelThresh != null) {
        await _write(HoplaGattUuids.accelThresh, HoplaBleCodec.u16le(accelThresh));
      }
      if (_accelRange != null) {
        await _write(HoplaGattUuids.accelRange, HoplaBleCodec.u8(_accelRange!));
      }
      if (calibX != null && calibY != null && calibZ != null) {
        final bytes = Uint8List.fromList([
          ...HoplaBleCodec.i16le(calibX),
          ...HoplaBleCodec.i16le(calibY),
          ...HoplaBleCodec.i16le(calibZ),
        ]);
        await _write(HoplaGattUuids.accelCalib, bytes);
      }
      if (_mode != null) {
        await _write(HoplaGattUuids.mode, HoplaBleCodec.u8(_mode!));
      }
    });
  }

  Future<void> _logCtrlWrite(Uint8List cmd) async {
    await _writeField(() => _write(HoplaGattUuids.logCtrl, cmd));
  }

  Future<void> _readLogsBestEffort() async {
    // flutter_reactive_ble does not expose "Read long / Read blob" offsets.
    // We still read a single chunk (usually <= MTU-1) so user can see something.
    await _writeField(() async {
      final bytes = await _read(HoplaGattUuids.logs);
      _logsText = HoplaBleCodec.readUtf8(bytes);
      if (!mounted) return;
      setState(() {});
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
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : _readAll,
                  child: const Text('Odczytaj wszystko'),
                ),
                FilledButton.tonal(
                  onPressed: _busy || !_isConnected ? null : _writeAll,
                  child: const Text('Zapisz wszystko'),
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
              onWrite: () => _write(HoplaGattUuids.sampleRate, HoplaBleCodec.u16le(_parseInt(_sampleRateCtrl.text) ?? 0)),
            ),
            _fieldU16(
              label: 'Log Interval (ms)',
              controller: _logIntervalCtrl,
              onWrite: () => _write(HoplaGattUuids.logInterval, HoplaBleCodec.u16le(_parseInt(_logIntervalCtrl.text) ?? 0)),
            ),
            _fieldU16(
              label: 'Adv Interval (ms)',
              controller: _advIntervalCtrl,
              onWrite: () => _write(HoplaGattUuids.advInterval, HoplaBleCodec.u16le(_parseInt(_advIntervalCtrl.text) ?? 0)),
            ),
            _fieldI8(
              label: 'TX Power (dBm)',
              controller: _txPowerCtrl,
              helper: 'Typowe: -40,-20,-16,-12,-8,-4,0,3,4',
              onWrite: () => _write(HoplaGattUuids.txPower, HoplaBleCodec.i8(_parseInt(_txPowerCtrl.text) ?? 0)),
            ),
            _fieldText(
              label: 'Device Name (1..20 bajtów UTF-8)',
              controller: _deviceNameCtrl,
              onWrite: () async {
                final bytes = HoplaBleCodec.utf8Bytes(_deviceNameCtrl.text);
                if (bytes.length > 20) {
                  throw Exception('Max 20 bajtów UTF-8. Teraz: ${bytes.length}.');
                }
                await _write(HoplaGattUuids.deviceName, bytes);
              },
            ),
            _fieldU16(
              label: 'Accel Threshold (mg)',
              controller: _accelThreshCtrl,
              onWrite: () => _write(HoplaGattUuids.accelThresh, HoplaBleCodec.u16le(_parseInt(_accelThreshCtrl.text) ?? 0)),
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
                  tooltip: 'Zapisz calib',
                  onPressed: _busy || !_isConnected
                      ? null
                      : () => _writeField(() async {
                            final x = _parseInt(_calibXCtrl.text) ?? 0;
                            final y = _parseInt(_calibYCtrl.text) ?? 0;
                            final z = _parseInt(_calibZCtrl.text) ?? 0;
                            final bytes = Uint8List.fromList([
                              ...HoplaBleCodec.i16le(x),
                              ...HoplaBleCodec.i16le(y),
                              ...HoplaBleCodec.i16le(z),
                            ]);
                            await _write(HoplaGattUuids.accelCalib, bytes);
                          }),
                  icon: const Icon(Icons.save),
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
    required Future<void> Function() onWrite,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      onWrite: onWrite,
    );
  }

  Widget _fieldI8({
    required String label,
    required TextEditingController controller,
    String? helper,
    required Future<void> Function() onWrite,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.number,
      helper: helper,
      onWrite: onWrite,
    );
  }

  Widget _fieldText({
    required String label,
    required TextEditingController controller,
    required Future<void> Function() onWrite,
  }) {
    return _fieldRow(
      label: label,
      controller: controller,
      keyboardType: TextInputType.text,
      onWrite: onWrite,
    );
  }

  Widget _fieldRow({
    required String label,
    required TextEditingController controller,
    required TextInputType keyboardType,
    String? helper,
    required Future<void> Function() onWrite,
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
            tooltip: 'Zapisz',
            onPressed: _busy || !_isConnected ? null : () => _writeField(onWrite),
            icon: const Icon(Icons.save),
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
          tooltip: 'Zapisz range',
          onPressed: _busy || !_isConnected || _accelRange == null
              ? null
              : () => _writeField(() => _write(HoplaGattUuids.accelRange, HoplaBleCodec.u8(_accelRange!))),
          icon: const Icon(Icons.save),
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
          tooltip: 'Zapisz mode',
          onPressed: _busy || !_isConnected || _mode == null
              ? null
              : () => _writeField(() => _write(HoplaGattUuids.mode, HoplaBleCodec.u8(_mode!))),
          icon: const Icon(Icons.save),
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
              'Uwaga: firmware wspiera “Read long / Read blob”, ale flutter_reactive_ble nie udostępnia offsetów — więc odczyt logów jest „best effort” (jedna porcja).',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey.shade700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : () => _logCtrlWrite(Uint8List.fromList([0x01])),
                  child: const Text('Clear'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : () => _logCtrlWrite(Uint8List.fromList([0x02, 0x01])),
                  child: const Text('Freeze ON'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : () => _logCtrlWrite(Uint8List.fromList([0x02, 0x00])),
                  child: const Text('Freeze OFF'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_isConnected ? null : () => _logCtrlWrite(Uint8List.fromList([0x04])),
                  child: const Text('Cursor=0'),
                ),
                FilledButton.tonal(
                  onPressed: _busy || !_isConnected ? null : _readLogsBestEffort,
                  child: const Text('Czytaj logs'),
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


