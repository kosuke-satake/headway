import Foundation

/// A map style with no tiles at all: a plain background. Routes, stops and buses are added on top at run time.
/// This is the stand-in until the offline basemap (PMTiles) is wired in.
enum BaseStyle {
  static let url: URL = {
    let json = """
      {
        "version": 8,
        "name": "Headway plain",
        "sources": {},
        "layers": [
          { "id": "background", "type": "background", "paint": { "background-color": "#EEEBE4" } }
        ]
      }
      """
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("headway-plain-style.json")
    try? Data(json.utf8).write(to: file)
    return file
  }()
}
