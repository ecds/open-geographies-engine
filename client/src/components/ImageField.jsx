import { useRef, useState } from 'react';
import _ from 'underscore';
import { errorMessages } from '../api';
import { Button, Field, Message } from './ui';

const ACCEPT = 'image/png,image/jpeg,image/gif,image/webp,image/avif,image/svg+xml,image/x-icon,.ico,image/tiff,.tif,.tiff';

/**
 * The atlas's uploaded images as a grid to pick from, plus an https://
 * address for an image hosted elsewhere. Used by ImageField and by the
 * Markdown field's "Image" button.
 */
export const AssetPicker = ({ assets, onCancel, onPick, onUpload }) => {
  const [address, setAddress] = useState('');
  const [uploading, setUploading] = useState(false);
  const [errors, setErrors] = useState([]);
  const input = useRef();

  const onFile = (e) => {
    const file = e.target.files?.[0];
    e.target.value = '';

    if (!file) {
      return;
    }

    setUploading(true);
    setErrors([]);

    onUpload(file)
      .then((asset) => onPick(asset.path, asset))
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setUploading(false));
  };

  return (
    <div className='asset-picker'>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      <div className='row'>
        <Button loading={uploading} onClick={() => input.current?.click()}>Upload an image…</Button>
        <input accept={ACCEPT} hidden onChange={onFile} ref={input} type='file' />
        <span className='muted'>PNG, JPEG, GIF, WebP, AVIF, SVG or ICO, up to 10 MB; TIFF up to 100 MB (stored as a JPEG). Large photos are fine: visitors get a copy sized for their screen.</span>
      </div>
      { !_.isEmpty(assets) && (
        <>
          <p className='muted'>Or choose one you've uploaded:</p>
          <div className='asset-grid'>
            { _.map(assets, (asset) => (
              <button
                className='asset-tile'
                key={asset.key}
                onClick={() => onPick(asset.path, asset)}
                title={asset.width ? `${asset.filename} (${asset.width} × ${asset.height})` : asset.filename}
                type='button'
              >
                <img alt='' loading='lazy' src={asset.thumbnail_path || asset.path} />
                <span>{ asset.filename }</span>
              </button>
            ))}
          </div>
        </>
      )}
      <form
        className='addition'
        onSubmit={(e) => {
          e.preventDefault();
          if (/^https:\/\//i.test(address.trim())) {
            onPick(address.trim());
          }
        }}
      >
        <input className='input' onChange={(e) => setAddress(e.target.value)} placeholder='Or an image address: https://…' value={address} />
        <Button disabled={!/^https:\/\//i.test(address.trim())} subtle type='submit'>Use address</Button>
      </form>
      <div className='actions'>
        <Button onClick={onCancel} subtle>Cancel</Button>
      </div>
    </div>
  );
};

/**
 * An image setting (logo, favicon, a section's image): a preview of the
 * current image with Change / Remove, and an optional alt text. `background`
 * previews the image on the color it will sit on (the logo on the header).
 */
const ImageField = ({ alt, assets, background, hint, label, onAltChange, onChange, onUpload, value }) => {
  const [picking, setPicking] = useState(false);

  // An uploaded image previews from its small copy.
  const preview = _.findWhere(assets, { path: value })?.thumbnail_path || value;

  return (
    <div className='field'>
      <span className='field-label'>{ label }</span>
      <div className='image-field'>
        <div className='image-preview' style={background ? { background } : undefined}>
          { value ? <img alt='' src={preview} /> : <span className='muted'>No image</span> }
        </div>
        <div className='image-actions'>
          <Button onClick={() => setPicking(!picking)}>{ value ? 'Change…' : 'Add image…' }</Button>
          { value && <Button onClick={() => onChange(undefined)} subtle>Remove</Button> }
        </div>
      </div>
      { picking && (
        <AssetPicker
          assets={assets}
          onCancel={() => setPicking(false)}
          onPick={(path) => { onChange(path); setPicking(false); }}
          onUpload={onUpload}
        />
      )}
      { onAltChange && value && (
        <input
          aria-label={`${label}: description for screen readers`}
          className='input image-alt'
          onChange={(e) => onAltChange(e.target.value)}
          placeholder='Describe the image for screen readers (leave empty if decorative)'
          value={alt || ''}
        />
      )}
      { hint && <span className='field-hint'>{ hint }</span> }
    </div>
  );
};

export default ImageField;
