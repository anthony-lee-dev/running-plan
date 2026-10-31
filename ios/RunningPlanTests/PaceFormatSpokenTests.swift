import Testing
@testable import RunningPlan

struct PaceFormatSpokenTests {
    @Test(arguments: [
        ("5 km · 6:25–7:10/km", "5 km · 6 minutes 25 to 7 minutes 10 per kilometre"),
        ("fast reps at 5:15–5:30/km", "fast reps at 5 minutes 15 to 5 minutes 30 per kilometre"),
        ("ran 5.1 km at 6:30/km", "ran 5.1 km at 6 minutes 30 per kilometre"),
        ("easy at 7:00/km", "easy at 7 minutes per kilometre"),
        ("45 min · easy effort", "45 min · easy effort"),
    ])
    func pacesAreReadAsWords(text: String, spoken: String) {
        #expect(PaceFormat.spoken(text) == spoken)
    }
}
