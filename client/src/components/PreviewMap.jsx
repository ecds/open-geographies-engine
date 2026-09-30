import maplibregl from 'maplibre-gl';
import { useEffect, useRef } from 'react';
import config from '../config';

const SOURCE = 'preview';
const COLOR = '#0a3a4d';

// Legacy `$type` filters match Multi* geometries too.
const LAYERS = [
  { id: 'preview-fill', type: 'fill', filter: ['==', '$type', 'Polygon'], paint: { 'fill-color': COLOR, 'fill-opacity': 0.2 } },
  { id: 'preview-line', type: 'line', filter: ['!=', '$type', 'Point'], paint: { 'line-color': COLOR, 'line-width': 2 } },
  {
    id: 'preview-point',
    type: 'circle',
    filter: ['==', '$type', 'Point'],
    paint: { 'circle-radius': 5, 'circle-color': COLOR, 'circle-stroke-color': '#fff', 'circle-stroke-width': 1 }
  }
];

/**
 * A read-only map of a GeoJSON FeatureCollection, framed to its bounding box.
 * For previews, where the drawing map (MapDraw) would add its frame as an
 * editable shape. Clicking a feature shows its `name`.
 */
const PreviewMap = ({ bbox, data, height = 420 }) => {
  const container = useRef(null);
  const mapRef = useRef(null);

  useEffect(() => {
    const style = config.mapTilerKey ? `${config.mapStyle}?key=${config.mapTilerKey}` : config.mapStyle;

    const map = new maplibregl.Map({
      container: container.current,
      style,
      cooperativeGestures: true,
      maxPitch: 0
    });

    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');

    const showName = (event) => {
      const name = event.features?.[0]?.properties?.name;

      if (name) {
        new maplibregl.Popup({ closeButton: false }).setLngLat(event.lngLat).setText(name).addTo(map);
      }
    };

    LAYERS.forEach(({ id }) => {
      map.on('click', id, showName);
      map.on('mouseenter', id, () => { map.getCanvas().style.cursor = 'pointer'; });
      map.on('mouseleave', id, () => { map.getCanvas().style.cursor = ''; });
    });

    mapRef.current = map;

    return () => {
      map.remove();
      mapRef.current = null;
    };
  }, []);

  useEffect(() => {
    const map = mapRef.current;

    if (!map || !data) {
      return;
    }

    const render = () => {
      const source = map.getSource(SOURCE);

      if (source) {
        source.setData(data);
      } else {
        map.addSource(SOURCE, { type: 'geojson', data });
        LAYERS.forEach((layer) => map.addLayer({ ...layer, source: SOURCE }));
      }

      if (bbox) {
        const [west, south, east, north] = bbox;

        if (west === east && south === north) {
          map.jumpTo({ center: [west, south], zoom: 14 });
        } else {
          map.fitBounds([[west, south], [east, north]], { padding: 40, maxZoom: 15, duration: 0 });
        }
      }
    };

    if (map.isStyleLoaded()) {
      render();
    } else {
      map.once('load', render);
    }
  }, [bbox, data]);

  return <div className='preview-map' ref={container} style={{ height }} />;
};

export default PreviewMap;
