# Проект: iOS-приложение «Лента» (SwiftUI + CoreBluetooth)

Отвечай по-русски, коротко. Порт сайта led-lenta.vercel.app (index.html) на Swift, минимум iOS 17.
Сборка: Xcode (Lenta.xcodeproj, синхронизированная папка Lenta/) или GitHub Actions → неподписанный IPA.

## Железо (как на сайте)
- LEDDMX-03, BLE сервис FFE0, запись в FFE1 без ответа. Команды 9 байт 7B…BF (Cmd в LEDController.swift).
- Цвет GRB + гамма 2.2. Лента держит одно подключение.

## Устройство кода
- Core/Services — все модели; доступ друг к другу через Services.shared (не трогать в init!).
- Bluetooth/LEDController — очередь записи: от каждого вида команды только последнее значение, пауза 20 мс.
- Audio/LightEngine — детектор бита и режимы, порт loop() с сайта; часы 10 мс, отправка ≤ 25/с.
- Audio/StreamAnalyzer — FFT 2048 + ВЧ 30 Гц + 3×НЧ, как Web Audio; FileAnalysis — разбор файла заранее.
- SoundCloud/ — виджет в WKWebView (сообщения webkit.messageHandlers.sc), форма волны + analyseTempo.
- Views/Glass — glassEffect на iOS 26 под `#if compiler(>=6.2)`, иначе .ultraThinMaterial.

## Правила
- Честно писать, что проверено на настоящем iPhone/ленте, а что нет.
