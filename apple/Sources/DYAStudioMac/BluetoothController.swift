import AppKit
import CoreBluetooth
import Foundation

final class BluetoothController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let serviceUUID = CBUUID(string: "00000000-0196-6107-C967-C5CFB1C2482A")
    private static let rpcCharacteristicUUID = CBUUID(string: "00000001-0196-6107-C967-C5CFB1C2482A")
    private static let batteryServiceUUID = CBUUID(string: "180F")

    var onData: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    private var central: CBCentralManager!
    private var discovered: [UUID: (peripheral: CBPeripheral, rssi: NSNumber)] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var rpcCharacteristic: CBCharacteristic?
    private var connectCompletion: ((Result<[String: Any], Error>) -> Void)?
    private var scanTimer: Timer?
    private var pendingWriteChunks: [Data] = []
    private var writeCompletion: ((Error?) -> Void)?
    private var intentionalDisconnect = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isAvailable: Bool {
        central.state == .poweredOn || central.state == .unknown || central.state == .resetting
    }

    func connect(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard connectCompletion == nil else {
            completion(.failure(BridgeError.message("A Bluetooth connection attempt is already in progress.")))
            return
        }
        disconnect(notify: false)
        connectCompletion = completion
        intentionalDisconnect = false

        switch central.state {
        case .poweredOn:
            beginScan()
        case .unknown, .resetting:
            break
        case .poweredOff:
            failConnection("Bluetooth is turned off. Turn it on and try again.")
        case .unauthorized:
            failConnection("Bluetooth access is not authorized. Enable it in System Settings > Privacy & Security > Bluetooth.")
        case .unsupported:
            failConnection("Bluetooth Low Energy is not supported on this Mac.")
        @unknown default:
            failConnection("Bluetooth is unavailable.")
        }
    }

    func write(_ data: Data, completion: @escaping (Error?) -> Void) {
        guard writeCompletion == nil else {
            completion(BridgeError.message("A Bluetooth write is already in progress."))
            return
        }
        guard let peripheral = connectedPeripheral, let characteristic = rpcCharacteristic else {
            completion(BridgeError.message("Bluetooth keyboard is not connected."))
            return
        }

        let supportsResponse = characteristic.properties.contains(.write)
        let writeType: CBCharacteristicWriteType = supportsResponse ? .withResponse : .withoutResponse
        guard supportsResponse || characteristic.properties.contains(.writeWithoutResponse) else {
            completion(BridgeError.message("The keyboard RPC characteristic is not writable."))
            return
        }

        let maximumLength = max(1, peripheral.maximumWriteValueLength(for: writeType))
        pendingWriteChunks = stride(from: 0, to: data.count, by: maximumLength).map { offset in
            data.subdata(in: offset..<min(offset + maximumLength, data.count))
        }
        writeCompletion = completion

        if writeType == .withResponse {
            sendNextWriteWithResponse()
        } else {
            for chunk in pendingWriteChunks {
                peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            }
            pendingWriteChunks.removeAll()
            finishWrite(nil)
        }
    }

    func disconnect(notify: Bool) {
        scanTimer?.invalidate()
        scanTimer = nil
        central.stopScan()
        intentionalDisconnect = !notify

        if let peripheral = connectedPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        rpcCharacteristic = nil
        pendingWriteChunks.removeAll()
        finishWrite(BridgeError.message("Bluetooth connection closed."))

        if let completion = connectCompletion {
            connectCompletion = nil
            completion(.failure(BridgeError.message("Bluetooth connection cancelled.")))
        }
        if notify { onDisconnect?() }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard connectCompletion != nil else { return }
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            failConnection("Bluetooth is turned off. Turn it on and try again.")
        case .unauthorized:
            failConnection("Bluetooth access is not authorized. Enable it in System Settings > Privacy & Security > Bluetooth.")
        case .unsupported:
            failConnection("Bluetooth Low Energy is not supported on this Mac.")
        default:
            break
        }
    }

    private func beginScan() {
        discovered.removeAll()
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertised = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let services = advertised + overflow
        guard services.contains(Self.serviceUUID) || services.contains(Self.batteryServiceUUID) else { return }
        discovered[peripheral.identifier] = (peripheral, RSSI)
    }

    private func finishScan() {
        scanTimer?.invalidate()
        scanTimer = nil
        central.stopScan()
        guard connectCompletion != nil else { return }

        let candidates = discovered.values.sorted { lhs, rhs in
            if lhs.rssi == rhs.rssi {
                return displayName(for: lhs.peripheral) < displayName(for: rhs.peripheral)
            }
            return lhs.rssi.intValue > rhs.rssi.intValue
        }
        guard !candidates.isEmpty else {
            failConnection("No ZMK Studio Bluetooth keyboard was found. Unlock Studio on the keyboard and try again.")
            return
        }

        let selected: CBPeripheral
        if candidates.count == 1 {
            selected = candidates[0].peripheral
        } else {
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            picker.addItems(withTitles: candidates.map { displayName(for: $0.peripheral) })
            let alert = NSAlert()
            alert.messageText = "Choose a Bluetooth keyboard"
            alert.informativeText = "Select a keyboard advertising the ZMK Studio service."
            alert.accessoryView = picker
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                failConnection("Bluetooth connection cancelled.")
                return
            }
            selected = candidates[picker.indexOfSelectedItem].peripheral
        }

        connectedPeripheral = selected
        selected.delegate = self
        central.connect(selected)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        failConnection(error?.localizedDescription ?? "Unable to connect to the Bluetooth keyboard.")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let wasIntentional = intentionalDisconnect
        intentionalDisconnect = false
        connectedPeripheral = nil
        rpcCharacteristic = nil
        pendingWriteChunks.removeAll()
        finishWrite(error ?? BridgeError.message("Bluetooth keyboard disconnected."))
        if connectCompletion != nil {
            failConnection(error?.localizedDescription ?? "Bluetooth keyboard disconnected during setup.")
        } else if !wasIntentional {
            onDisconnect?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failConnection(error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            failConnection("The selected keyboard does not expose the ZMK Studio service.")
            return
        }
        peripheral.discoverCharacteristics([Self.rpcCharacteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            failConnection(error.localizedDescription)
            return
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.rpcCharacteristicUUID }) else {
            failConnection("The selected keyboard does not expose the ZMK Studio RPC characteristic.")
            return
        }
        rpcCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            failConnection(error.localizedDescription)
            return
        }
        guard characteristic.uuid == Self.rpcCharacteristicUUID, characteristic.isNotifying else {
            failConnection("Could not enable ZMK Studio notifications.")
            return
        }
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(.success([
            "label": displayName(for: peripheral),
            "identifier": peripheral.identifier.uuidString,
        ]))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == Self.rpcCharacteristicUUID,
              let value = characteristic.value else { return }
        onData?(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            pendingWriteChunks.removeAll()
            finishWrite(error)
            return
        }
        sendNextWriteWithResponse()
    }

    private func sendNextWriteWithResponse() {
        guard let peripheral = connectedPeripheral, let characteristic = rpcCharacteristic else {
            finishWrite(BridgeError.message("Bluetooth keyboard is not connected."))
            return
        }
        guard !pendingWriteChunks.isEmpty else {
            finishWrite(nil)
            return
        }
        peripheral.writeValue(pendingWriteChunks.removeFirst(), for: characteristic, type: .withResponse)
    }

    private func finishWrite(_ error: Error?) {
        guard let completion = writeCompletion else { return }
        writeCompletion = nil
        completion(error)
    }

    private func failConnection(_ message: String) {
        scanTimer?.invalidate()
        scanTimer = nil
        central.stopScan()
        if let peripheral = connectedPeripheral {
            intentionalDisconnect = true
            central.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        rpcCharacteristic = nil
        guard let completion = connectCompletion else { return }
        connectCompletion = nil
        completion(.failure(BridgeError.message(message)))
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        let name = peripheral.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name : nil) ?? "Bluetooth Keyboard"
    }
}
