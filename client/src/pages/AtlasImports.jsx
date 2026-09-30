import { useEffect, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchSite } from '../api';
import AtlasHeader from '../components/AtlasHeader';
import PlaceSources from '../components/PlaceSources';
import { Message } from '../components/ui';

/**
 * Add places to an existing atlas: upload a dataset, or re-run the
 * gazetteer imports pre-filled with the atlas's area. The wizard's seed
 * step, standalone.
 */
const AtlasImports = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    fetchSite(id).then((data) => setSite(data.site)).catch((error) => setErrors(errorMessages(error)));
  }, [id]);

  return (
    <main className='wizard'>
      <AtlasHeader active='imports' navigate={navigate} site={site} />
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { site && (
        <section className='panel'>
          <Message>
            Imports are safe to re-run. Gazetteer places already imported are skipped; so are rows of an
            uploaded file whose identifier column matches a place already imported.
          </Message>
          <PlaceSources
            area={site.area || {}}
            key={site.id}
            projectId={site.project_id}
          />
        </section>
      )}
    </main>
  );
};

export default AtlasImports;
