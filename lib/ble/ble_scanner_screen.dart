import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:hopla/ble/hopla_adv_parser.dart';

class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  final FlutterReactiveBle _ble = FlutterReactiveBle();
  final Map<String, DiscoveredDevice> _devices = {};
  bool _isScanning = false;
  String? _errorMessage;
  bool _permissionsGranted = false;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    // Sprawdź i poproś o uprawnienia
    final locationStatus = await Permission.locationWhenInUse.request();
    final bluetoothStatus = await Permission.bluetoothScan.request();
    
    if (locationStatus.isGranted && bluetoothStatus.isGranted) {
      setState(() {
        _permissionsGranted = true;
      });
      _startScan();
    } else {
      setState(() {
        _errorMessage = 'Wymagane są uprawnienia do lokalizacji i Bluetooth';
        _permissionsGranted = false;
      });
    }
  }

  void _startScan() {
    if (!_permissionsGranted) {
      _checkPermissions();
      return;
    }

    setState(() {
      _isScanning = true;
      _errorMessage = null;
      _devices.clear();
    });

    _ble.scanForDevices(
      withServices: [],
      scanMode: ScanMode.lowLatency,
      requireLocationServicesEnabled: false,
    ).listen(
      (device) {
        // Filtruj tylko urządzenia zaczynające się od "Hopla!"
        final deviceName = device.name;
        if (deviceName.isNotEmpty && deviceName.startsWith('Hopla!')) {
          setState(() {
            // Aktualizuj lub dodaj urządzenie (deduplikacja po id)
            _devices[device.id] = device;
          });
        }
      },
      onError: (error) {
        setState(() {
          _isScanning = false;
          _errorMessage = 'Błąd skanowania: $error';
        });
      },
    );
  }

  void _stopScan() {
    _ble.stopScan();
    setState(() {
      _isScanning = false;
    });
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  void _showDeviceDetails(DiscoveredDevice device) {
    final manufacturerData = device.manufacturerData;
    final parsedData = HoplaAdvParser.parseManufacturerData(manufacturerData);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  device.name.isNotEmpty ? device.name : 'Bez nazwy',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'ID: ${device.id}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                Text(
                  'RSSI: ${device.rssi} dBm',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const Divider(height: 24),
                Text(
                  'Raw Advertising Data',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const SizedBox(height: 8),
                if (manufacturerData != null && manufacturerData.isNotEmpty) ...[
                  Text(
                    'Manufacturer Data (hex):',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    HoplaAdvParser.formatManufacturerDataMap(manufacturerData),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                        ),
                  ),
                ] else
                  Text(
                    'Brak Manufacturer Data',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey,
                        ),
                  ),
                if (device.serviceData.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Service Data:',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 4),
                  ...device.serviceData.entries.map((entry) => Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text(
                          '${entry.key}: ${HoplaAdvParser.formatUint8ListAsHex(entry.value)}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                      )),
                ],
                if (device.serviceUuids.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Service UUIDs:',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                  const SizedBox(height: 4),
                  ...device.serviceUuids.map((uuid) => Padding(
                        padding: const EdgeInsets.only(left: 16, bottom: 4),
                        child: Text(
                          uuid,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                              ),
                        ),
                      )),
                ],
                if (parsedData != null && parsedData.isValid) ...[
                  const Divider(height: 24),
                  Text(
                    'Parsed Hopla Payload',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const SizedBox(height: 8),
                  _buildDataRow('X (mg)', parsedData.xMg?.toString() ?? 'N/A'),
                  _buildDataRow('Y (mg)', parsedData.yMg?.toString() ?? 'N/A'),
                  _buildDataRow('Z (mg)', parsedData.zMg?.toString() ?? 'N/A'),
                  _buildDataRow('Sequence', parsedData.seq?.toString() ?? 'N/A'),
                ],
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDataRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontFamily: 'monospace',
                ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hopla! BLE Scanner'),
        actions: [
          if (_isScanning)
            IconButton(
              icon: const Icon(Icons.stop),
              onPressed: _stopScan,
              tooltip: 'Zatrzymaj skanowanie',
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScan,
              tooltip: 'Rozpocznij skanowanie',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.red.shade100,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.red),
                  ),
                  if (!_permissionsGranted)
                    TextButton(
                      onPressed: _checkPermissions,
                      child: const Text('Sprawdź uprawnienia ponownie'),
                    ),
                ],
              ),
            ),
          if (_isScanning)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.blue.shade50,
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  const Text('Skanowanie w toku...'),
                ],
              ),
            ),
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bluetooth_searching,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isScanning
                              ? 'Szukam urządzeń Hopla!...'
                              : 'Naciśnij przycisk, aby rozpocząć skanowanie',
                          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                color: Colors.grey.shade600,
                              ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices.values.elementAt(index);
                      final parsedData = HoplaAdvParser.parseManufacturerData(
                        device.manufacturerData,
                      );

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.bluetooth,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          title: Text(
                            device.name.isNotEmpty ? device.name : 'Bez nazwy',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('ID: ${device.id}'),
                              Text('RSSI: ${device.rssi} dBm'),
                              if (parsedData != null && parsedData.isValid)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text(
                                    'XYZ: ${parsedData.xMg}/${parsedData.yMg}/${parsedData.zMg} mg, Seq: ${parsedData.seq}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _showDeviceDetails(device),
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

