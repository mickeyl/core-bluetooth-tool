import Foundation
import Testing

private enum ScanTestError: Error {
    case binaryNotFound
    case unreadableOutput
}

private struct ScanTestConfiguration {
    let preferredPeripheral: UUID?
    let preferredServiceUUID: String?
    let preferredCharacteristicUUID: String?
    let preferredDescriptorUUID: String?
    let baselineDuration: Duration
    let scanDuration: Duration
    let extendedScanDuration: Duration

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        preferredPeripheral = environment["CBT_SCAN_PERIPHERAL_UUID"].flatMap(UUID.init(uuidString:))
        preferredServiceUUID = environment["CBT_SCAN_SERVICE_UUID"].flatMap { $0.isEmpty ? nil : $0 }
        preferredCharacteristicUUID = environment["CBT_SCAN_CHARACTERISTIC_UUID"].flatMap { $0.isEmpty ? nil : $0 }
        preferredDescriptorUUID = environment["CBT_SCAN_DESCRIPTOR_UUID"].flatMap { $0.isEmpty ? nil : $0 }

        func duration(for key: String, defaultSeconds: Double) -> Duration {
            guard let raw = environment[key], let value = Double(raw), value > 0 else {
                return .seconds(defaultSeconds)
            }
            return .seconds(value)
        }

        baselineDuration = duration(for: "CBT_SCAN_BASELINE_SECONDS", defaultSeconds: 20)
        scanDuration = duration(for: "CBT_SCAN_DURATION_SECONDS", defaultSeconds: 12)
        extendedScanDuration = duration(for: "CBT_SCAN_EXTENDED_DURATION_SECONDS", defaultSeconds: 14)
    }
}

