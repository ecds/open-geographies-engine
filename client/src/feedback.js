import { createContext, useContext } from 'react';

/**
 * "Send feedback": `open()` shows the feedback form, optionally with what the
 * curator was looking at when they got stuck — `{ error, job_id }` — so a
 * report from a failed import carries the message and the job. Provided by
 * App (FeedbackProvider); without a provider (signed out) it does nothing.
 */
const FeedbackContext = createContext({ open: () => {} });

export const useFeedback = () => useContext(FeedbackContext);

export default FeedbackContext;
