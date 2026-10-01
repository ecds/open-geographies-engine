import _ from 'underscore';
import useJobPolling from '../hooks/useJobPolling';
import { JobStatuses } from '../jobs';
import ReindexStatus from './ReindexStatus';
import { Message, Progress } from './ui';

/**
 * Follows the photo copying an import queued (CopyPhotosJob): each photo
 * link is downloaded and saved on the atlas's IIIF image server as the
 * place's featured media. Slow on purpose (one request a second to each
 * source), so it reports as it goes and lists what it couldn't copy.
 */
const CopyPhotosStatus = ({ jobId }) => {
  const job = useJobPolling(jobId);

  if (!jobId) {
    return null;
  }

  const counts = job?.extra?.counts || {};
  const progress = job?.extra?.progress;

  if (!job || job.status === JobStatuses.initializing || job.status === JobStatuses.processing) {
    return (
      <>
        <Message>
          Copying the photos to the image server, about one a second
          { counts.copied > 0 && ` (${counts.copied} so far)` }…
        </Message>
        { progress?.total > 0 && <Progress total={progress.total} value={progress.completed} /> }
      </>
    );
  }

  if (job.status === JobStatuses.failed) {
    return (
      <Message header='The photos couldn’t be copied' tone='negative'>
        { job.extra?.error }
        { counts.copied > 0 && ` ${counts.copied} were copied before it stopped; importing the file again copies the rest.` }
      </Message>
    );
  }

  const failures = job.extra?.failures || [];
  const summary = _.compact([
    counts.copied > 0 && `${counts.copied} copied to ${job.extra?.server || 'the image server'}`,
    counts.already_copied > 0 && `${counts.already_copied} already there`,
    counts.failed > 0 && `${counts.failed} couldn’t be copied`
  ]).join('; ');

  return (
    <>
      <Message tone={counts.failed > 0 ? 'warning' : 'positive'}>
        Photos: { summary || 'nothing to copy' }.
        { counts.failed > 0 && ' Those places still show the photo from its source; importing the file again tries them again.' }
      </Message>
      { !_.isEmpty(failures) && (
        <Message
          header='Photos not copied'
          list={_.map(failures, (f) => `${f.place || 'A place'}: ${f.reason}`)}
          tone='warning'
        />
      )}
      { job.extra?.reindex_job_id && <ReindexStatus jobId={job.extra.reindex_job_id} /> }
    </>
  );
};

export default CopyPhotosStatus;
