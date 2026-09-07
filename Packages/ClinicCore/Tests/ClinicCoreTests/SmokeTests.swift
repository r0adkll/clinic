import Testing
@testable import ClinicCore

@Test func versionIsSet() {
    #expect(ClinicCore.version.hasPrefix("0.1"))
}
