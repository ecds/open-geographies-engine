import { useEffect, useState } from 'react';
import { fetchJob } from '../api';
import { isTerminal } from '../jobs';

const DEFAULT_INTERVAL = 2000;

/**
 * Polls the passed job until it completes or fails, returning the latest job
 * record (including `extra`, which carries stage/progress reporting). Pass a
 * null/undefined ID to idle the hook.
 */
const useJobPolling = (jobId, interval = DEFAULT_INTERVAL) => {
  const [job, setJob] = useState(null);

  useEffect(() => {
    setJob(null);

    if (!jobId) {
      return undefined;
    }

    let active = true;
    let timer;

    const poll = () => {
      fetchJob(jobId)
        .then((data) => {
          if (!active) {
            return;
          }

          setJob(data.job);

          if (!isTerminal(data.job?.status)) {
            timer = setTimeout(poll, interval);
          }
        })
        .catch(() => {
          // Transient fetch errors (e.g. a server restart mid-poll) retry on
          // the next tick rather than wedging the progress display.
          if (active) {
            timer = setTimeout(poll, interval);
          }
        });
    };

    poll();

    return () => {
      active = false;
      clearTimeout(timer);
    };
  }, [jobId, interval]);

  return job;
};

export default useJobPolling;
