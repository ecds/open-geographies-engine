import maplibregl from 'maplibre-gl';
import { useCallback, useEffect, useRef, useState } from 'react';
import config from '../config';

const GEOCODING = 'https://api.maptiler.com/geocoding';

/**
 * The atlas's extent widened on every side (at least half a degree), so a
 * search prefers results near the atlas over a namesake far away.
 */
const searchArea = (bbox) => {
  if (!bbox) {
    return null;
  }

  const [west, south, east, north] = bbox;
  const padX = Math.max((east - west) / 2, 0.5);
  const padY = Math.max((north - south) / 2, 0.5);

  return [Math.max(west - padX, -180), Math.max(south - padY, -90), Math.min(east + padX, 180), Math.min(north + padY, 90)]
    .map((n) => n.toFixed(5)).join(',');
};

/**
 * A map for putting one place on it: click where it is (or pick a search
 * result), then drag the marker to adjust. Framed to the atlas's located
 * places. The search box looks names up with MapTiler (islands,
 * landmarks, intersections the Census can't place), biased toward the
 * atlas; without a MapTiler key it's left out and clicking is the way.
 */
const PlacePicker = ({ bbox, height = 440, initialQuery, onChange, value }) => {
  const container = useRef(null);
  const mapRef = useRef(null);
  const markerRef = useRef(null);
  const onChangeRef = useRef(onChange);
  const bboxRef = useRef(bbox);
  const [query, setQuery] = useState(initialQuery || '');
  const [results, setResults] = useState(null);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState(null);
  const [farAway, setFarAway] = useState(false);

  onChangeRef.current = onChange;

  useEffect(() => {
    const style = config.mapTilerKey ? `${config.mapStyle}?key=${config.mapTilerKey}` : config.mapStyle;
    const map = new maplibregl.Map({ container: container.current, style, maxPitch: 0, center: [0, 20], zoom: 1 });

    map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
    map.getCanvas().style.cursor = 'crosshair';

    // Framed once, to the located places; the map then stays where the
    // curator moves it from place to place.
    if (bboxRef.current) {
      const [west, south, east, north] = bboxRef.current;
      map.fitBounds([[west, south], [east, north]], { padding: 40, maxZoom: 15, duration: 0 });
    }

    map.on('click', (event) => onChangeRef.current({ latitude: event.lngLat.lat, longitude: event.lngLat.lng }));
    mapRef.current = map;

    return () => {
      map.remove();
      mapRef.current = null;
      markerRef.current = null;
    };
  }, []);

  // The marker follows the chosen point; dragging it chooses a new one.
  useEffect(() => {
    const map = mapRef.current;

    if (!map) {
      return;
    }

    if (!value) {
      markerRef.current?.remove();
      markerRef.current = null;
      return;
    }

    if (!markerRef.current) {
      markerRef.current = new maplibregl.Marker({ color: '#c2410c', draggable: true })
        .setLngLat([value.longitude, value.latitude])
        .addTo(map);
      markerRef.current.on('dragend', () => {
        const { lat, lng } = markerRef.current.getLngLat();
        onChangeRef.current({ latitude: lat, longitude: lng });
      });
    } else {
      markerRef.current.setLngLat([value.longitude, value.latitude]);
    }
  }, [value]);

  useEffect(() => {
    setQuery(initialQuery || '');
    setResults(null);
    setSearchError(null);
  }, [initialQuery]);

  const onSearch = useCallback((event) => {
    event.preventDefault();

    const text = query.trim();
    const map = mapRef.current;

    if (!text || !config.mapTilerKey || !map) {
      return;
    }

    const center = map.getCenter();
    const area = searchArea(bboxRef.current);
    const search = (within) => fetch(`${GEOCODING}/${encodeURIComponent(text)}.json?key=${encodeURIComponent(config.mapTilerKey)}`
      + `&limit=6&proximity=${center.lng.toFixed(5)},${center.lat.toFixed(5)}${within ? `&bbox=${within}` : ''}`)
      .then((response) => (response.ok ? response.json() : Promise.reject(new Error(String(response.status)))))
      .then((data) => data.features || []);

    setSearching(true);
    setSearchError(null);
    setFarAway(false);

    // Near the atlas first; anywhere only when nothing is found there.
    search(area)
      .then((features) => {
        if (features.length > 0 || !area) {
          return features;
        }

        setFarAway(true);
        return search(null);
      })
      .then(setResults)
      .catch(() => setSearchError('The place search isn’t answering. Click the map where the place is instead.'))
      .finally(() => setSearching(false));
  }, [query]);

  const onPick = (feature) => {
    const [longitude, latitude] = feature.center || feature.geometry?.coordinates || [];

    if (longitude == null || latitude == null) {
      return;
    }

    mapRef.current?.flyTo({ center: [longitude, latitude], zoom: Math.max(mapRef.current.getZoom(), 16), duration: 600 });
    onChange({ latitude, longitude });
    setResults(null);
  };

  return (
    <div className='place-picker'>
      { config.mapTilerKey && (
        <form className='place-search' onSubmit={onSearch} role='search'>
          <input
            aria-label='Search for the place'
            className='input'
            onChange={(e) => setQuery(e.target.value)}
            placeholder='Search for a place, address or landmark'
            value={query}
          />
          <button className='button' disabled={searching || !query.trim()} type='submit'>{ searching ? 'Searching…' : 'Search' }</button>
        </form>
      )}
      { searchError && <p className='muted'>{ searchError }</p> }
      { results && (
        results.length === 0
          ? <p className='muted'>Nothing found. Try fewer words, or click the map where the place is.</p>
          : (
            <>
            { farAway && <p className='muted'>Nothing near the atlas; these are elsewhere.</p> }
            <ul className='place-results'>
              { results.map((feature) => (
                <li key={feature.id || feature.place_name}>
                  <button onClick={() => onPick(feature)} type='button'>{ feature.place_name || feature.text }</button>
                </li>
              ))}
            </ul>
            </>
          )
      )}
      <div className='preview-map' ref={container} style={{ height }} />
      <p className='muted'>Click the map where the place is; drag the marker to adjust.</p>
    </div>
  );
};

export default PlacePicker;
