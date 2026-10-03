import useJobPolling from '../hooks/useJobPolling';
import { JobStatuses } from '../jobs';
import FeedbackLink from './FeedbackLink';
import { Message, Progress } from './ui';

/**
 * What a reindex means for the curator, in their terms. The search index is
 * shared by every atlas, so two failures come from outside this atlas.
 */
export const explain = (error) => {
  if (!error) {
    return 'The search index refused the update.';
  }

  if (/Limit of total fields/i.test(error)) {
    return 'The shared search index has no room left for new fields. An administrator needs to make room; the places are saved.';
  }

  const field = /failed to parse field \[([^\].]+)/i.exec(error)?.[1];

  if (field) {
    return `Another atlas already uses the field name “${field.replace(/_/g, ' ')}” for a different kind of value. Rename this atlas's field in the project's data, then reindex from Settings → General; the places are saved.`;
  }

  return `The search index refused the update (${error.slice(0, 160)}). The places are saved; reindex from Settings → General to try again.`;
};

/**
 * Follows the reindex an import queued: the places are saved when the import
 * finishes, but visitors see them only once the search index has them. A
 * failure here used to be visible only on the Jobs page, so the curator was
 * told "imported" and found an empty atlas.
 */
const ReindexStatus = ({ jobId }) => {
  const job = useJobPolling(jobId);

  if (!jobId) {
    return null;
  }

  if (!job || job.status === JobStatuses.initializing || job.status === JobStatuses.processing) {
    const progress = job?.extra?.progress;

    return (
      <>
        <Message>Updating the atlas…</Message>
        { progress?.total > 0 && <Progress total={progress.total} value={progress.completed} /> }
      </>
    );
  }

  if (job.status === JobStatuses.failed) {
    return (
      <Message
        action={<FeedbackLink error={explain(job.extra?.error)} jobId={jobId} />}
        header='The atlas couldn’t be updated'
        tone='negative'
      >
        { explain(job.extra?.error) }
      </Message>
    );
  }

  return <Message tone='positive'>The atlas is updated: the places are live.</Message>;
};

export default ReindexStatus;
