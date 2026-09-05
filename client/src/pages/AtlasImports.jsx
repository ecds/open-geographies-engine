import { useEffect, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchSite } from '../api';
import AtlasHeader from '../components/AtlasHeader';
import PlaceImportPanel from '../components/PlaceImportPanel';
import { Message } from '../components/ui';

/**
 * Re-run authority imports for an existing atlas: the wizard's seed step,
 * standalone, pre-filled with the atlas's area. Imports are idempotent.
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
            Imports are safe to re-run: places already imported from the same authority are skipped,
            so you can widen the area, add a source, or change the filters at any time.
          </Message>
          <PlaceImportPanel
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
