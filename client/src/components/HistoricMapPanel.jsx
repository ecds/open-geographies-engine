import { lazy, Suspense, useState } from 'react';
import { findGeoreference } from '../allmaps';
import { Button, Field, Message } from './ui';

const PreviewMap = lazy(() => import('./PreviewMap'));

const DEFAULT_OPACITY = 0.8;

/**
 * Adds a historic map to the atlas: a scanned map, georeferenced in Allmaps,
 * drawn over the atlas's map as a layer visitors can switch on and off.
 * The curator pastes an Allmaps link or the scan's IIIF address; a scan that
 * isn't georeferenced yet gets a button into the Allmaps Editor. The layer
 * is added to the edited settings (saved with Save).
 */
const HistoricMapPanel = ({ onAdd }) => {
  const [text, setText] = useState('');
  const [looking, setLooking] = useState(false);
  const [result, setResult] = useState(null);
  const [name, setName] = useState('');
  const [shown, setShown] = useState(true);
  const [opacity, setOpacity] = useState(DEFAULT_OPACITY);

  const onFind = (event) => {
    event.preventDefault();
    setLooking(true);
    setResult(null);

    findGeoreference(text)
      .then((found) => {
        setResult(found);
        setName(found.title || '');
      })
      .finally(() => setLooking(false));
  };

  const onAddLayer = () => {
    // A year in the map's name ("Atlanta, 1878") dates the layer; the curator
    // can change it in the layer list.
    const year = name.match(/\b(1[5-9]\d\d|20\d\d)\b/);

    onAdd({
      name: name.trim() || 'Historic map',
      layer_type: 'georeference',
      url: result.url,
      overlay: true,
      default: shown,
      opacity,
      ...(year ? { start_year: Number(year[1]) } : {})
    });
    setText('');
    setResult(null);
  };

  const outline = result?.status === 'found' && {
    type: 'FeatureCollection',
    features: [{
      type: 'Feature',
      properties: { name: name || 'Historic map' },
      geometry: {
        type: 'Polygon',
        coordinates: [[
          [result.bbox[0], result.bbox[1]], [result.bbox[2], result.bbox[1]],
          [result.bbox[2], result.bbox[3]], [result.bbox[0], result.bbox[3]],
          [result.bbox[0], result.bbox[1]]
        ]]
      }
    }]
  };

  return (
    <section className='card historic-map-panel'>
      <h4>Add a historic map</h4>
      <p className='muted'>
        Lay a scanned historical map over the atlas’s map. The scan has to be georeferenced in
        {' '}<a href='https://allmaps.org' rel='noreferrer' target='_blank'>Allmaps</a> (free: you match a few points on the
        scan to the same places on today’s map). Paste its Allmaps link, or the IIIF address of the scan — a library’s
        “IIIF manifest” link — to find out.
      </p>
      <form className='preview-link' onSubmit={onFind}>
        <input
          aria-label='Allmaps link or IIIF address'
          className='input'
          onChange={(e) => setText(e.target.value)}
          placeholder='https://annotations.allmaps.org/maps/… or https://…/manifest.json'
          spellCheck={false}
          value={text}
        />
        <Button disabled={!text.trim()} loading={looking} type='submit'>Find</Button>
      </form>

      { result?.status === 'invalid' && (
        <Message tone='warning'>That isn’t an Allmaps link or a IIIF address of a scanned map.</Message>
      )}
      { result?.status === 'not_georeferenced' && (
        <Message tone='warning'>
          <p>This scan hasn’t been georeferenced in Allmaps yet. Open it in the Allmaps Editor, match a few points to
            today’s map, then paste the Allmaps link here.</p>
          <a className='button' href={result.editorUrl} rel='noreferrer' target='_blank'>Open in the Allmaps Editor ↗</a>
        </Message>
      )}
      { result?.status === 'unavailable' && (
        <Message tone='warning'>
          <p>Allmaps couldn’t look this address up. If the map is already georeferenced, paste its Allmaps link
            instead; if not, open the scan in the Allmaps Editor.</p>
          <a className='button' href={result.editorUrl} rel='noreferrer' target='_blank'>Open in the Allmaps Editor ↗</a>
        </Message>
      )}

      { result?.status === 'found' && (
        <div className='historic-map-found'>
          <div className='historic-map-summary'>
            { result.thumbnail && <img alt='' src={result.thumbnail} /> }
            <div>
              <strong>{ result.title || 'Georeferenced map' }</strong>
              <p className='muted'>
                { result.maps === 1 ? 'One map' : `${result.maps} maps` } · outlined below
              </p>
            </div>
          </div>
          <Suspense fallback={<div className='muted'>Loading the map…</div>}>
            <PreviewMap bbox={result.bbox} data={outline} height={260} />
          </Suspense>
          <div className='grid-2'>
            <Field label='Name in the map’s layer menu'>
              <input className='input' onChange={(e) => setName(e.target.value)} value={name} />
            </Field>
            <Field label={`Opacity: ${Math.round(opacity * 100)}%`}>
              <input max='1' min='0.2' onChange={(e) => setOpacity(Number(e.target.value))} step='0.05' type='range' value={opacity} />
            </Field>
          </div>
          <div className='row'>
            <label className='check'>
              <input checked={shown} onChange={(e) => setShown(e.target.checked)} type='checkbox' />
              Shown when the map opens
            </label>
            <Button onClick={onAddLayer} primary>Add to the atlas</Button>
            <Button onClick={() => setResult(null)} subtle>Cancel</Button>
          </div>
        </div>
      )}
    </section>
  );
};

export default HistoricMapPanel;
