# Hopla! - Flutter Mobile App

Aplikacja mobilna do skanowania i interakcji z urządzeniami Hopla! przez Bluetooth Low Energy (BLE).

## Wymagania

- Flutter SDK (3.0.0 lub nowszy)
- Android Studio / Xcode
- Urządzenie fizyczne z Android/iOS (emulatory nie obsługują BLE)

## Instalacja

1. Zainstaluj zależności:
```bash
flutter pub get
```

2. Upewnij się, że masz skonfigurowane:
   - Android SDK (w `local.properties`)
   - Xcode (dla iOS)

## Uruchomienie

### Android
```bash
flutter run
```

### iOS
```bash
flutter run
```

## Funkcjonalności

- **Skanowanie BLE**: Automatyczne skanowanie urządzeń o nazwie zaczynającej się od "Hopla!"
- **Wyświetlanie danych**: Lista znalezionych urządzeń z podstawowymi informacjami
- **Szczegóły urządzenia**: Tap na urządzenie pokazuje pełne dane advertising, w tym:
  - Raw Manufacturer Data (hex)
  - Service Data
  - Service UUIDs
  - Parsed Hopla Payload (XYZ w mg, sequence)

## Uprawnienia

Aplikacja wymaga następujących uprawnień:
- **Android**: Bluetooth, Bluetooth Scan, Location
- **iOS**: Bluetooth Always Usage

Uprawnienia są konfigurowane automatycznie w odpowiednich plikach manifestów.