private actor ScanScenario {
    private let binaryURL: URL
    private var cachedBaseline: ScanResult?
    private let configuration: ScanTestConfiguration

    init(configuration: ScanTestConfiguration) throws {
        self.binaryURL = try Self.locateBinary()
        self.configuration = configuration
    }

    func baseline(duration: Duration? = nil) async throws -> ScanResult {
        if let cachedBaseline {
            return cachedBaseline
        }
        let baselineDuration = duration ?? configuration.baselineDuration
        let result = try await run(arguments: [], duration: baselineDuration)
        cachedBaseline = result
        return result
    }

    func run(arguments: [String], duration: Duration? = nil) async throws -> ScanResult {
        let scanDuration = duration ?? configuration.scanDuration
        return try await execute(arguments: arguments, duration: scanDuration)
    }

    private func execute(arguments: [String], duration: Duration) async throws -> ScanResult {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["scan"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        try await Task.sleep(for: duration)
        if process.isRunning {
            process.interrupt()
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pipe.fileHandleForReading.closeFile()

        guard let rawOutput = String(data: data, encoding: .utf8) else {
            throw ScanTestError.unreadableOutput
        }
        let sanitizedOutput = Self.sanitize(rawOutput)
        let lines = sanitizedOutput.split(whereSeparator: { $0.isNewline }).map(String.init)
        let snapshot = ScanSnapshot(lines: lines)
        return ScanResult(command: ["scan"] + arguments, rawOutput: rawOutput, sanitizedOutput: sanitizedOutput, snapshot: snapshot)
    }

    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\u001B\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private static func locateBinary() throws -> URL {
#if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("core-bluetooth-tool")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
#endif

        let fileURL = URL(fileURLWithPath: #filePath)
        var searchRoot = fileURL.deletingLastPathComponent() // Tests/target
        searchRoot.deleteLastPathComponent() // Tests
        searchRoot.deleteLastPathComponent() // package root

        let buildRoot = searchRoot.appendingPathComponent(".build")
        if let binary = findBinary(named: "core-bluetooth-tool", under: buildRoot) {
            return binary
        }

        throw ScanTestError.binaryNotFound
    }

    private static func findBinary(named name: String, under root: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return nil }
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isExecutableKey], options: options) {
            for case let url as URL in enumerator where url.lastPathComponent == name {
                if fm.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        return nil
    }
}

private struct ScanResult {
    let command: [String]
    let rawOutput: String
    let sanitizedOutput: String
    let snapshot: ScanSnapshot
}

private struct ScanSnapshot {
    struct Peripheral {
        struct Service {
            struct Characteristic {
                let uuid: String
                let descriptors: [String]
            }

            let uuid: String
            let characteristics: [Characteristic]

            func characteristic(_ uuid: String) -> Characteristic? {
                characteristics.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
            }
        }

        let identifier: UUID
        let name: String
        let services: [Service]

        func service(_ uuid: String) -> Service? {
            services.first { $0.uuid.caseInsensitiveCompare(uuid) == .orderedSame }
        }
    }

    let peripherals: [Peripheral]
    let lines: [String]

    init(lines: [String]) {
        self.lines = lines
        self.peripherals = ScanSnapshot.buildPeripherals(from: lines)
    }

    func peripheral(_ identifier: UUID) -> Peripheral? {
        peripherals.first { $0.identifier == identifier }
    }

    func servicePath(preferredPeripheral: UUID?, preferredServiceUUID: String?) -> (peripheral: Peripheral, service: Peripheral.Service)? {
        let orderedPeripherals = peripherals.sequenceMatchingPeripheral(preferredPeripheral)
        if let preferredServiceUUID {
            for peripheral in orderedPeripherals {
                if let service = peripheral.service(preferredServiceUUID) {
                    return (peripheral, service)
                }
            }
        }
        return firstServicePath(in: orderedPeripherals)
    }

    private func firstServicePath(in orderedPeripherals: [Peripheral]? = nil) -> (peripheral: Peripheral, service: Peripheral.Service)? {
        let source = orderedPeripherals ?? peripherals
        for peripheral in source {
            if let service = peripheral.services.first {
                return (peripheral, service)
            }
        }
        return nil
    }

    func characteristicPath(preferredPeripheral: UUID?, preferredServiceUUID: String?, preferredCharacteristicUUID: String?) -> (peripheral: Peripheral, service: Peripheral.Service, characteristic: Peripheral.Service.Characteristic)? {
        let orderedPeripherals = peripherals.sequenceMatchingPeripheral(preferredPeripheral)
        if let preferredCharacteristicUUID {
            for peripheral in orderedPeripherals {
                let services = servicesMatchingPreference(in: peripheral, preferredServiceUUID: preferredServiceUUID)
                for service in services {
                    if let characteristic = service.characteristic(preferredCharacteristicUUID) {
                        return (peripheral, service, characteristic)
                    }
                }
            }
        }
        if let preferredServiceUUID {
            for peripheral in orderedPeripherals {
                if let service = peripheral.service(preferredServiceUUID), let characteristic = service.characteristics.first {
                    return (peripheral, service, characteristic)
                }
            }
        }
        return firstCharacteristicPath(in: orderedPeripherals)
    }

    private func firstCharacteristicPath(in orderedPeripherals: [Peripheral]? = nil) -> (peripheral: Peripheral, service: Peripheral.Service, characteristic: Peripheral.Service.Characteristic)? {
        let source = orderedPeripherals ?? peripherals
        for peripheral in source {
            for service in peripheral.services {
                if let characteristic = service.characteristics.first {
                    return (peripheral, service, characteristic)
                }
            }
        }
        return nil
    }

    func descriptorPath(preferredPeripheral: UUID?, preferredServiceUUID: String?, preferredCharacteristicUUID: String?, preferredDescriptorUUID: String?) -> (peripheral: Peripheral, service: Peripheral.Service, characteristic: Peripheral.Service.Characteristic, descriptor: String)? {
        let orderedPeripherals = peripherals.sequenceMatchingPeripheral(preferredPeripheral)
        if let preferredDescriptorUUID {
            for peripheral in orderedPeripherals {
                let services = servicesMatchingPreference(in: peripheral, preferredServiceUUID: preferredServiceUUID)
                for service in services {
                    let characteristics = characteristicsMatchingPreference(in: service, preferredCharacteristicUUID: preferredCharacteristicUUID)
                    for characteristic in characteristics {
                        if characteristic.descriptors.contains(where: { $0.caseInsensitiveCompare(preferredDescriptorUUID) == .orderedSame }) {
                            return (peripheral, service, characteristic, preferredDescriptorUUID)
                        }
                    }
                }
            }
        }
        if let preferredCharacteristicUUID {
            for peripheral in orderedPeripherals {
                let services = servicesMatchingPreference(in: peripheral, preferredServiceUUID: preferredServiceUUID)
                for service in services {
                    if let characteristic = service.characteristic(preferredCharacteristicUUID), let descriptor = characteristic.descriptors.first {
                        return (peripheral, service, characteristic, descriptor)
                    }
                }
            }
        }
        if let preferredServiceUUID {
            for peripheral in orderedPeripherals {
                if let service = peripheral.service(preferredServiceUUID) {
                    for characteristic in service.characteristics {
                        if let descriptor = characteristic.descriptors.first {
                            return (peripheral, service, characteristic, descriptor)
                        }
                    }
                }
            }
        }
        return firstDescriptorPath(in: orderedPeripherals)
    }

    private func firstDescriptorPath(in orderedPeripherals: [Peripheral]? = nil) -> (peripheral: Peripheral, service: Peripheral.Service, characteristic: Peripheral.Service.Characteristic, descriptor: String)? {
        let source = orderedPeripherals ?? peripherals
        for peripheral in source {
            for service in peripheral.services {
                for characteristic in service.characteristics {
                    if let descriptor = characteristic.descriptors.first {
                        return (peripheral, service, characteristic, descriptor)
                    }
                }
            }
        }
        return nil
    }

    private func servicesMatchingPreference(in peripheral: Peripheral, preferredServiceUUID: String?) -> [Peripheral.Service] {
        if let preferredServiceUUID, let service = peripheral.service(preferredServiceUUID) {
            return [service]
        }
        return peripheral.services
    }

    private func characteristicsMatchingPreference(in service: Peripheral.Service, preferredCharacteristicUUID: String?) -> [Peripheral.Service.Characteristic] {
        if let preferredCharacteristicUUID, let characteristic = service.characteristic(preferredCharacteristicUUID) {
            return [characteristic]
        }
        return service.characteristics
    }

    private static func buildPeripherals(from lines: [String]) -> [Peripheral] {
        struct CharacteristicBuilder {
            let uuid: String
            var descriptors: [String]

            mutating func addDescriptor(_ uuid: String) {
                if !descriptors.contains(where: { $0.caseInsensitiveCompare(uuid) == .orderedSame }) {
                    descriptors.append(uuid)
                }
            }
        }

        struct ServiceBuilder {
            let uuid: String
            var characteristicOrder: [String] = []
            var characteristics: [String: CharacteristicBuilder]

            init(uuid: String) {
                self.uuid = uuid
                self.characteristics = [:]
            }

            mutating func ensureCharacteristic(_ uuid: String) -> CharacteristicBuilder {
                if let existing = characteristics[uuid] {
                    return existing
                }
                characteristicOrder.append(uuid)
                let builder = CharacteristicBuilder(uuid: uuid, descriptors: [])
                characteristics[uuid] = builder
                return builder
            }

            mutating func updateCharacteristic(_ builder: CharacteristicBuilder) {
                characteristics[builder.uuid] = builder
            }
        }

        struct PeripheralBuilder {
            var name: String
            var serviceOrder: [String] = []
            var services: [String: ServiceBuilder]

            init(name: String) {
                self.name = name
                self.services = [:]
            }

            mutating func ensureService(_ uuid: String) -> ServiceBuilder {
                if let existing = services[uuid] {
                    return existing
                }
                serviceOrder.append(uuid)
                let builder = ServiceBuilder(uuid: uuid)
                services[uuid] = builder
                return builder
            }

            mutating func updateService(_ builder: ServiceBuilder) {
                services[builder.uuid] = builder
            }
        }

        var order: [UUID] = []
        var peripherals: [UUID: PeripheralBuilder] = [:]

        func sanitizeUUIDComponent(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for line in lines {
            if line.hasPrefix("(P) ") {
                let payload = line.dropFirst(4)
                let parts = payload.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count >= 1, let identifier = UUID(uuidString: String(parts[0])) else { continue }
                let name = parts.count > 1 ? String(parts[1]) : ""
                if peripherals[identifier] == nil {
                    order.append(identifier)
                    peripherals[identifier] = PeripheralBuilder(name: name)
                }
            } else if line.hasPrefix("(S) ") {
                let payload = line.dropFirst(4)
                let parts = payload.split(separator: "\t")
                guard parts.count >= 3, let identifier = UUID(uuidString: String(parts[0])) else { continue }
                let serviceUUID = sanitizeUUIDComponent(String(parts[2]))
                var builder = peripherals[identifier] ?? PeripheralBuilder(name: parts.count > 1 ? String(parts[1]) : "")
                _ = builder.ensureService(serviceUUID)
                peripherals[identifier] = builder
            } else if line.hasPrefix("(C) ") {
                let payload = line.dropFirst(4)
                let parts = payload.split(separator: "\t")
                guard parts.count >= 3, let identifier = UUID(uuidString: String(parts[0])) else { continue }
                let combined = parts[2].split(separator: ".")
                guard combined.count >= 2 else { continue }
                let serviceUUID = sanitizeUUIDComponent(String(combined[0]))
                let characteristicUUID = sanitizeUUIDComponent(String(combined[1]))
                var builder = peripherals[identifier] ?? PeripheralBuilder(name: parts.count > 1 ? String(parts[1]) : "")
                var service = builder.ensureService(serviceUUID)
                _ = service.ensureCharacteristic(characteristicUUID)
                builder.updateService(service)
                peripherals[identifier] = builder
            } else if line.hasPrefix("(D) ") {
                let payload = line.dropFirst(4)
                let parts = payload.split(separator: "\t")
                guard parts.count >= 3, let identifier = UUID(uuidString: String(parts[0])) else { continue }
                let combined = parts[2].split(separator: ".")
                guard combined.count >= 3 else { continue }
                let serviceUUID = sanitizeUUIDComponent(String(combined[0]))
                let characteristicUUID = sanitizeUUIDComponent(String(combined[1]))
                let descriptorUUID = sanitizeUUIDComponent(String(combined[2]))
                var builder = peripherals[identifier] ?? PeripheralBuilder(name: parts.count > 1 ? String(parts[1]) : "")
                var service = builder.ensureService(serviceUUID)
                var characteristic = service.ensureCharacteristic(characteristicUUID)
                characteristic.addDescriptor(descriptorUUID)
                service.updateCharacteristic(characteristic)
                builder.updateService(service)
                peripherals[identifier] = builder
            }
        }

        return order.compactMap { identifier in
            guard let builder = peripherals[identifier] else { return nil }
            let services = builder.serviceOrder.compactMap { serviceUUID -> Peripheral.Service? in
                guard let serviceBuilder = builder.services[serviceUUID] else { return nil }
                let characteristics = serviceBuilder.characteristicOrder.compactMap { characteristicUUID -> Peripheral.Service.Characteristic? in
                    guard let characteristicBuilder = serviceBuilder.characteristics[characteristicUUID] else { return nil }
                    return Peripheral.Service.Characteristic(uuid: characteristicBuilder.uuid, descriptors: characteristicBuilder.descriptors)
                }
                return Peripheral.Service(uuid: serviceBuilder.uuid, characteristics: characteristics)
            }
            return Peripheral(identifier: identifier, name: builder.name, services: services)
        }
    }
}

private extension Array where Element == ScanSnapshot.Peripheral {
    func sequenceMatchingPeripheral(_ preferred: UUID?) -> [ScanSnapshot.Peripheral] {
        guard let preferred else { return self }
        if let match = first(where: { $0.identifier == preferred }) {
            return [match]
        }
        return self
    }
}

private let testConfiguration = ScanTestConfiguration()
private let scenario = try! ScanScenario(configuration: testConfiguration)

@Suite("Scan Command", .serialized)
struct ScanCommandTests {

    @Test("scan all devices")
    func scanAllDevices() async throws {
        let result = try await scenario.baseline()
        #expect(!result.snapshot.peripherals.isEmpty, "Expected at least one peripheral to be discovered during baseline scan.")
    }

    @Test("scan by service")
    func scanByService() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.servicePath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID) else {
            Issue.record("No services discovered during baseline scan; cannot exercise service-specific scan mode.")
            return
        }

        let result = try await scenario.run(arguments: [path.service.uuid])
        guard let rediscovered = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Service scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(rediscovered.service(path.service.uuid) != nil, "Expected service \(path.service.uuid) to be reported.")
    }

    @Test("scan by service and characteristic")
    func scanByServiceCharacteristic() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.characteristicPath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID, preferredCharacteristicUUID: testConfiguration.preferredCharacteristicUUID) else {
            Issue.record("No characteristics discovered during baseline scan; cannot exercise characteristic-specific scan mode.")
            return
        }

        let argument = "\(path.service.uuid).\(path.characteristic.uuid)"
        let result = try await scenario.run(arguments: [argument])
        guard let peripheral = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Characteristic scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let service = peripheral.service(path.service.uuid) else {
            Issue.record("Characteristic scan did not report service \(path.service.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(service.characteristic(path.characteristic.uuid) != nil, "Expected characteristic \(path.characteristic.uuid) to be reported.")
    }

    @Test("scan by service, characteristic, and descriptor")
    func scanByServiceCharacteristicDescriptor() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.descriptorPath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID, preferredCharacteristicUUID: testConfiguration.preferredCharacteristicUUID, preferredDescriptorUUID: testConfiguration.preferredDescriptorUUID) else {
            Issue.record("No descriptors discovered during baseline scan; cannot exercise descriptor-specific scan mode.")
            return
        }

        let argument = "\(path.service.uuid).\(path.characteristic.uuid).\(path.descriptor)"
        let result = try await scenario.run(arguments: [argument], duration: testConfiguration.extendedScanDuration)
        guard let peripheral = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Descriptor scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let service = peripheral.service(path.service.uuid) else {
            Issue.record("Descriptor scan did not report service \(path.service.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let characteristic = service.characteristic(path.characteristic.uuid) else {
            Issue.record("Descriptor scan did not report characteristic \(path.characteristic.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(characteristic.descriptors.contains(where: { $0.caseInsensitiveCompare(path.descriptor) == .orderedSame }) == true, "Expected descriptor \(path.descriptor) to be reported.")
    }

    @Test("scan by device identifier")
    func scanByDeviceIdentifier() async throws {
        let baseline = try await scenario.baseline()
        let targetPeripheral: ScanSnapshot.Peripheral?
        if let preferred = testConfiguration.preferredPeripheral {
            targetPeripheral = baseline.snapshot.peripheral(preferred)
        } else {
            targetPeripheral = baseline.snapshot.peripherals.first
        }
        guard let peripheral = targetPeripheral else {
            Issue.record("No peripherals discovered during baseline scan; cannot exercise device-specific scan mode.")
            return
        }

        let argument = "device.\(peripheral.identifier.uuidString)"
        let result = try await scenario.run(arguments: [argument])
        #expect(result.snapshot.peripheral(peripheral.identifier) != nil, "Expected to rediscover peripheral \(peripheral.identifier).")
    }

    @Test("scan by device and service")
    func scanByDeviceAndService() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.servicePath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID) else {
            Issue.record("No services discovered during baseline scan; cannot exercise device+service scan mode.")
            return
        }

        let argument = "device.\(path.peripheral.identifier.uuidString).\(path.service.uuid)"
        let result = try await scenario.run(arguments: [argument])
        guard let peripheral = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Device+service scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(peripheral.service(path.service.uuid) != nil, "Expected service \(path.service.uuid) to be reported.")
    }

    @Test("scan by device, service, and characteristic")
    func scanByDeviceServiceCharacteristic() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.characteristicPath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID, preferredCharacteristicUUID: testConfiguration.preferredCharacteristicUUID) else {
            Issue.record("No characteristics discovered during baseline scan; cannot exercise device+service+characteristic scan mode.")
            return
        }

        let argument = "device.\(path.peripheral.identifier.uuidString).\(path.service.uuid).\(path.characteristic.uuid)"
        let result = try await scenario.run(arguments: [argument])
        guard let peripheral = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Device+service+characteristic scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let service = peripheral.service(path.service.uuid) else {
            Issue.record("Device+service+characteristic scan did not report service \(path.service.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(service.characteristic(path.characteristic.uuid) != nil, "Expected characteristic \(path.characteristic.uuid) to be reported.")
    }

    @Test("scan by device, service, characteristic, and descriptor")
    func scanByDeviceServiceCharacteristicDescriptor() async throws {
        let baseline = try await scenario.baseline()
        guard let path = baseline.snapshot.descriptorPath(preferredPeripheral: testConfiguration.preferredPeripheral, preferredServiceUUID: testConfiguration.preferredServiceUUID, preferredCharacteristicUUID: testConfiguration.preferredCharacteristicUUID, preferredDescriptorUUID: testConfiguration.preferredDescriptorUUID) else {
            Issue.record("No descriptors discovered during baseline scan; cannot exercise full device scan mode.")
            return
        }

        let argument = "device.\(path.peripheral.identifier.uuidString).\(path.service.uuid).\(path.characteristic.uuid).\(path.descriptor)"
        let result = try await scenario.run(arguments: [argument], duration: testConfiguration.extendedScanDuration)
        guard let peripheral = result.snapshot.peripheral(path.peripheral.identifier) else {
            Issue.record("Device+service+characteristic+descriptor scan did not rediscover peripheral \(path.peripheral.identifier). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let service = peripheral.service(path.service.uuid) else {
            Issue.record("Device+service+characteristic+descriptor scan did not report service \(path.service.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        guard let characteristic = service.characteristic(path.characteristic.uuid) else {
            Issue.record("Device+service+characteristic+descriptor scan did not report characteristic \(path.characteristic.uuid). Output:\n\(result.sanitizedOutput)")
            return
        }
        #expect(characteristic.descriptors.contains(where: { $0.caseInsensitiveCompare(path.descriptor) == .orderedSame }) == true, "Expected descriptor \(path.descriptor) to be reported.")
    }
}
