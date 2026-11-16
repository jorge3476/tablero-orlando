import CoreBluetooth
import Foundation

/// Lee el escáner OBD2 Bluetooth (Vgate iCar Pro y otros ELM327 de bajo consumo).
/// Datos: velocidad, RPM, temperatura del motor, voltaje de batería y, si el carro lo
/// reporta, nivel del tanque. Se reconecta solo cuando el carro vuelve a encender.
final class OBDManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    var onUpdate: ((String) -> Void)?

    private struct Found {
        let periph: CBPeripheral
        let name: String
        let rssi: Int
    }

    private var central: CBCentralManager?
    private var device: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var found: [UUID: Found] = [:]
    private var state = "idle"
    private var errorText: String?
    private var protocolName: String?

    private var buffer = ""
    private var pendingDone: ((String?) -> Void)?
    private var timeoutWork: DispatchWorkItem?
    private var servicesLeft = 0
    private var polling = false
    private var queue: [String] = []
    private var cycle = 0
    private var unsupported = Set<String>()
    private var misses: [String: Int] = [:]
    private var values: [String: Double] = [:]

    private let savedKey = "obdPeripheral"
    /// Servicios conocidos de escáneres ELM327 de bajo consumo, en orden de preferencia.
    private let knownServices = [
        CBUUID(string: "FFF0"), CBUUID(string: "FFE0"), CBUUID(string: "18F0"),
        CBUUID(string: "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2")
    ]
    private let ignoredServices: Set<CBUUID> = [
        CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A"), CBUUID(string: "180F")
    ]

    // MARK: - Lo que pide la página

    func start() {
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)   // aquí iOS pide el permiso de Bluetooth
        } else {
            reconnectSaved()
            emit()
        }
    }

    func scan() {
        guard let central, central.state == .poweredOn else { start(); return }
        stopPolling()
        if let p = device { central.cancelPeripheralConnection(p) }
        device = nil
        found.removeAll()
        setState("scanning")
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.state == "scanning" else { return }
            self.central?.stopScan()
        }
    }

    func connect(id: String) {
        guard let uuid = UUID(uuidString: id), let item = found[uuid] else { return }
        central?.stopScan()
        UserDefaults.standard.set(id, forKey: savedKey)
        connect(item.periph)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        stopPolling()
        central?.stopScan()
        if let p = device { central?.cancelPeripheralConnection(p) }
        device = nil
        writeChar = nil
        notifyChar = nil
        setState("idle")
    }

    // MARK: - Conexión

    private func reconnectSaved() {
        guard let central, central.state == .poweredOn, device == nil else { return }
        if let saved = UserDefaults.standard.string(forKey: savedKey),
           let uuid = UUID(uuidString: saved),
           let p = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(p)
        } else {
            setState("idle")
        }
    }

    private func connect(_ p: CBPeripheral) {
        device = p
        p.delegate = self
        writeChar = nil
        notifyChar = nil
        setState("connecting")
        central?.connect(p, options: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: reconnectSaved()
        case .unauthorized: setState("unauthorized")
        case .poweredOff: stopPolling(); setState("off")
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard !name.isEmpty else { return }
        found[p.identifier] = Found(periph: p, name: name, rssi: RSSI.intValue)
        emit()
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        setState("initializing")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "no se pudo conectar")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.device === p else { return }
            self.central?.connect(p, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        stopPolling()
        writeChar = nil
        notifyChar = nil
        guard device === p else { return }
        setState("disconnected")
        // Conexión pendiente: iOS la completa sola cuando el escáner vuelva a encender.
        central.connect(p, options: nil)
    }

    // MARK: - Servicios y canal de datos

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = (p.services ?? []).filter { !ignoredServices.contains($0.uuid) }
        servicesLeft = services.count
        if services.isEmpty { fail("el escáner no ofrece un canal de datos"); return }
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        servicesLeft -= 1
        guard servicesLeft <= 0, writeChar == nil else { return }

        // Primero los servicios conocidos; si no, cualquiera que permita escribir y recibir.
        let services = p.services ?? []
        let ordered = knownServices.compactMap { id in services.first { $0.uuid == id } }
            + services.filter { !knownServices.contains($0.uuid) && !ignoredServices.contains($0.uuid) }
        for svc in ordered {
            let chars = svc.characteristics ?? []
            let w = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
            let n = chars.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
            if let w, let n {
                writeChar = w
                notifyChar = n
                p.setNotifyValue(true, for: n)
                return
            }
        }
        fail("no encontré el canal de datos del escáner")
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard c == notifyChar else { return }
        if let error { fail(error.localizedDescription); return }
        initializeAdapter()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard c == notifyChar, let data = c.value,
              let text = String(data: data, encoding: .isoLatin1) else { return }
        buffer += text
        if buffer.contains(">") {
            let response = buffer.replacingOccurrences(of: ">", with: "")
            buffer = ""
            finish(response)
        }
    }

    // MARK: - Comandos ELM327

    private func send(_ cmd: String, timeout: Double = 2.5, done: @escaping (String?) -> Void) {
        guard let p = device, let w = writeChar, p.state == .connected else { done(nil); return }
        pendingDone = done
        buffer = ""
        let type: CBCharacteristicWriteType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(Data((cmd + "\r").utf8), for: w, type: type)
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func finish(_ response: String?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        guard let done = pendingDone else { return }
        pendingDone = nil
        done(response)
    }

    private func run(_ cmds: [String], then: @escaping () -> Void) {
        guard let first = cmds.first else { then(); return }
        send(first, timeout: first == "ATZ" ? 4 : 2) { [weak self] _ in
            self?.run(Array(cmds.dropFirst()), then: then)
        }
    }

    private func initializeAdapter() {
        unsupported.removeAll()
        misses.removeAll()
        values.removeAll()
        run(["ATZ", "ATE0", "ATL0", "ATS0", "ATH0", "ATSP0"]) { [weak self] in
            self?.connectToCar()
        }
    }

    /// Busca el protocolo del carro. Con el motor apagado el carro no responde: se reintenta.
    private func connectToCar() {
        send("0100", timeout: 10) { [weak self] r in
            guard let self else { return }
            let clean = Self.clean(r)
            if clean.contains("4100") {
                self.send("ATDP") { proto in
                    self.protocolName = proto?.replacingOccurrences(of: "\r", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "AUTO, ", with: "")
                    self.setState("connected")
                    self.startPolling()
                }
            } else if self.device?.state == .connected {
                self.fail("el carro no responde. Enciende el motor (o pon la llave en ON)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.device?.state == .connected, !self.polling else { return }
                    self.setState("initializing")
                    self.connectToCar()
                }
            }
        }
    }

    private func startPolling() {
        polling = true
        cycle = 0
        queue = []
        pollNext()
    }

    private func stopPolling() {
        polling = false
        queue = []
        finish(nil)
    }

    private func pollNext() {
        guard polling, device?.state == .connected else { return }
        if queue.isEmpty {
            cycle += 1
            if cycle > 1 { emit() }
            var next = ["010D", "010C"]                                   // velocidad y RPM, siempre
            if cycle % 8 == 1 { next += ["0105", "ATRV", "012F"] }        // temperatura, batería y tanque, cada tanto
            queue = next.filter { !unsupported.contains($0) }
        }
        guard !queue.isEmpty else { return }
        let cmd = queue.removeFirst()
        send(cmd, timeout: 1.5) { [weak self] r in
            guard let self else { return }
            self.parse(cmd, r)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.pollNext() }
        }
    }

    private static func clean(_ r: String?) -> String {
        (r ?? "").uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static let keys = ["0D": "speed", "0C": "rpm", "05": "coolant", "2F": "fuel"]

    private func parse(_ cmd: String, _ r: String?) {
        let clean = Self.clean(r)
        if cmd == "ATRV" {
            let number = clean.filter { "0123456789.".contains($0) }
            if let v = Double(number), v > 5, v < 20 { values["volt"] = v }
            return
        }
        let pid = String(cmd.suffix(2))
        guard let range = clean.range(of: "41" + pid) else {
            if let key = Self.keys[pid] { values.removeValue(forKey: key) }
            if r != nil {   // respondió pero sin el dato: tras varias veces, el carro no lo reporta
                misses[cmd, default: 0] += 1
                if misses[cmd, default: 0] >= 4 { unsupported.insert(cmd) }
            }
            return
        }
        misses[cmd] = 0
        let hex = Array(clean[range.upperBound...].prefix(while: { $0.isHexDigit }))
        var bytes: [Int] = []
        var i = 0
        while i + 1 < hex.count {
            if let b = Int(String(hex[i...i + 1]), radix: 16) { bytes.append(b) }
            i += 2
        }
        guard let a = bytes.first else { return }
        switch pid {
        case "0D": values["speed"] = Double(a)
        case "0C": if bytes.count >= 2 { values["rpm"] = Double(a * 256 + bytes[1]) / 4 }
        case "05": values["coolant"] = Double(a - 40)
        case "2F": values["fuel"] = Double(a) * 100 / 255
        default: break
        }
    }

    // MARK: - Estado hacia la página

    private func fail(_ message: String) {
        errorText = message
        state = "error"
        emit()
    }

    private func setState(_ s: String) {
        state = s
        errorText = nil
        emit()
    }

    private static func isLikely(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["obd", "vlink", "vlinker", "vgate", "icar", "elm", "v-link", "konnwei", "veepeak"].contains { n.contains($0) }
    }

    private func emit() {
        var d: [String: Any] = ["state": state]
        if let name = device?.name { d["name"] = name }
        if let e = errorText { d["error"] = e }
        if state == "connected" {
            if let p = protocolName { d["proto"] = p }
            for (k, v) in values { d[k] = v }
        }
        if state == "scanning" {
            let list = found.values.sorted {
                let a = Self.isLikely($0.name), b = Self.isLikely($1.name)
                return a != b ? a : $0.rssi > $1.rssi
            }
            d["devices"] = list.map { f -> [String: Any] in
                ["id": f.periph.identifier.uuidString, "name": f.name, "likely": Self.isLikely(f.name)]
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: d),
           let json = String(data: data, encoding: .utf8) {
            onUpdate?(json)
        }
    }
}
