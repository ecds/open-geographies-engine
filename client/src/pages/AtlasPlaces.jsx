import { useEffect, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchSite } from '../api';
import AtlasHeader from '../components/AtlasHeader';
import UnlocatedPlaces from '../components/UnlocatedPlaces';
import { Message } from '../components/ui';

const TABS = [
  { key: 'unlocated', label: 'Without a location' }
];

/**
 * Work on the atlas's places after they're in: put the ones without a
 * location on the map.
 */
const AtlasPlaces = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  const [errors, setErrors] = useState([]);
  const [tab, setTab] = useState('unlocated');

  useEffect(() => {
    fetchSite(id).then((data) => setSite(data.site)).catch((error) => setErrors(errorMessages(error)));
  }, [id]);

  return (
    <main className='wizard'>
      <AtlasHeader active='places' navigate={navigate} site={site} />
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { site && (
        <section className='panel'>
          { TABS.length > 1 && (
            <div className='tabs' role='tablist'>
              { _.map(TABS, (t) => (
                <button aria-selected={tab === t.key} className='tab' key={t.key} onClick={() => setTab(t.key)} role='tab' type='button'>
                  { t.label }
                </button>
              ))}
            </div>
          )}
          { tab === 'unlocated' && <UnlocatedPlaces site={site} /> }
        </section>
      )}
    </main>
  );
};

export default AtlasPlaces;
