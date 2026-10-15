import Testing
@testable import ClinicCore

@Suite struct ProjectQuickActionTests {
    @Test func nothingStoredMeansTheDefaults() {
        #expect(ProjectQuickAction.parse(nil) == [.newSession, .group, .gitPull])
    }

    @Test func anEmptyChoiceMeansNone() {
        #expect(ProjectQuickAction.parse("").isEmpty)
    }

    @Test func storedNamesComeBackInDeclarationOrderWithoutUnknownsOrRepeats() {
        #expect(ProjectQuickAction.parse("gitPull,bogus,newSession,gitPull") == [.newSession, .gitPull])
    }

    @Test func theChoiceIsCapped() {
        let all = ProjectQuickAction.allCases.map(\.rawValue).joined(separator: ",")
        #expect(ProjectQuickAction.parse(all).count == ProjectQuickAction.maxChosen)
        #expect(ProjectQuickAction.serialize(ProjectQuickAction.allCases).split(separator: ",").count == ProjectQuickAction.maxChosen)
    }

    @Test func aChoiceRoundTrips() {
        let chosen: [ProjectQuickAction] = [.showInFinder, .run, .newSession]
        #expect(ProjectQuickAction.parse(ProjectQuickAction.serialize(chosen)) == [.newSession, .run, .showInFinder])
    }

    @Test func chatsOnlyGetsActionsThatNeedNoRepository() {
        #expect(ProjectQuickAction.newSession.appliesToChats)
        #expect(!ProjectQuickAction.gitPull.appliesToChats)
        #expect(!ProjectQuickAction.group.appliesToChats)
    }
}
