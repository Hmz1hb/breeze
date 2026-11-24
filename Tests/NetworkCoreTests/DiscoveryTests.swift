import NetworkCore
import Testing

@Test func discoveryNamesAppleTVsAndPrivateAddressDevices() {
    var tv = LocalDevice(ip: "192.168.1.30", name: "Living Room", evidence: "Bonjour advertisement")
    tv.services = ["_companion-link._tcp"]; tv.model = "AppleTV11,1"
    #expect(tv.category == "Apple TV")
    var phone = LocalDevice(ip: "192.168.1.31", name: "HmzLhb-13PRO", evidence: "Bonjour advertisement")
    phone.services = ["_remotepairing._tcp"]
    #expect(phone.category == "Apple mobile device")
    #expect(LocalDevice(ip: "192.168.1.32", mac: "06:55:3a:34:37:ef").category == "Private Wi-Fi device")
    #expect(LocalDevice(ip: "192.168.1.33", mac: "1c:b3:c9:11:30:c7").category == "Unidentified device")
}
