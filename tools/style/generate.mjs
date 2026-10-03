// Writes App/Resources/basemap-style.json: a MapLibre style over the Protomaps tile schema.
// Placeholders __PMTILES__ and __GLYPHS__ are replaced by the app at run time with local file URLs.
import { layers, namedFlavor } from "@protomaps/basemaps";
import { writeFileSync } from "node:fs";

// Light uses the quiet "white" flavor so that route colours stand out; dark uses Protomaps "dark".
const flavors = { light: "white", dark: "dark" };
for (const [name, flavorName] of Object.entries(flavors)) {
  const style = {
    version: 8,
    name: `Headway basemap (${name})`,
    glyphs: "__GLYPHS__/{fontstack}/{range}.pbf",
    sources: {
      protomaps: {
        type: "vector",
        url: "pmtiles://__PMTILES__",
        attribution: "© OpenStreetMap contributors",
      },
    },
    // Points of interest (shops, museums, ...) are left out: the map is for finding buses, and they clutter it.
    layers: layers("protomaps", namedFlavor(flavorName), { lang: "en" }).filter((l) => l["source-layer"] !== "pois"),
  };
  const out = new URL(`../../App/Resources/basemap-${name}.json`, import.meta.url);
  writeFileSync(out, JSON.stringify(style));
  console.log(`wrote ${out.pathname}: ${style.layers.length} layers`);
}
