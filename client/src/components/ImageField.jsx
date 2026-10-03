import { useContext, useRef, useState } from 'react';
import _ from 'underscore';
import { errorMessages } from '../api';
import ImageCropper, { CROPPABLE_TYPES, ImageCropContext } from './ImageCropper';
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
 * Width / height as a short ratio for people: 1.333 → "4:3".
 */
const ratioLabel = (width, height) => {
  const ratio = width / height;
  const known = [[1, '1:1'], [4 / 3, '4:3'], [3 / 2, '3:2'], [16 / 9, '16:9'], [1.91, '1.91:1'], [3, '3:1'], [3 / 4, '3:4'], [2 / 3, '2:3']];
  const match = _.find(known, ([value]) => Math.abs(ratio - value) / value < 0.02);
  return match ? match[1] : `${ratio.toFixed(2)}:1`;
};

/**
 * An image setting (logo, favicon, a section's image): a preview of the
 * current image with Change / Crop / Remove, and an optional alt text.
 * `background` previews the image on the color it will sit on (the logo on
 * the header). `crop` gives the shape the atlas shows it at, when it has one
 * ({ aspect, aspectLabel, minWidth, minHeight }); an uploaded JPEG, PNG,
 * WebP or AVIF can then be cropped to it.
 */
const ImageField = ({ alt, assets, background, crop = {}, hint, label, onAltChange, onChange, onUpload, value }) => {
  const [picking, setPicking] = useState(false);
  const [cropping, setCropping] = useState(null);
  const cropAsset = useContext(ImageCropContext);

  const current = _.findWhere(assets, { path: value });

  // An uploaded image previews from its small copy.
  const preview = current?.thumbnail_path || value;

  // Cropping an earlier crop starts again from its original, at the earlier
  // frame, when the original is still in the library.
  const croppable = (asset) => asset && CROPPABLE_TYPES.includes(asset.content_type) && asset.width && asset.height;
  const source = current?.cropped_from ? _.findWhere(assets, { key: current.cropped_from.from }) : null;
  const target = croppable(source) ? { asset: source, initial: current.cropped_from } : (croppable(current) ? { asset: current } : null);

  const mismatch = crop.aspect && croppable(current) &&
    Math.abs(current.width / current.height - crop.aspect) / crop.aspect > 0.03;

  return (
    <div className='field'>
      <span className='field-label'>{ label }</span>
      <div className='image-field'>
        <div className='image-preview' style={background ? { background } : undefined}>
          { value ? <img alt='' src={preview} /> : <span className='muted'>No image</span> }
        </div>
        <div className='image-actions'>
          <Button onClick={() => setPicking(!picking)}>{ value ? 'Change…' : 'Add image…' }</Button>
          { cropAsset && target && <Button onClick={() => setCropping(target)}>Crop…</Button> }
          { value && <Button onClick={() => onChange(undefined)} subtle>Remove</Button> }
        </div>
      </div>
      { mismatch && (
        <span className='field-hint'>
          This image is { ratioLabel(current.width, current.height) }; { crop.mismatch }, so its edges are cut off.
          { cropAsset ? ' Crop it to choose what shows.' : '' }
        </span>
      )}
      { cropping && (
        <ImageCropper
          asset={cropping.asset}
          crop={crop}
          initial={cropping.initial}
          label={label}
          onCancel={() => setCropping(null)}
          onCropped={(asset) => { onChange(asset.path); setCropping(null); }}
        />
      )}
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
