import Foundation
import Testing

@testable import HeadwayCore

@Suite struct CSVTests {
  private func rows(_ text: String) -> (header: [String: Int], rows: [[String]]) {
    let file = CSVFile(data: Data(text.utf8))
    var result: [[String]] = []
    file.forEachRow { row in
      result.append((0..<file.header.count).map { row.string($0) })
    }
    return (file.header, result)
  }

  @Test func parsesHeaderAndRows() {
    let parsed = rows("a,b,c\n1,2,3\n4,5,6\n")
    #expect(parsed.header == ["a": 0, "b": 1, "c": 2])
    #expect(parsed.rows == [["1", "2", "3"], ["4", "5", "6"]])
  }

  @Test func handlesCRLFAndMissingFinalNewline() {
    let parsed = rows("a,b\r\n1,2\r\n3,4")
    #expect(parsed.rows == [["1", "2"], ["3", "4"]])
  }

  @Test func handlesQuotedFieldsWithCommasAndEscapedQuotes() {
    let parsed = rows("name,note\n\"Park, N\",\"say \"\"hi\"\"\"\n")
    #expect(parsed.rows == [["Park, N", "say \"hi\""]])
  }

  @Test func keepsEmptyFieldsAndSkipsBlankLines() {
    let parsed = rows("a,b,c\n1,,3\n\n,,\n")
    #expect(parsed.rows == [["1", "", "3"], ["", "", ""]])
  }

  @Test func skipsByteOrderMark() {
    let file = CSVFile(data: Data([0xEF, 0xBB, 0xBF] + Array("id,name\n1,x\n".utf8)))
    #expect(file.header["id"] == 0)
  }

  @Test func parsesNumbers() {
    let file = CSVFile(data: Data("n,x,s\n-12,43.5,abc\n".utf8))
    file.forEachRow { row in
      #expect(row.int(file.header["n"]) == -12)
      #expect(row.double(file.header["x"]) == 43.5)
      #expect(row.int(file.header["s"]) == nil)
      #expect(row.int(99) == nil)
    }
  }

  @Test func parsesGTFSTimesPastMidnight() {
    #expect(parseGTFSTime("15:49:00") == 15 * 3600 + 49 * 60)
    #expect(parseGTFSTime("5:03:09") == 5 * 3600 + 3 * 60 + 9)
    #expect(parseGTFSTime("25:10:00") == 25 * 3600 + 10 * 60)
    #expect(parseGTFSTime("") == nil)
    #expect(parseGTFSTime("12:30") == nil)
  }
}
