import { MapDraw } from '@performant-software/geospatial';
import config from '../config';

/**
 * The draw/preview map, configured from the injected runtime config.
 */
const AreaMap = ({ children, data, onChange }) => (
  <MapDraw
    apiKey={config.mapTilerKey}
    data={data}
    mapStyle={config.mapStyle}
    maxPitch={0}
    navigation
    onChange={onChange || (() => {})}
    style={{ height: 420, width: '100%' }}
  >
    { children }
  </MapDraw>
);

export default AreaMap;
