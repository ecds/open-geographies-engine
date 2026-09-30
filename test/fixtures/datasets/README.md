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
