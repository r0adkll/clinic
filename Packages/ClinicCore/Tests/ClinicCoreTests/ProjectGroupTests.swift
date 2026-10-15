import Foundation
import Testing
@testable import ClinicCore

@Suite struct ProjectGroupTests {
    private let roster = ["/chats", "/clinic", "/campfire", "/nix", "/azulon", "/perfetto"]

    private func state() -> (ClinicState, apps: UUID, tools: UUID) {
        var s = ClinicState()
        let apps = s.addGroup(named: "Apps", with: ["/campfire", "/azulon"])
        let tools = s.addGroup(named: "Tools", with: ["/nix", "/perfetto"])
        return (s, apps, tools)
    }

    @Test func noGroupsLaysOutLikeToday() {
        let layout = ProjectLayout(paths: roster, groups: [], pinned: ["/chats"])
        #expect(layout.pinned == ["/chats"])
        #expect(layout.ungrouped == ["/clinic", "/campfire", "/nix", "/azulon", "/perfetto"])
        #expect(layout.groups.isEmpty)
        #expect(layout.allPaths == roster)
    }

    @Test func ungroupedComeBeforeGroupsAndMembersKeepRosterOrder() {
        let (s, _, _) = state()
        let layout = ProjectLayout(paths: roster, groups: s.projectGroups, pinned: ["/chats"])
        #expect(layout.ungrouped == ["/clinic"])
        #expect(layout.groups.map(\.group.name) == ["Apps", "Tools"])
        #expect(layout.groups[0].paths == ["/campfire", "/azulon"])
        #expect(layout.groups[1].paths == ["/nix", "/perfetto"])
    }

    @Test func scopeShowsChatsAndOneGroupOnly() {
        let (s, _, tools) = state()
        let layout = ProjectLayout(paths: roster, groups: s.projectGroups, pinned: ["/chats"], scope: tools)
        #expect(layout.allPaths == ["/chats", "/nix", "/perfetto"])
        #expect(layout.groups.count == 1)
    }

    @Test func aScopeWhoseGroupIsGoneShowsEverything() {
        let (s, _, _) = state()
        let layout = ProjectLayout(paths: roster, groups: s.projectGroups, pinned: ["/chats"], scope: UUID())
        #expect(layout.allPaths.count == roster.count)
    }

    @Test func aPinnedPathIsNeverGrouped() {
        var (s, apps, _) = state()
        s.move(project: "/chats", toGroup: apps)
        let layout = ProjectLayout(paths: roster, groups: s.projectGroups, pinned: ["/chats"])
        #expect(layout.pinned == ["/chats"])
        #expect(!layout.groups[0].paths.contains("/chats"))
    }

    @Test func membersNotInTheRosterAreSkippedButRemembered() {
        // An archived project is unregistered; it keeps its group and comes back into it.
        let (s, _, _) = state()
        let layout = ProjectLayout(paths: roster.filter { $0 != "/azulon" }, groups: s.projectGroups, pinned: ["/chats"])
        #expect(layout.groups[0].paths == ["/campfire"])
        #expect(s.group(of: "/azulon")?.name == "Apps")
    }

    @Test func anEmptyGroupIsStillListed() {
        var s = ClinicState()
        s.addGroup(named: "Later")
        let layout = ProjectLayout(paths: roster, groups: s.projectGroups, pinned: ["/chats"])
        #expect(layout.groups.map(\.paths) == [[]])
    }

    @Test func aProjectIsInAtMostOneGroup() {
        var (s, apps, tools) = state()
        s.move(project: "/nix", toGroup: apps)
        #expect(s.group(of: "/nix")?.id == apps)
        #expect(!(s.projectGroups.first { $0.id == tools }!.members.contains("/nix")))
        s.addGroup(named: "Dotfiles", with: ["/nix"])
        #expect(s.projectGroups.filter { $0.members.contains("/nix") }.map(\.name) == ["Dotfiles"])
    }

    @Test func movingToNilOrAMissingGroupUngroups() {
        var (s, _, _) = state()
        s.move(project: "/nix", toGroup: nil)
        #expect(s.group(of: "/nix") == nil)
        s.move(project: "/perfetto", toGroup: UUID())
        #expect(s.group(of: "/perfetto") == nil)
    }

    @Test func deletingAGroupUngroupsItsProjectsAndForgetsItsFold() {
        var (s, apps, _) = state()
        s.collapsedGroups.insert(apps)
        s.deleteGroup(apps)
        #expect(s.group(of: "/campfire") == nil)
        #expect(s.collapsedGroups.isEmpty)
        #expect(s.projectGroups.map(\.name) == ["Tools"])
    }

    @Test func renamingTrimsAndNeverLeavesANameEmpty() {
        var (s, apps, _) = state()
        s.renameGroup(apps, to: "  Mobile  ")
        #expect(s.projectGroups[0].name == "Mobile")
        s.renameGroup(apps, to: "   ")
        #expect(s.projectGroups[0].name == "Untitled Group")
    }

    @Test func groupsReorder() {
        var (s, apps, tools) = state()
        let misc = s.addGroup(named: "Misc")
        s.moveGroup(misc, before: apps)
        #expect(s.projectGroups.map(\.name) == ["Misc", "Apps", "Tools"])
        s.moveGroup(misc, by: 1)
        #expect(s.projectGroups.map(\.name) == ["Apps", "Misc", "Tools"])
        s.moveGroup(tools, by: 1)   // already last
        #expect(s.projectGroups.map(\.name) == ["Apps", "Misc", "Tools"])
    }

    @Test func groupsSurviveARoundTripAndOldFilesDecodeWithout() throws {
        let (s, apps, _) = state()
        var folded = s
        folded.collapsedGroups = [apps]
        let back = try JSONDecoder().decode(ClinicState.self, from: JSONEncoder().encode(folded))
        #expect(back.projectGroups == folded.projectGroups)
        #expect(back.collapsedGroups == [apps])
        let old = try JSONDecoder().decode(ClinicState.self, from: Data(#"{"version":1}"#.utf8))
        #expect(old.projectGroups.isEmpty)
    }
}
