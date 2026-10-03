import { useState } from 'react';
import DatasetImportPanel from './DatasetImportPanel';
import PlaceImportPanel from './PlaceImportPanel';
import { onTabListKeyDown } from './ui';

const TABS = [
  { key: 'upload', label: 'Upload your data' },
  { key: 'gazetteer', label: 'From a gazetteer' }
];

/**
 * The two ways places get into an atlas: the curator's own dataset, or a
 * gazetteer (GeoNames, Wikidata) queried for the atlas's area. Shared by the
 * wizard's seed step and the atlas's Imports page.
 */
const PlaceSources = ({ area, onImported, projectId }) => {
  const [tab, setTab] = useState('upload');

  return (
    <>
      <div aria-label='Where the places come from' className='tabs' onKeyDown={onTabListKeyDown} role='tablist'>
        { TABS.map(({ key, label }) => (
          <button
            aria-selected={tab === key}
            className='tab'
            key={key}
            onClick={() => setTab(key)}
            role='tab'
            tabIndex={tab === key ? 0 : -1}
            type='button'
          >
            { label }
          </button>
        ))}
      </div>
      { tab === 'upload' && <DatasetImportPanel onImported={onImported} projectId={projectId} /> }
      { tab === 'gazetteer' && <PlaceImportPanel area={area} onImported={onImported} projectId={projectId} /> }
    </>
  );
};

export default PlaceSources;
