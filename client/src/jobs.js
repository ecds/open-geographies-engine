export const JobStatuses = {
  initializing: 'initializing',
  processing: 'processing',
  completed: 'completed',
  failed: 'failed'
};

export const JOB_STATUS_LABELS = {
  initializing: 'Queued',
  processing: 'Running',
  completed: 'Completed',
  failed: 'Failed'
};

export const isTerminal = (status) => status === JobStatuses.completed || status === JobStatuses.failed;
