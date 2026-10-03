import { useEffect, useMemo, useRef, useState } from 'react';
import _ from 'underscore';
import { errorMessages, sendFeedback } from '../api';
import { Button, Field, Message } from './ui';

const SCREENSHOT_TYPES = ['image/png', 'image/jpeg', 'image/webp'];
const MAX_SCREENSHOT_BYTES = 10 * 1024 * 1024;
const MAX_TEXT = 5000;

/**
 * What the form sends without asking: the page, the browser and window, and
 * what the curator was looking at when they opened it from a failure.
 */
const gatherContext = (prefill) => _.pick({
  source: prefill?.error ? 'failure' : 'header',
  path: `${window.location.pathname}${window.location.search}`,
  error: prefill?.error,
  job_id: prefill?.job_id,
  user_agent: navigator.userAgent,
  viewport: `${window.innerWidth}×${window.innerHeight}`,
  screen: `${window.screen.width}×${window.screen.height}`,
  language: navigator.language
}, (value) => value !== undefined && value !== null && value !== '');

/**
 * The "Send feedback" form, as a modal dialog: what happened, what they
 * expected, an optional screenshot (chosen, or pasted with ⌘V / Ctrl+V), and
 * a plain list of what's sent along with it. Sent to the platform's admins
 * (and by email when the platform has an address for it).
 */
const FeedbackDialog = ({ onClose, prefill, site }) => {
  const dialog = useRef();
  const fileInput = useRef();
  const [whatHappened, setWhatHappened] = useState('');
  const [expected, setExpected] = useState('');
  const [screenshot, setScreenshot] = useState(null);
  const [screenshotUrl, setScreenshotUrl] = useState(null);
  const [errors, setErrors] = useState([]);
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState(false);

  const context = useMemo(() => gatherContext(prefill), [prefill]);

  useEffect(() => {
    const element = dialog.current;
    element?.showModal();
    return () => element?.open && element.close();
  }, []);

  useEffect(() => {
    if (!screenshot) {
      setScreenshotUrl(null);
      return undefined;
    }

    const url = URL.createObjectURL(screenshot);
    setScreenshotUrl(url);
    return () => URL.revokeObjectURL(url);
  }, [screenshot]);

  const takeScreenshot = (file) => {
    if (!file) return;

    if (!SCREENSHOT_TYPES.includes(file.type)) {
      setErrors(['The screenshot must be a PNG, JPEG or WebP image.']);
    } else if (file.size > MAX_SCREENSHOT_BYTES) {
      setErrors(['The screenshot can be at most 10 MB.']);
    } else {
      setErrors([]);
      setScreenshot(file);
    }
  };

  // A pasted image (a screenshot copied to the clipboard) becomes the
  // screenshot; pasted text goes where it was pasted.
  const onPaste = (e) => {
    const item = _.find(e.clipboardData?.items || [], (i) => i.kind === 'file' && i.type.startsWith('image/'));

    if (item) {
      e.preventDefault();
      const file = item.getAsFile();
      takeScreenshot(file && new File([file], `screenshot.${file.type.split('/')[1] || 'png'}`, { type: file.type }));
    }
  };

  const onSubmit = (e) => {
    e.preventDefault();
    setSending(true);
    setErrors([]);

    sendFeedback({
      what_happened: whatHappened,
      expected,
      page_url: context.path,
      site_id: site?.id,
      context,
      screenshot
    })
      .then(() => setSent(true))
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSending(false));
  };

  const sentAlong = _.compact([
    `this page (${context.path})`,
    site?.name && `the atlas “${site.name}”`,
    context.error && 'the message shown',
    context.job_id && `the job (#${context.job_id})`,
    'your browser and window size',
    'your name and email, so we can reply'
  ]);

  return (
    <dialog
      aria-labelledby='feedback-title'
      className='feedback-dialog'
      onCancel={(e) => { e.preventDefault(); onClose(); }}
      onPaste={onPaste}
      ref={dialog}
    >
      { sent ? (
        <div className='feedback-body'>
          <h2 id='feedback-title'>Thank you</h2>
          <p>Your feedback was sent. If we need to know more, we’ll write to you.</p>
          <div className='actions'>
            <Button autoFocus onClick={onClose} primary>Close</Button>
          </div>
        </div>
      ) : (
        <form className='feedback-body' onSubmit={onSubmit}>
          <h2 id='feedback-title'>Send feedback</h2>
          { context.error && (
            <Message header='About this message' tone='negative'>{ context.error }</Message>
          )}
          <Field label='What happened?' required>
            <textarea
              autoFocus
              className='input'
              maxLength={MAX_TEXT}
              onChange={(e) => setWhatHappened(e.target.value)}
              rows={4}
              value={whatHappened}
            />
          </Field>
          <Field label='What did you expect to happen?'>
            <textarea
              className='input'
              maxLength={MAX_TEXT}
              onChange={(e) => setExpected(e.target.value)}
              rows={3}
              value={expected}
            />
          </Field>
          <div className='field'>
            <span className='field-label'>Screenshot (optional)</span>
            { screenshotUrl ? (
              <div className='feedback-shot'>
                <img alt='The screenshot to send' src={screenshotUrl} />
                <Button onClick={() => setScreenshot(null)} subtle>Remove</Button>
              </div>
            ) : (
              <>
                <div>
                  <Button onClick={() => fileInput.current?.click()}>Add a screenshot…</Button>
                </div>
                <span className='field-hint'>Or paste one here (⌘V / Ctrl+V). PNG, JPEG or WebP, up to 10 MB.</span>
              </>
            )}
            <input
              accept={SCREENSHOT_TYPES.join(',')}
              aria-label='Screenshot file'
              hidden
              onChange={(e) => { takeScreenshot(e.target.files?.[0]); e.target.value = ''; }}
              ref={fileInput}
              type='file'
            />
          </div>
          { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
          <p className='muted feedback-sent-along'>Sent along with it: { sentAlong.join(', ') }.</p>
          <div className='actions'>
            <Button onClick={onClose} subtle>Cancel</Button>
            <Button disabled={!whatHappened.trim()} loading={sending} primary type='submit'>Send</Button>
          </div>
        </form>
      )}
    </dialog>
  );
};

export default FeedbackDialog;
