import { useEffect, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchJobs, fetchSite } from '../api';
import JobStatus from '../components/JobStatus';
import { Message } from '../components/ui';
import { isTerminal } from '../jobs';
import AtlasHeader from '../components/AtlasHeader';

const JOB_LABELS = {
  provision_atlas: 'Provision atlas',
  import_places: 'Import places',
  reindex: 'Reindex search',
  build_tiles: 'Build map tiles'
};

const POLL_MS = 4000;

/**
 * The project's jobs, newest first, polled while any is still running.
 */
const AtlasJobs = ({ id, navigate }) => {
  const [site, setSite] = useState(null);
  const [jobs, setJobs] = useState(null);
  const [errors, setErrors] = useState([]);

  useEffect(() => {
    fetchSite(id).then((data) => setSite(data.site)).catch((error) => setErrors(errorMessages(error)));
  }, [id]);

  useEffect(() => {
    if (!site) {
      return undefined;
    }

    let active = true;
    let timer;

    const load = () => fetchJobs(site.project_id)
      .then((data) => {
        if (!active) return;
        setJobs(data.jobs || []);
        if (_.some(data.jobs, (job) => !isTerminal(job.status))) {
          timer = setTimeout(load, POLL_MS);
        }
      })
      .catch((error) => active && setErrors(errorMessages(error)));

    load();

    return () => { active = false; clearTimeout(timer); };
  }, [site]);

  const summary = (job) => {
    const extra = job.extra || {};

    if (extra.counts) {
      return `${extra.counts.imported} imported, ${extra.counts.skipped} skipped`;
    }

    if (extra.progress) {
      return `${extra.progress.completed} / ${extra.progress.total}`;
    }

    if (extra.error) {
      return extra.error;
    }

    return extra.stage || '';
  };

  return (
    <main className='wizard'>
      <AtlasHeader active='jobs' navigate={navigate} site={site} />
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { jobs && _.isEmpty(jobs) && <Message>No jobs yet.</Message> }
      { !_.isEmpty(jobs) && (
        <table className='table'>
          <thead>
            <tr><th>Job</th><th>Status</th><th>Details</th><th>Started</th></tr>
          </thead>
          <tbody>
            { _.map(jobs, (job) => (
              <tr key={job.id}>
                <td>{ JOB_LABELS[job.job_type] || job.job_type }</td>
                <td><JobStatus status={job.status} /></td>
                <td className='muted'>{ summary(job) }</td>
                <td>{ new Date(job.created_at).toLocaleString() }</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </main>
  );
};

export default AtlasJobs;
