import Foundation
import CoreBluetooth

// MARK: - JSON Protocols

struct Command: Decodable {
    let command: String
    let uuid: String?
    let services: [String]?
    let service: String?
    let characteristics: [String]?
    let characteristic: String?
    let data: String? // Hex string
}

struct Response: Encodable {
    let event: String
    let data: AnyCodable?
    
    enum CodingKeys: String, CodingKey {
        case event
        case data
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        if let data = data {
            try container.encode(data, forKey: .data)
        }
    }
}

struct AnyCodable: Encodable {
    let value: Any
    
    init(_ value: Any) {
        self.value = value
    }
    
    func encode(to encoder: Encoder) throws {
        if let string = value as? String {
            try string.encode(to: encoder)
        } else if let int = value as? Int {
            try int.encode(to: encoder)
        } else if let dict = value as? [String: AnyCodable] {
            try dict.encode(to: encoder)
        } else if let dict = value as? [String: String] {
            try dict.encode(to: encoder)
        } else if let dict = value as? [String: Int] {
            try dict.encode(to: encoder)
        } else if let array = value as? [String] {
            try array.encode(to: encoder)
        } else if let array = value as? [AnyCodable] {
            try array.encode(to: encoder)
        } else {
             var container = encoder.singleValueContainer()
             try container.encodeNil()
        }
    }
}

// MARK: - Bluetooth Manager

