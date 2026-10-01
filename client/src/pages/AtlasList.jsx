import { useEffect, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchSites } from '../api';
import { liveUrl } from '../atlasLinks';
import { paths } from '../router';
import { Button, Message } from '../components/ui';

/**
 * The atlases the signed-in user can edit (the sites policy scope: their
 * projects, or everything for an admin).
 */
const AtlasList = ({ navigate }) => {
  const [sites, setSites] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    fetchSites()
      .then((data) => setSites(data.sites || []))
      .catch((error) => setErrors(errorMessages(error)));
  }, []);

  return (
    <main className='wizard'>
      <div className='page-head'>
        <h1>Atlases</h1>
        <Button onClick={() => navigate(paths.wizard())} primary>Create an atlas</Button>
      </div>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { sites && _.isEmpty(sites) && (
        <Message>No atlases yet. Create one: it stays private, with a preview link, until you publish it.</Message>
      )}
      { !_.isEmpty(sites) && (
        <table className='table'>
          <thead>
            <tr><th>Name</th><th>Status</th><th>Slug</th><th>Updated</th><th /></tr>
          </thead>
          <tbody>
            { _.map(sites, (site) => (
              <tr key={site.id}>
                <td>
                  <a href={paths.atlas(site.id)} onClick={(e) => { e.preventDefault(); navigate(paths.atlas(site.id)); }}>
                    <strong>{ site.name }</strong>
                  </a>
                </td>
                <td>
                  <span className={`status-pill ${site.published ? 'status-published' : 'status-draft'}`}>
                    { site.published ? 'Published' : 'Draft' }
                  </span>
                </td>
                <td><code>{ site.slug }</code></td>
                <td>{ new Date(site.updated_at).toLocaleDateString() }</td>
                <td className='table-actions'>
                  { site.published && liveUrl(site) && <a href={liveUrl(site)} rel='noreferrer' target='_blank'>View</a> }
                  <a href={paths.imports(site.id)} onClick={(e) => { e.preventDefault(); navigate(paths.imports(site.id)); }}>Imports</a>
                  <a href={paths.jobs(site.id)} onClick={(e) => { e.preventDefault(); navigate(paths.jobs(site.id)); }}>Jobs</a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </main>
  );
};

export default AtlasList;
