import { useState } from 'react';
import { errorMessages, regeneratePreviewToken, updateSite } from '../api';
import { liveUrl, previewUrl } from '../atlasLinks';
import { Button, Message } from './ui';

/**
 * Draft or published. A draft is visible only through its preview link;
 * publishing makes it public at its address. Both take effect at once
 * (separately from Save), within the renderer's 30-second cache. Only the
 * atlas's owners publish, unpublish and replace the link; editors see the
 * state and the preview link.
 */
const PublishPanel = ({ onChange, site }) => {
  const canManage = site.permissions?.manage !== false;
  const [saving, setSaving] = useState(false);
  const [errors, setErrors] = useState([]);
  const [confirmUnpublish, setConfirmUnpublish] = useState(false);
  const [confirmReplace, setConfirmReplace] = useState(false);
  const [copied, setCopied] = useState(false);

  const live = liveUrl(site);
  const preview = previewUrl(site);

  const run = (promise, changes) => {
    setSaving(true);
    setErrors([]);

    return promise
      .then((data) => onChange(changes(data)))
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => {
        setSaving(false);
        setConfirmUnpublish(false);
        setConfirmReplace(false);
      });
  };

  const setPublished = (published) => run(updateSite(site.id, { published }), () => ({ published }));

  const onReplace = () => run(regeneratePreviewToken(site.id), (data) => ({ preview_token: data.preview_token }));

  const onCopy = () => {
    navigator.clipboard?.writeText(preview).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  };

  return (
    <section className='card publish-panel'>
      { errors.length > 0 && <Message list={errors} tone='negative' /> }
      { site.published ? (
        <>
          <p>
            <span className='status-pill status-published'>Published</span>
            { ' ' }Anyone can see this atlas{ live && <> at <a href={live} rel='noreferrer' target='_blank'>{ live }</a></> }.
          </p>
          { !canManage && <p className='muted'>Only the atlas’s owners can unpublish it.</p> }
          { canManage && !confirmUnpublish && <Button disabled={saving} onClick={() => setConfirmUnpublish(true)} subtle>Unpublish…</Button> }
          { confirmUnpublish && (
            <div className='row'>
              <span>Visitors will find no atlas at this address until you publish it again.</span>
              <Button loading={saving} onClick={() => setPublished(false)}>Unpublish</Button>
              <Button disabled={saving} onClick={() => setConfirmUnpublish(false)} subtle>Keep it published</Button>
            </div>
          )}
        </>
      ) : (
        <>
          <p>
            <span className='status-pill status-draft'>Draft</span>
            { ' ' }Only people with the preview link can see this atlas.{ canManage && ' Publish it when it’s ready.' }
          </p>
          { preview && (
            <div className='preview-link'>
              <input aria-label='Preview link' className='input' readOnly value={preview} onFocus={(e) => e.target.select()} />
              <Button onClick={onCopy}>{ copied ? 'Copied' : 'Copy' }</Button>
              <a className='button' href={preview} rel='noreferrer' target='_blank'>Open ↗</a>
            </div>
          )}
          { !canManage && <p className='muted'>Only the atlas’s owners can publish it or replace the preview link.</p> }
          { canManage && (
          <div className='row'>
            <Button loading={saving} onClick={() => setPublished(true)} primary>Publish atlas</Button>
            { !confirmReplace && <Button disabled={saving} onClick={() => setConfirmReplace(true)} subtle>Replace preview link…</Button> }
            { confirmReplace && (
              <>
                <span>The current link will stop working for everyone who has it.</span>
                <Button loading={saving} onClick={onReplace}>Replace it</Button>
                <Button disabled={saving} onClick={() => setConfirmReplace(false)} subtle>Cancel</Button>
              </>
            )}
          </div>
          )}
        </>
      )}
    </section>
  );
};

export default PublishPanel;