class BluetoothDriver: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    var connectedPeripherals: [UUID: CBPeripheral] = [:]
    
    override init() {
        super.init()
        self.centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Commands
    
    func handleCommand(_ cmd: Command) {
        switch cmd.command {
        case "scan":
            startScan()
        case "stopScan":
            stopScan()
        case "connect":
            if let uuidString = cmd.uuid, let uuid = UUID(uuidString: uuidString) {
                connect(uuid: uuid)
            }
        case "disconnect":
            if let uuidString = cmd.uuid, let uuid = UUID(uuidString: uuidString) {
                disconnect(uuid: uuid)
            }
        case "discoverServices":
            if let uuidString = cmd.uuid, let uuid = UUID(uuidString: uuidString) {
                let services = cmd.services?.compactMap { CBUUID(string: $0) }
                discoverServices(uuid: uuid, serviceUUIDs: services)
            }
        case "discoverCharacteristics":
            if let uuidString = cmd.uuid, let uuid = UUID(uuidString: uuidString), let serviceString = cmd.service {
                let characteristics = cmd.characteristics?.compactMap { CBUUID(string: $0) }
                discoverCharacteristics(uuid: uuid, serviceUUID: serviceString, characteristicUUIDs: characteristics)
            }
        case "read":
            if let uuidString = cmd.uuid,
               let uuid = UUID(uuidString: uuidString),
               let serviceString = cmd.service,
               let charString = cmd.characteristic {
                readValue(uuid: uuid, serviceUUID: serviceString, characteristicUUID: charString)
            }
        case "write":
            if let uuidString = cmd.uuid,
               let uuid = UUID(uuidString: uuidString),
               let serviceString = cmd.service,
               let charString = cmd.characteristic,
               let dataHex = cmd.data {
                writeValue(uuid: uuid, serviceUUID: serviceString, characteristicUUID: charString, dataHex: dataHex)
            }
        default:
            log("Unknown command: \(cmd.command)")
        }
    }
    
    func startScan() {
        guard centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: nil, options: nil)
        sendEvent(name: "scanStart")
    }
    
    func stopScan() {
        centralManager.stopScan()
        sendEvent(name: "scanStop")
    }
    
    func connect(uuid: UUID) {
        let known = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = known.first {
            discoveredPeripherals[uuid] = peripheral
            centralManager.connect(peripheral, options: nil)
        } else if let peripheral = discoveredPeripherals[uuid] {
             centralManager.connect(peripheral, options: nil)
        } else {
            log("Peripheral not found with UUID: \(uuid)")
        }
    }
    
    func disconnect(uuid: UUID) {
        if let peripheral = connectedPeripherals[uuid] ?? discoveredPeripherals[uuid] {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    func discoverServices(uuid: UUID, serviceUUIDs: [CBUUID]?) {
        guard let peripheral = connectedPeripherals[uuid] else {
            log("Cannot discover services: Device not connected")
            return
        }
        peripheral.discoverServices(serviceUUIDs)
    }
    
    func discoverCharacteristics(uuid: UUID, serviceUUID: String, characteristicUUIDs: [CBUUID]?) {
        guard let peripheral = connectedPeripherals[uuid] else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceUUID }) else {
            log("Service \(serviceUUID) not found on device \(uuid)")
            return
        }
        peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
    }
    
    func readValue(uuid: UUID, serviceUUID: String, characteristicUUID: String) {
        guard let (peripheral, characteristic) = findCharacteristic(uuid: uuid, serviceUUID: serviceUUID, characteristicUUID: characteristicUUID) else { return }
        peripheral.readValue(for: characteristic)
    }
    
    func writeValue(uuid: UUID, serviceUUID: String, characteristicUUID: String, dataHex: String) {
        guard let (peripheral, characteristic) = findCharacteristic(uuid: uuid, serviceUUID: serviceUUID, characteristicUUID: characteristicUUID) else { return }
        
        let data = dataFromHex(dataHex)
        // Determine type: withResponse or withoutResponse
        // We'll default to withResponse if property available, otherwise without
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: type)
        
        // If withoutResponse, we manually emit write success? Or wait for delegate?
        // didWriteValueFor is only called for .withResponse
        if type == .withoutResponse {
             sendEvent(name: "write", data: AnyCodable([
                "uuid": AnyCodable(uuid.uuidString),
                "service": AnyCodable(serviceUUID),
                "characteristic": AnyCodable(characteristicUUID),
                "success": AnyCodable(1) // Fake success
            ]))
        }
    }
    
    // MARK: - Helper Methods
    
    func findCharacteristic(uuid: UUID, serviceUUID: String, characteristicUUID: String) -> (CBPeripheral, CBCharacteristic)? {
        guard let peripheral = connectedPeripherals[uuid] else {
            log("Device \(uuid) not connected")
            return nil
        }
        guard let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceUUID }) else {
            log("Service \(serviceUUID) not found")
            return nil
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid.uuidString == characteristicUUID }) else {
            log("Characteristic \(characteristicUUID) not found")
            return nil
        }
        return (peripheral, characteristic)
    }
    
    func dataFromHex(_ hex: String) -> Data {
        var data = Data()
        var hexStr = hex
        if hexStr.count % 2 != 0 { hexStr = "0" + hexStr } // padding
        
        var i = hexStr.startIndex
        while i < hexStr.endIndex {
            let nextIndex = hexStr.index(i, offsetBy: 2)
            if let byte = UInt8(hexStr[i..<nextIndex], radix: 16) {
                data.append(byte)
            }
            i = nextIndex
        }
        return data
    }
    
    func hexFromData(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }
    
    // MARK: - Delegate Methods
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        var stateStr = "unknown"
        switch central.state {
        case .poweredOn: stateStr = "poweredOn"
        case .poweredOff: stateStr = "poweredOff"
        case .resetting: stateStr = "resetting"
        case .unauthorized: stateStr = "unauthorized"
        case .unsupported: stateStr = "unsupported"
        default: stateStr = "unknown"
        }
        sendEvent(name: "stateChange", data: AnyCodable(stateStr))
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        discoveredPeripherals[peripheral.identifier] = peripheral
        
        var info: [String: AnyCodable] = [
            "uuid": AnyCodable(peripheral.identifier.uuidString),
            "rssi": AnyCodable(RSSI.intValue)
        ]
        
        if let name = peripheral.name {
            info["name"] = AnyCodable(name)
        } else if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            info["name"] = AnyCodable(localName)
        }
        
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
           let uuids = serviceUUIDs.map { $0.uuidString.lowercased() }
           info["serviceUuids"] = AnyCodable(uuids)
        }
        
        sendEvent(name: "device", data: AnyCodable(info))
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        sendEvent(name: "connected", data: AnyCodable(["uuid": AnyCodable(peripheral.identifier.uuidString)]))
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
         // handle error
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        sendEvent(name: "disconnected", data: AnyCodable(["uuid": AnyCodable(peripheral.identifier.uuidString)]))
    }
    
    // MARK: - Peripheral Delegate
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("Error discovering services: \(error)")
            return
        }
        
        let services = peripheral.services?.map { $0.uuid.uuidString } ?? []
        let data: [String: AnyCodable] = [
            "uuid": AnyCodable(peripheral.identifier.uuidString),
            "services": AnyCodable(services.map { AnyCodable($0) })
        ]
        sendEvent(name: "services", data: AnyCodable(data))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            log("Error discovering characteristics: \(error)")
            return
        }
        
        let chars = service.characteristics?.map { $0.uuid.uuidString } ?? []
        let data: [String: AnyCodable] = [
            "uuid": AnyCodable(peripheral.identifier.uuidString),
            "service": AnyCodable(service.uuid.uuidString),
            "characteristics": AnyCodable(chars.map { AnyCodable($0) })
        ]
        sendEvent(name: "characteristics", data: AnyCodable(data))
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            log("Error reading value: \(error)")
            return
        }
        
        if let data = characteristic.value {
            let hex = hexFromData(data)
            let response: [String: AnyCodable] = [
                "uuid": AnyCodable(peripheral.identifier.uuidString),
                "service": AnyCodable(characteristic.service?.uuid.uuidString ?? ""),
                "characteristic": AnyCodable(characteristic.uuid.uuidString),
                "data": AnyCodable(hex)
            ]
            sendEvent(name: "read", data: AnyCodable(response))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        // called if write type was .withResponse
        let response: [String: AnyCodable] = [
            "uuid": AnyCodable(peripheral.identifier.uuidString),
            "service": AnyCodable(characteristic.service?.uuid.uuidString ?? ""),
            "characteristic": AnyCodable(characteristic.uuid.uuidString),
            "success": AnyCodable(error == nil ? 1 : 0)
        ]
         sendEvent(name: "write", data: AnyCodable(response))
    }
    
    // MARK: - Helpers
    
    func sendEvent(name: String, data: AnyCodable? = nil) {
        let response = Response(event: name, data: data)
        do {
            let jsonData = try JSONEncoder().encode(response)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
                fflush(stdout)
            }
        } catch {
            log("Failed to encode response: \(error)")
        }
    }
    
    func log(_ msg: String) {
        // Print logging as stderr
        fputs(msg + "\n", stderr)
    }
}

// MARK: - Main Loop

let driver = BluetoothDriver()

// Handle stdin
// We use a global to keep the buffer because HandleData comes in chunks
var inputBuffer = Data()

// Readability handler on stdin
FileHandle.standardInput.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
        // EOF
        exit(0)
    }
    
    inputBuffer.append(data)
    
    // Process lines
    while let range = inputBuffer.range(of: Data([0x0A])) { // \n
        let lineData = inputBuffer.subdata(in: 0..<range.lowerBound)
        inputBuffer.removeSubrange(0..<range.upperBound)
        
        if let line = String(data: lineData, encoding: .utf8) {
             // Parse JSON
             if let data = line.data(using: .utf8) {
                 do {
                     let cmd = try JSONDecoder().decode(Command.self, from: data)
                     // Dispatch to main thread to ensure CoreBluetooth safety
                     DispatchQueue.main.async {
                         driver.handleCommand(cmd)
                     }
                 } catch {
                     // driver.log("Invalid JSON: \(line)")
                 }
             }
        }
    }
}

// Start RunLoop
RunLoop.main.run()
