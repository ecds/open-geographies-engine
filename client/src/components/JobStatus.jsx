import { JOB_STATUS_LABELS, JobStatuses } from '../jobs';
import { Tag } from './ui';

const TONES = {
  [JobStatuses.initializing]: undefined,
  [JobStatuses.processing]: 'warning',
  [JobStatuses.completed]: 'positive',
  [JobStatuses.failed]: 'negative'
};

const JobStatus = ({ status }) => (
  <Tag tone={TONES[status]}>{ JOB_STATUS_LABELS[status] || status }</Tag>
);

export default JobStatus;
