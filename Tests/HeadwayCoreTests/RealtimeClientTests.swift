import Foundation
import Testing

@testable import HeadwayCore

@Suite struct RealtimeClientTests {
  @Test func parsesHTTPDates() {
    let date = RealtimeClient.parseHTTPDate("Sun, 04 Oct 2026 01:07:21 GMT")
    #expect(date == Date(timeIntervalSince1970: 1_791_076_041))
    #expect(RealtimeClient.parseHTTPDate(nil) == nil)
    #expect(RealtimeClient.parseHTTPDate("yesterday") == nil)
  }
}
