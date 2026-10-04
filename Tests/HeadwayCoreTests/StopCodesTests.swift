import Testing

@testable import HeadwayCore

struct StopCodesTests {
  @Test func findsCodesWrittenInDifferentWays() {
    #expect(StopCodes.find(in: "From Aug 4, Stop 7253 and Stop 7351 will be closed") == ["7253", "7351"])
    #expect(StopCodes.find(in: "Stop 7253 & Stop7351 closed") == ["7253", "7351"])
    #expect(StopCodes.find(in: "Brooks St Stop #0269 closed") == ["0269"])
    #expect(StopCodes.find(in: "Stops 1001, 1002 and 1003 are closed") == ["1001", "1002", "1003"])
  }

  @Test func ignoresDatesAndYears() {
    #expect(StopCodes.find(in: "Starting Monday, June 15, 2026 route S detours from Main St").isEmpty)
    #expect(StopCodes.find(in: "Stop 0269 Closed. Alternate stops on N Mills St, 2026").first == "0269")
  }

  @Test func repeatsAreDropped() {
    #expect(StopCodes.find(in: "Stop 0269 Closed Stop #0269") == ["0269"])
  }
}
