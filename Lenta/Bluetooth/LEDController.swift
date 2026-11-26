import Foundation
import CoreBluetooth

/// Контроллер LEDDMX-03 (приложение LED LAMP): сервис FFE0, запись в FFE1 без ответа, команды 9 байт 7B…BF.
final class LEDController: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle, bluetoothOff, unauthorized, unsupported
        case searching, connecting, connected(String)
        case reconnecting(Int), lost, failed(String)
    }

    struct Found: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        var matches: Bool
    }

    // MARK: опубликованное состояние (только main)
    @Published private(set) var status: Status = .idle
    @Published private(set) var isConnected = false
    @Published private(set) var found: [Found] = []
    @Published private(set) var scanning = false
    @Published var showPicker = false
    @Published var showAll = false {
        didSet { let all = showAll; q.async { self.showAllQ = all; self.refreshFoundListQ() } }
    }

    static let serviceUUID = CBUUID(string: "FFE0")
    static let elkServiceUUID = CBUUID(string: "FFF0")
    static let elkCharUUID = CBUUID(string: "FFF3")
    static let charUUID = CBUUID(string: "FFE1")
    private static let lastDeviceKey = "lenta.lastDeviceID"
    private static let lastNameKey = "lenta.lastDeviceName"

    // MARK: внутреннее (только очередь q)
    private let q = DispatchQueue(label: "lenta.ble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var ch: CBCharacteristic?
    private var seen: [UUID: CBPeripheral] = [:]
    private var seenInfo: [UUID: Found] = [:]
    private var pending: [(String, Data)] = []
    private var busy = false
    private var userDisconnect = false
    private var dropTries = 0
    private var attempt = 0
    private var wantAuto = true
    private var showAllQ = false
    /// Тихий поиск ленты, с которой уже работали (если iOS её «забыла»)
    private var autoScan = false
    private var autoScanBudget = 3

    /// Вызывается на main после подключения
    var onConnected: (() -> Void)?

    override init() {
        super.init()
        // восстановление: iOS сама поднимет приложение, когда лента снова появится рядом
        central = CBCentralManager(delegate: self, queue: q, options: [
            CBCentralManagerOptionShowPowerAlertKey: true,
            CBCentralManagerOptionRestoreIdentifierKey: "lenta.central"
        ])
    }

    // MARK: - Публичные действия (с main)

    /// Кнопка «Подключить»: сначала знакомая лента, иначе поиск со списком
    func connectTapped() {
        showPicker = true
        q.async {
            if let p = self.peripheral, p.state != .connected {
                self.connect(p)
            }
            self.startScan()
        }
    }

    func choose(_ id: UUID) {
        showPicker = false
        q.async {
            guard let p = self.seen[id] else { return }
            self.stopScanQ()
            // другая лента: старую отпускаем (её событие отключения потом пропустим)
            if let old = self.peripheral, old.identifier != id {
                if old.state != .disconnected { self.central.cancelPeripheralConnection(old) }
                self.ch = nil
                self.pending.removeAll()
                self.busy = false
                self.ui { self.isConnected = false }
            }
            self.connect(p)
        }
    }

    func stopScan() { q.async { self.stopScanQ() } }

    func disconnect() {
        q.async {
            guard let p = self.peripheral else { return }
            self.userDisconnect = true
            self.wantAuto = false
            self.central.cancelPeripheralConnection(p)
        }
    }

    /// Тихо подключиться к ленте, с которой работали в прошлый раз (на старте и для таймеров)
    func autoConnect() {
        q.async {
            self.wantAuto = true
            self.autoScanBudget = 3
            if self.central.state == .poweredOn { self.autoConnectQ() }
        }
    }

    /// Одна запись за раз; от каждого вида команды отправляется только последнее значение
    @discardableResult
    func send(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard isConnected else { return false }
        q.async {
            let data = self.ch?.uuid == Self.elkCharUUID ? Cmd.elk(key, bytes) : bytes
            guard !data.isEmpty else { return }
            self.pending.removeAll { $0.0 == key }
            self.pending.append((key, Data(data)))
            self.pump()
        }
        return true
    }

    // MARK: - Внутреннее

    private func ui(_ block: @escaping () -> Void) { DispatchQueue.main.async(execute: block) }
    private func setStatus(_ s: Status) { ui { self.status = s } }

    private func autoConnectQ() {
        if let p = peripheral, p.state == .connected || p.state == .connecting { return }
        if let str = UserDefaults.standard.string(forKey: Self.lastDeviceKey), let id = UUID(uuidString: str),
           let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(p)
            return
        }
        let already = central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID, Self.elkServiceUUID])
        if let p = already.first(where: { Self.nameMatches($0.name) }) ?? already.first {
            connect(p)
            return
        }
        startAutoScan()
    }

    /// Лента уже подключалась, но iOS не знает её по номеру — ищем по имени и подключаемся сами
    private func startAutoScan() {
        let pending = peripheral.map { $0.state != .disconnected } ?? false
        guard let name = UserDefaults.standard.string(forKey: Self.lastNameKey), !name.isEmpty,
              central.state == .poweredOn, ch == nil, autoScanBudget > 0 else {
            if ch == nil && !pending { setStatus(.idle) }
            return
        }
        autoScanBudget -= 1
        autoScan = true
        setStatus(.searching)
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
        q.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoScan else { return }
            self.autoScan = false
            if self.central.isScanning && !self.scanningForPicker { self.central.stopScan() }
            if self.ch == nil, let p = self.peripheral, p.state != .disconnected {
                self.setStatus(.searching)     // ждём через отложенное подключение
            } else if self.ch == nil {
                self.setStatus(.idle)
            }
        }
    }

    private var scanningForPicker = false

    private static func nameMatches(_ name: String?) -> Bool {
        guard let n = name else { return false }
        return n.hasPrefix("LEDDMX") || n.hasPrefix("LEDBLE") || n.hasPrefix("ELK-BLEDDM")
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        attempt += 1
        let my = attempt
        setStatus(.connecting)
        central.connect(p, options: nil)
        // CoreBluetooth ждёт ленту сколько угодно; через 10 с честно говорим, что ищем
        q.asyncAfter(deadline: .now() + 10) {
            guard my == self.attempt, self.ch == nil else { return }
            self.setStatus(.searching)
            if !self.autoScan { self.startAutoScan() }
        }
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        seenInfo = [:]
        refreshFoundListQ()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanningForPicker = true
        ui { self.scanning = true }
        q.asyncAfter(deadline: .now() + 20) { [weak self] in self?.stopScanQ() }
    }

    private func stopScanQ() {
        scanningForPicker = false
        if central.isScanning && !autoScan { central.stopScan() }
        ui { self.scanning = false }
    }

    private func refreshFoundListQ() {
        let all = seenInfo.values.sorted { a, b in
            if a.matches != b.matches { return a.matches }
            return a.rssi > b.rssi
        }
        let list = all.filter { $0.matches || (showAllQ && !$0.name.isEmpty) }
        ui { self.found = list }
    }

    private func pump() {
        guard !busy, let p = peripheral, let c = ch, !pending.isEmpty else { return }
        let noResponse = c.properties.contains(.writeWithoutResponse)
        if noResponse && !p.canSendWriteWithoutResponse { return }   // продолжим в peripheralIsReady
        busy = true
        let (_, data) = pending.removeFirst()
        p.writeValue(data, for: c, type: noResponse ? .withoutResponse : .withResponse)
        q.asyncAfter(deadline: .now() + .milliseconds(noResponse ? 12 : 20)) {
            self.busy = false
            self.pump()
        }
    }

    private func linkReady(_ p: CBPeripheral, _ c: CBCharacteristic) {
        ch = c
        dropTries = 0
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastDeviceKey)
        if let n = p.name, !n.isEmpty { UserDefaults.standard.set(n, forKey: Self.lastNameKey) }
        autoScan = false
        let name = p.name ?? "Лента"
        ui {
            self.isConnected = true
            self.status = .connected(name)
            self.showPicker = false
            self.onConnected?()
        }
        stopScanQ()
    }
}

