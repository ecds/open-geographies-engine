import { useCallback, useEffect, useState } from 'react';
import _ from 'underscore';
import {
  errorMessages,
  fetchFeedbackReports,
  fetchFeedbackScreenshot,
  updateFeedbackReport
} from '../api';
import { paths } from '../router';
import { isAdmin } from '../session';
import { Button, Message, onTabListKeyDown } from '../components/ui';

const FILTERS = [
  { value: 'new', label: 'New' },
  { value: 'resolved', label: 'Resolved' },
  { value: '', label: 'All' }
];

const EMAIL_STATUS = {
  sent: 'Emailed',
  failed: 'Email failed',
  pending: 'Email pending',
  off: 'Not emailed (no address set)'
};

const CONTEXT_LABELS = {
  error: 'Message shown',
  job_id: 'Job',
  viewport: 'Window',
  screen: 'Screen',
  language: 'Language',
  user_agent: 'Browser'
};

/**
 * True when a report's page is a path on this console's own site ("//host"
 * and "/\host" start with a slash too, and browsers read them as another
 * site). The server keeps only such paths; older reports may not be.
 */
const isConsolePath = (url) => {
  if (!/^\/(?![/\\])/.test(url)) return false;

  try {
    return new URL(url, window.location.origin).origin === window.location.origin;
  } catch (error) {
    return false;
  }
};

/**
 * The details sent with a report, as [label, value] rows: the page (a link
 * within the console), then what the form gathered, then a failed email's
 * error.
 */
const contextRows = (report) => _.compact([
  report.page_url && ['Page', isConsolePath(report.page_url) ? <a href={report.page_url}>{ report.page_url }</a> : report.page_url],
  ..._.map(CONTEXT_LABELS, (label, key) => report.context?.[key] && [label, report.context[key]]),
  report.email_status === 'failed' && report.email_error && ['Email error', report.email_error]
]);

/**
 * A report's screenshot: loaded with the session (the image route needs the
 * Authorization header), shown small, opened full size in a new tab.
 */
const Screenshot = ({ id }) => {
  const [url, setUrl] = useState(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let objectUrl = null;
    let active = true;

    fetchFeedbackScreenshot(id)
      .then((value) => {
        // Arrived after the list moved on: nothing will show it.
        if (!active) {
          URL.revokeObjectURL(value);
          return;
        }

        objectUrl = value;
        setUrl(value);
      })
      .catch(() => active && setFailed(true));

    return () => { active = false; if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [id]);

  if (failed) return <span className='muted'>The screenshot couldn’t be loaded.</span>;
  if (!url) return <span className='muted'>Loading the screenshot…</span>;

  return (
    <a className='feedback-thumb' href={url} rel='noreferrer' target='_blank' title='Open the screenshot full size'>
      <img alt='Screenshot sent with the report' src={url} />
    </a>
  );
};

/**
 * What curators sent with "Send feedback", newest first, for the platform's
 * administrators: what happened and what they expected, who and which atlas,
 * the page, the message and job when it came from a failure, the screenshot,
 * whether the email went out. Mark each resolved once it's dealt with.
 */
const FeedbackList = ({ navigate }) => {
  const [status, setStatus] = useState('new');
  const [page, setPage] = useState(1);
  const [data, setData] = useState(null);
  const [errors, setErrors] = useState([]);
  const [saving, setSaving] = useState(null);

  const load = useCallback(() => {
    fetchFeedbackReports({ status, page })
      .then(setData)
      .catch((error) => setErrors(errorMessages(error)));
  }, [page, status]);

  useEffect(load, [load]);

  const setReportStatus = (report, value) => {
    setSaving(report.id);
    updateFeedbackReport(report.id, value)
      .then(load)
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSaving(null));
  };

  if (!isAdmin()) {
    return (
      <main className='wizard'>
        <h1>Feedback</h1>
        <p>Feedback from curators is read by the platform’s administrators. To send some, use <strong>Send feedback</strong> at the top of the page.</p>
      </main>
    );
  }

  const reports = data?.feedback_reports || [];
  const pages = data ? Math.max(1, Math.ceil(data.total / data.per_page)) : 1;

  return (
    <main className='wizard'>
      <h1>Feedback</h1>
      <div aria-label='Show' className='tabs' onKeyDown={onTabListKeyDown} role='tablist'>
        { _.map(FILTERS, (filter) => (
          <button
            aria-selected={status === filter.value}
            className='tab'
            key={filter.label}
            onClick={() => { setStatus(filter.value); setPage(1); }}
            role='tab'
            tabIndex={status === filter.value ? 0 : -1}
            type='button'
          >
            { filter.label }
            { filter.value && data?.counts?.[filter.value] > 0 && ` (${data.counts[filter.value]})` }
          </button>
        ))}
      </div>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { data && _.isEmpty(reports) && <Message>{ status === 'new' ? 'Nothing new.' : 'No feedback here.' }</Message> }
      { _.map(reports, (report) => (
        <article className='card feedback-report' key={report.id}>
          <header className='feedback-report-head'>
            <div>
              <strong>{ report.user ? report.user.name || report.user.email : 'A deleted account' }</strong>
              { report.user?.email && <> · <a href={`mailto:${report.user.email}`}>{ report.user.email }</a></> }
              <div className='muted'>
                { new Date(report.created_at).toLocaleString() }
                { report.site && (
                  <>
                    { ' · ' }
                    <a href={paths.atlas(report.site.id)} onClick={(e) => { e.preventDefault(); navigate(paths.atlas(report.site.id)); }}>
                      { report.site.name }
                    </a>
                  </>
                )}
                { ' · ' }
                <span title={report.email_error || undefined}>{ EMAIL_STATUS[report.email_status] }</span>
              </div>
            </div>
            <Button
              loading={saving === report.id}
              onClick={() => setReportStatus(report, report.status === 'new' ? 'resolved' : 'new')}
              subtle={report.status === 'resolved'}
            >
              { report.status === 'new' ? 'Mark resolved' : 'Reopen' }
            </Button>
          </header>
          <h2 className='h-sub'>What happened</h2>
          <p className='feedback-text'>{ report.what_happened }</p>
          { report.expected && (
            <>
              <h2 className='h-sub'>What they expected</h2>
              <p className='feedback-text'>{ report.expected }</p>
            </>
          )}
          { report.screenshot && <Screenshot id={report.id} /> }
          <dl className='feedback-context'>
            { _.map(contextRows(report), ([label, value]) => (
              <div className='feedback-context-row' key={label}>
                <dt>{ label }</dt>
                <dd>{ value }</dd>
              </div>
            ))}
          </dl>
        </article>
      ))}
      { pages > 1 && (
        <div className='actions'>
          <Button disabled={page <= 1} onClick={() => setPage(page - 1)} subtle>← Newer</Button>
          <span className='muted'>Page { page } of { pages }</span>
          <Button disabled={page >= pages} onClick={() => setPage(page + 1)} subtle>Older →</Button>
        </div>
      )}
    </main>
  );
};

export default FeedbackList;
