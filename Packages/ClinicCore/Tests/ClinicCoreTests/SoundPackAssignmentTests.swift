import Foundation
import Testing
@testable import ClinicCore

private let a = SessionID("a"), b = SessionID("b"), c = SessionID("c"), d = SessionID("d")
private let installed: Set<String> = ["peon", "glados", "kerrigan", "zug"]
/// c is b's child, b is a's child; d stands alone. a and d live in /clinic, b and c in /ditto.
private let parents: [SessionID: SessionID] = [c: b, b: a]
private let projects: [SessionID: String] = [a: "/clinic", b: "/ditto", c: "/ditto", d: "/clinic"]

private func resolve(_ s: SessionID?, _ assignments: SoundPackAssignments, rotation: [String] = [], defaultPack: String? = "peon",
                     installed: Set<String> = installed) -> SoundPackAssignments.Resolution {
    assignments.resolve(s, project: s.flatMap { projects[$0] }, parent: { parents[$0] }, projectOf: { projects[$0] },
                        rotation: rotation, defaultPack: defaultPack, installed: installed)
}

private func pack(_ r: SoundPackAssignments.Resolution) -> String? {
    if case .choice(let c) = r { return c.pack }
    return nil
}

@Test func theSessionThenTheProjectThenTheDefault() {
    var x = SoundPackAssignments()
    #expect(resolve(d, x) == .choice(.init(pack: "peon", source: .defaultPack)))
    x.byProject["/clinic"] = "glados"
    #expect(resolve(d, x) == .choice(.init(pack: "glados", source: .project("/clinic"))))
    x.bySession[d] = "zug"
    #expect(resolve(d, x) == .choice(.init(pack: "zug", source: .session)))
    // A pack that has been uninstalled falls through.
    #expect(pack(resolve(d, x, installed: ["peon", "glados"])) == "glados")
    #expect(resolve(nil, SoundPackAssignments()) == .choice(.init(pack: "peon", source: .defaultPack)))
    #expect(resolve(d, SoundPackAssignments(), defaultPack: nil) == .none)
}

@Test func aChildSpeaksWithItsFamilyNotItsProject() {
    var x = SoundPackAssignments()
    x.byProject["/clinic"] = "glados"
    x.byProject["/ditto"] = "zug"
    // c's own project says zug, but its root, a, lives in /clinic.
    #expect(resolve(c, x) == .choice(.init(pack: "glados", source: .parent(a))))
    // The nearest ancestor with a choice of its own wins.
    x.bySession[b] = "kerrigan"
    #expect(resolve(c, x) == .choice(.init(pack: "kerrigan", source: .parent(b))))
    // Its own choice beats both.
    x.bySession[c] = "peon"
    #expect(resolve(c, x) == .choice(.init(pack: "peon", source: .session)))
}

@Test func theRotationIsDrawnOnceAndKept() {
    var x = SoundPackAssignments()
    let rotation = ["glados", "kerrigan"]
    #expect(resolve(d, x, rotation: rotation) == .draw(for: d))
    x.drawn[d] = "kerrigan"
    #expect(resolve(d, x, rotation: rotation) == .choice(.init(pack: "kerrigan", source: .rotation)))
    // A draw that has left the rotation is drawn again.
    #expect(resolve(d, x, rotation: ["glados"]) == .draw(for: d))
    // A project's own pack outranks the rotation.
    x.byProject["/clinic"] = "zug"
    #expect(pack(resolve(d, x, rotation: rotation)) == "zug")
    // A child draws nothing of its own: its root does.
    x.byProject = [:]
    #expect(resolve(c, x, rotation: rotation) == .draw(for: a))
}

@Test func drawsSpreadAcrossWhatIsAlreadyPlaying() {
    var random = SystemRandomNumberGenerator()
    let rotation = ["glados", "kerrigan", "zug"]
    for _ in 0..<20 {
        let pick = SoundPackAssignments.draw(rotation: rotation, installed: installed, inUse: ["glados", "zug", "glados"], using: &random)
        #expect(pick == "kerrigan")
    }
    let either = SoundPackAssignments.draw(rotation: rotation, installed: installed, inUse: ["zug"], using: &random)
    #expect(either == "glados" || either == "kerrigan")
    #expect(SoundPackAssignments.draw(rotation: ["gone"], installed: installed, inUse: []) == nil)
}

@Test func oldStateAndDrawsStayTidy() throws {
    var state = try JSONDecoder().decode(ClinicState.self, from: Data(#"{"version":1}"#.utf8))
    #expect(state.soundPacks == SoundPackAssignments())
    state.soundPacks.byProject["/clinic"] = "peon"
    let round = try JSONDecoder().decode(ClinicState.self, from: JSONEncoder().encode(state))
    #expect(round.soundPacks.byProject == ["/clinic": "peon"])

    var x = SoundPackAssignments()
    for i in 0..<401 { x.drawn[SessionID("s\(i)")] = "peon" }
    x.pruneDraws(keeping: [SessionID("s1")])
    #expect(x.drawn.keys.map(\.rawValue) == ["s1"])
}

@Test func anAutomationCarriesItsVoice() throws {
    var automation = Automation(name: "Nightly", prompt: "Check", target: .project(path: "/clinic"),
                                schedule: try CronSchedule("0 9 * * *"))
    // Saved before automations had a voice: it decodes as Automatic.
    var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(automation)) as? [String: Any])
    json["soundPack"] = nil
    let old = try JSONDecoder().decode(Automation.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.soundPack == nil)
    automation.soundPack = "glados"
    let round = try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(automation))
    #expect(round.soundPack == "glados")
    #expect(SoundWitness.automationFinished.category == .taskComplete)
    #expect(SoundWitness.automationFailed.category == .taskError)
    #expect(!SoundWitness.automationFinished.isHook && !SoundWitness.automationFinished.isOptIn)
}
