// Writes App/Resources/basemap-style.json: a MapLibre style over the Protomaps tile schema.
// Placeholders __PMTILES__ and __GLYPHS__ are replaced by the app at run time with local file URLs.
import { layers, namedFlavor } from "@protomaps/basemaps";
import { writeFileSync } from "node:fs";

const flavor = namedFlavor("white");
const style = {
  version: 8,
  name: "Headway basemap",
  glyphs: "__GLYPHS__/{fontstack}/{range}.pbf",
  sources: {
    protomaps: {
      type: "vector",
      url: "pmtiles://__PMTILES__",
      attribution: "© OpenStreetMap contributors",
    },
  },
  layers: layers("protomaps", flavor, { lang: "en" }),
};
const out = new URL("../../App/Resources/basemap-style.json", import.meta.url);
writeFileSync(out, JSON.stringify(style));
console.log(`wrote ${out.pathname}: ${style.layers.length} layers`);
const kinds = new Set(style.layers.map((l) => l["source-layer"]).filter(Boolean));
console.log("source layers:", [...kinds].join(", "));
