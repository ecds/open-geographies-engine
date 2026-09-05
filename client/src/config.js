/**
 * Runtime configuration injected by the engine's wizard page (see
 * WizardController). `mapStyle` defaults to MapTiler's dataviz style, which
 * needs `mapTilerKey`; without a key the map falls back to MapLibre's demo
 * tiles so the area picker still works in a bare local setup.
 */
const injected = (typeof window !== 'undefined' && window.OG_WIZARD_CONFIG) || {};

const MAPTILER_STYLE = 'https://api.maptiler.com/maps/dataviz/style.json';
const FALLBACK_STYLE = 'https://demotiles.maplibre.org/style.json';

const config = {
  apiBaseUrl: injected.apiBaseUrl || '',
  consoleUrl: injected.consoleUrl || '',
  mapTilerKey: injected.mapTilerKey || '',
  mapStyle: injected.mapStyle || (injected.mapTilerKey ? MAPTILER_STYLE : FALLBACK_STYLE),
  atlasUrlTemplate: injected.atlasUrlTemplate || null
};

export default config;
