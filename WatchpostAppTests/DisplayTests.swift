import Foundation
import Testing
@testable import WatchpostApp

struct DisplayTests {
    private func bundle(for language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// English spaces the two words around the dot; Chinese does not.
    @Test
    func cityAndStreetAreJoinedAsEachLanguageWritesThem() throws {
        #expect(Display.place(city: "Sample City", street: "Sample Car Park A", bundle: try bundle(for: "en"))
                == "Sample City · Sample Car Park A")
        #expect(Display.place(city: "Sample City", street: "Sample Car Park A", bundle: try bundle(for: "zh-Hans"))
                == "Sample City·Sample Car Park A")
    }

    @Test
    func oneMissingPartShowsTheOtherAndNoneShowsTheDash() throws {
        let english = try bundle(for: "en")
        #expect(Display.place(city: "Sample City", street: nil, bundle: english) == "Sample City")
        #expect(Display.place(city: nil, street: "Sample Car Park A", bundle: english) == "Sample Car Park A")
        #expect(Display.place(city: nil, street: nil, bundle: english) == Display.missing)
    }

    /// The demo's real recording is named by what it is, its cameras and its length, in words: never by
    /// the moment the demo gives it, which is only where it sits in the list.
    @Test(arguments: ["en", "zh-Hans"])
    func theRealRecordingIsNamedByItsCamerasAndItsLength(language: String) throws {
        let table = try bundle(for: language)
        let length = Display.sampleLength(20, bundle: table)
        let summary = Display.sampleSummary(20, bundle: table)
        #expect(length.contains("20"))
        #expect(summary.contains(length))
        if language == "en" {
            #expect(length == "20 seconds")
            #expect(summary == "Six camera views · 20 seconds")
        }
    }
}
