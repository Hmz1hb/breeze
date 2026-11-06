import Foundation
import Testing
@testable import FanApp

@Test func macInfoReadsHybridCPUAndGPUWithoutConfusingTheirCoreCounts() throws {
    let data = Data(#"""
    {"SPHardwareDataType":[{"machine_model":"MacBookPro18,2","machine_name":"MacBook Pro",
      "chip_type":"Apple M1 Max","number_processors":"proc 10:0:8:2","physical_memory":"32 GB",
      "serial_number":"TEST-SERIAL"}],
     "SPDisplaysDataType":[{"sppci_model":"Apple M1 Max","sppci_cores":"24"}]}
    """#.utf8)
    let info = try MacHardwareInfo.parse(data)
    #expect(info.modelIdentifier == "MacBookPro18,2")
    #expect(info.physicalCores == 10)
    #expect(info.performanceCores == 8)
    #expect(info.efficiencyCores == 2)
    #expect(info.graphics == ["Apple M1 Max (24 cores)"])
    #expect(info.memory == "32 GB")
    #expect(info.serialNumber == "TEST-SERIAL")
}

@Test func macInfoHandlesIntelMultipleGPUsAndMissingFields() throws {
    let data = Data(#"""
    {"SPHardwareDataType":[{"machine_name":"MacBook Pro","cpu_type":"Intel Core i7",
      "number_processors":"1 processor, 4 cores"}],
     "SPDisplaysDataType":[{"sppci_model":"Intel Iris Pro"},{"sppci_model":"AMD Radeon Pro"}]}
    """#.utf8)
    let info = try MacHardwareInfo.parse(data)
    #expect(info.processor == "Intel Core i7")
    #expect(info.performanceCores == nil)
    #expect(info.efficiencyCores == nil)
    #expect(info.serialNumber == nil)
    #expect(info.graphics == ["Intel Iris Pro", "AMD Radeon Pro"])
    let empty = try MacHardwareInfo.parse(Data("{}".utf8))
    #expect(empty.processorLines == ["Unavailable"])
    #expect(empty.memory == nil)
    #expect(empty.graphics.isEmpty)
}

@Test func macIdentityUsesTheSystemModelCatalog() {
    let identity = MacModelIdentity(modelIdentifier: "MacBookPro18,2")
    #expect(identity.contentType?.identifier == "com.apple.macbookpro-16-2021")
    #expect(identity.year == "2021")
    #expect(identity.size == "16")
    #expect(identity.title(family: "MacBook Pro", processor: "Apple M1 Max") == "MacBook Pro 16″ (M1 Max)")
    let unknown = MacModelIdentity(modelIdentifier: "UnknownFutureMac99,1")
    #expect(unknown.contentType == nil)
    #expect(unknown.year == nil)
    #expect(unknown.size == nil)
    #expect(unknown.title(family: "Mac", processor: nil) == "Mac")
}
