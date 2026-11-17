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
        dtcs = []
        dtcCount = nil
        mil = false
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

    /// Un pedido al carro. `header` dirige el pedido a un módulo concreto (motor 7E0, caja 7E2);
    /// sin header va a todos los módulos (7DF), que es lo normal en OBD2.
    private struct Request {
        let cmd: String
        let header: String?
        init(_ cmd: String, header: String? = nil) { self.cmd = cmd; self.header = header }
        var key: String { (header ?? "") + cmd }
    }

    private var requests: [Request] = []

    private func startPolling() {
        polling = true
        cycle = 0
        requests = []
        pollNext()
    }

    private func stopPolling() {
        polling = false
        requests = []
        finish(nil)
    }

    private func pollNext() {
        guard polling, device?.state == .connected else { return }
        if requests.isEmpty {
            cycle += 1
            if cycle > 1 { emit() }
            // Siempre: velocidad, RPM y flujo de aire (para el consumo real).
            var next = [Request("010D"), Request("010C"), Request("0110")]
            // Cada tanto: temperatura, batería, tanque, aceite y caja.
            if cycle % 8 == 1 {
                next += [Request("0105"), Request("ATRV"), Request("012F"), Request("015C"),
                         Request("221154", header: "7E0"),     // aceite (GM)
                         Request("221940", header: "7E2")]     // caja automática (GM)
            }
            // De vez en cuando: luz de check engine, códigos y odómetro.
            if cycle % 40 == 1 { next += [Request("0101"), Request("01A6")] }
            requests = next.filter { !unsupported.contains($0.key) }
        }
        guard !requests.isEmpty else { return }
        let req = requests.removeFirst()
        perform(req) { [weak self] r in
            guard let self else { return }
            self.parse(req, r)
            if req.cmd == "0101", let count = self.dtcCount, count > 0 {
                self.requests.insert(Request("03"), at: 0)   // leer los códigos
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.pollNext() }
        }
    }

    /// Envía el pedido; si va a un módulo concreto, cambia el header y luego lo devuelve a 7DF.
    private func perform(_ req: Request, done: @escaping (String?) -> Void) {
        guard let header = req.header else {
            send(req.cmd, timeout: req.cmd == "03" ? 3 : 1.5, done: done)
            return
        }
        send("ATSH" + header, timeout: 1) { [weak self] _ in
            self?.send(req.cmd, timeout: 1.5) { r in
                self?.send("ATSH7DF", timeout: 1) { _ in done(r) }
            }
        }
    }

    private static func clean(_ r: String?) -> String {
        (r ?? "").uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Respuesta esperada: el modo + 0x40 y el resto del pedido (010D → 410D, 221154 → 621154).
    private static func responsePrefix(_ cmd: String) -> String? {
        guard cmd.count >= 2, let mode = Int(cmd.prefix(2), radix: 16) else { return nil }
        return String(format: "%02X", mode + 0x40) + cmd.dropFirst(2)
    }

    private static func bytes(after prefix: String, in clean: String) -> [Int]? {
        guard let range = clean.range(of: prefix) else { return nil }
        let hex = Array(clean[range.upperBound...].prefix(while: { $0.isHexDigit }))
        var out: [Int] = []
        var i = 0
        while i + 1 < hex.count {
            if let b = Int(String(hex[i...i + 1]), radix: 16) { out.append(b) }
            i += 2
        }
        return out
    }

    private var dtcCount: Int?
    private var mil = false
    private var dtcs: [String] = []

    private func parse(_ req: Request, _ r: String?) {
        let clean = Self.clean(r)
        let cmd = req.cmd

        if cmd == "ATRV" {
            let number = clean.filter { "0123456789.".contains($0) }
            if let v = Double(number), v > 5, v < 20 { values["volt"] = v }
            return
        }
        if cmd == "03" { parseDTCs(clean); return }

        guard let prefix = Self.responsePrefix(cmd),
              let b = Self.bytes(after: prefix, in: clean), let a = b.first else {
            switch cmd {
            case "010D": values.removeValue(forKey: "speed")
            case "010C": values.removeValue(forKey: "rpm")
            default: break
            }
            if r != nil {   // respondió pero sin el dato: tras varias veces, el carro no lo reporta
                misses[req.key, default: 0] += 1
                if misses[req.key, default: 0] >= 3 { unsupported.insert(req.key) }
            }
            return
        }
        misses[req.key] = 0
        let two: Double? = b.count >= 2 ? Double(a * 256 + b[1]) : nil
        switch cmd {
        case "010D": values["speed"] = Double(a)
        case "010C": if let two { values["rpm"] = two / 4 }
        case "0110": if let two { values["maf"] = two / 100 }
        case "0105": values["coolant"] = Double(a - 40)
        case "012F": values["fuel"] = Double(a) * 100 / 255
        case "015C", "221154": values["oil"] = Double(a - 40)
        case "221940": values["atf"] = Double(a - 40)
        case "01A6":
            if b.count >= 4 {
                let km = Double((a << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) / 10
                if km > 100 { values["odo"] = km }
            }
        case "0101":
            mil = (a & 0x80) != 0
            dtcCount = a & 0x7F
            if dtcCount == 0 { dtcs = [] }
        default: break
        }
    }

    /// Códigos de falla (modo 03). En CAN cada módulo responde aparte, con el número de códigos
    /// al inicio, y una respuesta larga llega en varias líneas numeradas (0:, 1:, 2:…).
    private func parseDTCs(_ clean: String) {
        let isCAN = (protocolName ?? "").contains("15765")
        var segments: [String] = []
        for raw in clean.split(separator: "\n").map(String.init) {
            if raw.count <= 3 && raw.allSatisfy({ $0.isHexDigit }) { continue }   // largo del mensaje
            var line = raw
            var frame: Int?
            if let colon = line.firstIndex(of: ":") {
                frame = Int(line[..<colon], radix: 16)
                line = String(line[line.index(after: colon)...])
            }
            let hex = line.filter { $0.isHexDigit }
            if hex.hasPrefix("43") && (frame == nil || frame == 0) {
                segments.append(String(hex.dropFirst(2)))
            } else if frame != nil, !segments.isEmpty {
                segments[segments.count - 1] += hex
            }
        }
        var codes: [String] = []
        for var seg in segments {
            var limit = Int.max
            if isCAN, seg.count >= 2, let n = Int(seg.prefix(2), radix: 16) {
                limit = n
                seg = String(seg.dropFirst(2))
            }
            var i = seg.startIndex
            var taken = 0
            while taken < limit, seg.distance(from: i, to: seg.endIndex) >= 4 {
                let chunk = String(seg[i..<seg.index(i, offsetBy: 4)])
                i = seg.index(i, offsetBy: 4)
                taken += 1
                guard chunk != "0000", let v = Int(chunk, radix: 16) else { continue }
                let letter = ["P", "C", "B", "U"][(v >> 14) & 3]
                let code = letter + String((v >> 12) & 3) + String(format: "%03X", v & 0xFFF)
                if !codes.contains(code) { codes.append(code) }
            }
        }
        dtcs = codes
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
            d["mil"] = mil
            d["dtc"] = dtcs
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
