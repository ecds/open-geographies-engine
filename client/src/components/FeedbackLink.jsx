import { useFeedback } from '../feedback';

/**
 * "Tell us what went wrong" beside a failure: opens the feedback form with
 * the message (and the job, when there is one) already attached.
 */
const FeedbackLink = ({ error, jobId }) => {
  const { open } = useFeedback();

  return (
    <button
      className='link-button feedback-link'
      onClick={() => open({ error: Array.isArray(error) ? error.join(' ') : error, job_id: jobId })}
      type='button'
    >
      Tell us what went wrong
    </button>
  );
};

export default FeedbackLink;