// MARK: - CBCentralManagerDelegate

extension LEDController: CBCentralManagerDelegate {

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let list = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let p = list.first else { return }
        peripheral = p
        p.delegate = self
        if p.state == .connected { p.discoverServices([Self.serviceUUID, Self.elkServiceUUID]) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if wantAuto { autoConnectQ() } else { setStatus(.idle) }
        case .poweredOff:
            ch = nil
            ui { self.isConnected = false; self.status = .bluetoothOff }
        case .unauthorized:
            setStatus(.unauthorized)
        case .unsupported:
            setStatus(.unsupported)
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? p.name ?? ""
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let matches = Self.nameMatches(name) || services.contains(Self.serviceUUID) || services.contains(Self.elkServiceUUID)
        seen[p.identifier] = p
        seenInfo[p.identifier] = Found(id: p.identifier, name: name, rssi: RSSI.intValue, matches: matches)
        refreshFoundListQ()
        if autoScan, ch == nil, !name.isEmpty, name == UserDefaults.standard.string(forKey: Self.lastNameKey) {
            autoScan = false
            if !scanningForPicker { central.stopScan() }
            if let old = peripheral, old.identifier != p.identifier, old.state != .disconnected {
                central.cancelPeripheralConnection(old)
            }
            connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p.identifier == peripheral?.identifier else { central.cancelPeripheralConnection(p); return }
        setStatus(.connecting)
        p.discoverServices([Self.serviceUUID, Self.elkServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        setStatus(.failed("Не удалось подключиться"))
        // пробуем ещё раз сами: лента могла быть занята другим телефоном
        q.asyncAfter(deadline: .now() + 2) {
            guard self.ch == nil, self.peripheral?.identifier == p.identifier, self.wantAuto else { return }
            self.connect(p)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        ch = nil
        pending.removeAll()
        busy = false
        ui { self.isConnected = false }
        if userDisconnect {
            userDisconnect = false
            setStatus(.idle)
            return
        }
        // лента сама оборвала связь (например, её забрало родное приложение): возвращаем её сами
        dropTries += 1
        let tries = dropTries
        setStatus(.reconnecting(min(tries, 4)))
        attempt += 1
        let my = attempt
        central.connect(p, options: nil)          // ждёт, пока лента снова появится
        q.asyncAfter(deadline: .now() + 15) {
            guard my == self.attempt, self.ch == nil else { return }
            self.setStatus(.lost)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension LEDController: CBPeripheralDelegate {

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let hasLegacyService = p.services?.contains { $0.uuid == Self.serviceUUID } == true
        let serviceID = hasLegacyService ? Self.serviceUUID : Self.elkServiceUUID
        guard let s = p.services?.first(where: { $0.uuid == serviceID }) else {
            setStatus(.failed("У устройства нет сервиса \(serviceID.uuidString)"))
            return
        }
        let writeID = serviceID == Self.elkServiceUUID ? Self.elkCharUUID : Self.charUUID
        p.discoverCharacteristics([writeID], for: s)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let writeID = service.uuid == Self.elkServiceUUID ? Self.elkCharUUID : Self.charUUID
        guard let c = service.characteristics?.first(where: { $0.uuid == writeID }) else {
            setStatus(.failed("Нет характеристики \(writeID.uuidString)"))
            return
        }
        linkReady(p, c)
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }
}

// MARK: - Команды 7B … BF

enum Cmd {
    static func elk(_ key: String, _ bytes: [UInt8]) -> [UInt8] {
        switch key {
        case "power": return [0x7E, 0, 4, bytes[3] == 1 ? 0xF0 : 0, 0, bytes[3], 0xFF, 0, 0xEF]
        case "color": return [0x7E, 0, 5, 3, bytes[3], bytes[4], bytes[5], 0, 0xEF]
        case "brightness": return [0x7E, 0, 1, UInt8((Double(bytes[4]) * 255 / 100).rounded()), 0, 0, 0, 0, 0xEF]
        case "effect": return [0x7E, 0, 3, bytes[3], 0, 0, 0, 0, 0xEF]
        default: return []
        }
    }

    static func power(_ on: Bool) -> [UInt8] {
        [0x7B, 0x04, 0x04, on ? 1 : 0, 0xFF, 0xFF, 0xFF, 0xFF, 0xBF]
    }
    /// Байты уже в порядке каналов ленты (по умолчанию GRB)
    static func color(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> [UInt8] {
        [0x7B, 0xFF, 0x07, a, b, c, 0x00, 0xFF, 0xBF]
    }
    static func brightness(_ percent: Int) -> [UInt8] {
        let p = clamp(percent, 0, 100)
        return [0x7B, 0xFF, 0x01, UInt8((Double(p) * 32 / 100).rounded()), UInt8(p), 0x00, 0xFF, 0xFF, 0xBF]
    }
    static func effect(_ n: Int) -> [UInt8] {
        [0x7B, 0xFF, 0x03, UInt8(clamp(n, 1, 210)), 0xFF, 0xFF, 0xFF, 0xFF, 0xBF]
    }
}
