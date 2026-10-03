# Dataset upload fixtures

Test data for `DatasetImports` readers and `ImportDatasetJob`. Coordinates are approximate;
this is test data, not a gazetteer.

| File | Exercises |
|---|---|
| `atlanta_landmarks.csv` | CSV with lat/lon, a category, a pick-list (Neighborhood), numbers, yes/no, a row without coordinates and a row in a projected system |
| `atlanta_landmarks.xlsx` | The same as an Excel workbook with typed cells (numbers, booleans, a date column) and a second sheet (ignored, with a warning). Written with openpyxl. |
| `atlanta_landmarks.ods` | The same as OpenDocument. Written with odfpy. |
| `semicolon_bom.csv` | Semicolon separator, byte-order mark, decimal commas |
| `wkt.csv` | A WKT geometry column, including an unreadable value |
| `piedmont.geojson` | GeoJSON with a polygon, a point and a line; a nested property |
| `broken.geojson` | Not JSON (refused) |
| `landmarks_points.zip` | Point shapefile (EPSG:4326, UTF-8 .cpg, an accented name, 10-character .dbf names). Written with GDAL's ogr2ogr. |
| `areas.zip` | Polygon shapefile: a polygon with a hole and a two-part multipolygon (GDAL) |
| `landmarks_stateplane.zip` | The points in Georgia West State Plane feet (refused: projected) |
| `dates_and_marks.csv` | Dates as historical data has them — a year, decade, circa, range (`built`, proposed as a partial date); NPS-style months `1983-03-` with an impossible `1980-02-30` (`listed`, flagged); full dates in two spellings plus `yesterday` (`surveyed`); a checkmark column (`landmark`: X / ✓ / blank → Yes/No); a number column with `n/a`; codes with leading zeros (`code`, unique, so proposed as the identifier) |
| `savannah_layers.kml` | Four layers as four folders (GDAL's KML driver, from GeoJSON via a GeoPackage): points with typed `SchemaData`/`SimpleData` (an `Address` value, an accented name, `&` `<` `>` in a value, an HTML description); a polygon, a polygon with a hole and a two-part `MultiGeometry`; a line and a two-part line; a point + polygon `MultiGeometry` (a collection); a placemark with no geometry |
| `savannah_layers.kmz` | The same as a KMZ from GDAL's LIBKML driver with `LIBKML_USE_SIMPLEFIELD=NO`: `doc.kml` holds only `NetworkLink`s to `layers/<layer>.kml` inside the zip; untyped `Data`/`value`; altitudes |
| `walking_tour_google_earth.kml` | Written by hand in Google Earth Pro's shape: nested folders (Walking tour → Day 1 / Day 2) and a placemark outside any folder, styles, `Data` with `displayName`, a CDATA HTML description (link, image), a plain two-line description, `<address>`, `TimeSpan` and `TimeStamp`, a `gx:Track` (undeclared-prefix tolerant), an open polygon ring, unreadable coordinates (`-81.09,north`), a `NetworkLink` to the web and a `GroundOverlay` (both reported, not imported) |
| `walking_tour_google_earth.kmz` | The same zipped as `doc.kml` |

Every KML/KMZ placemark's geometry was checked against GDAL's own reading of the same file
(`ogr2ogr -f GeoJSON`, GDAL 3.14): identical once GDAL's altitudes are dropped and its open
ring closed (the reader drops altitude and closes rings, as GeoJSON requires). GDAL reads the
`GroundOverlay` as a polygon placemark; the upload skips it with a warning.
