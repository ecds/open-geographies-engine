import { useState } from 'react';
import { deleteSite, errorMessages } from '../api';
import { Button, Message } from './ui';

/**
 * Deleting the atlas (owners): its website, pages, branding, images,
 * settings and address go; its places and other records stay in its
 * FairData project. Confirmed by typing the atlas's name.
 */
const DeleteAtlasPanel = ({ onDeleted, site }) => {
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState('');
  const [deleting, setDeleting] = useState(false);
  const [errors, setErrors] = useState([]);

  const matches = typed.trim() === (site.name || '').trim();

  const onDelete = () => {
    setDeleting(true);
    setErrors([]);

    deleteSite(site.id)
      .then(onDeleted)
      .catch((error) => {
        setErrors(errorMessages(error));
        setDeleting(false);
      });
  };

  return (
    <section className='card delete-atlas'>
      { !open && (
        <div className='row'>
          <span className='muted'>Delete the atlas’s website. Its records stay in FairData.</span>
          <Button onClick={() => setOpen(true)} subtle>Delete this atlas…</Button>
        </div>
      )}
      { open && (
        <>
          { errors.length > 0 && <Message list={errors} tone='negative' /> }
          <p>
            This deletes <strong>{ site.name }</strong>: its website, home page and pages, branding, images,
            settings and address{ site.domain ? <> (including { site.domain })</> : null }. Visitors will find no atlas there.
          </p>
          <p>
            Its places and other records stay in the FairData project
            { site.project_name ? <> “{ site.project_name }”</> : null }. This can’t be undone.
          </p>
          <label className='field-label' htmlFor='delete-atlas-name'>Type the atlas’s name to confirm</label>
          <div className='preview-link'>
            <input autoComplete='off' className='input' id='delete-atlas-name' onChange={(e) => setTyped(e.target.value)} placeholder={site.name} value={typed} />
            <Button className='button-danger' disabled={!matches} loading={deleting} onClick={onDelete}>Delete the atlas</Button>
            <Button disabled={deleting} onClick={() => { setOpen(false); setTyped(''); }} subtle>Cancel</Button>
          </div>
        </>
      )}
    </section>
  );
};

export default DeleteAtlasPanel;
