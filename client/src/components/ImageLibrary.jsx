import { useMemo, useRef, useState } from 'react';
import _ from 'underscore';
import { deleteSiteAsset, errorMessages } from '../api';
import { Button, Message } from './ui';

const ACCEPT = 'image/png,image/jpeg,image/gif,image/webp,image/avif,image/svg+xml,image/x-icon,.ico,image/tiff,.tif,.tiff';

/**
 * Where an uploaded image is used in a site document: the settings and pages
 * whose values mention its address (/core_data/public/v1/assets/<key>/…),
 * Markdown text included.
 */
export const assetUsage = (site, key) => {
  const needle = `/assets/${key}/`;
  const has = (value) => value != null && JSON.stringify(value).includes(needle);

  const branding = site?.branding || {};
  const places = [];

  if (has(branding.logo) || has(branding.header?.logo)) places.push('Logo');
  if (has(branding.favicon)) places.push('Favicon');
  if (has(branding.share_image)) places.push('Link preview image');
  if (has(branding.footer)) places.push('Footer');
  if (has(site?.content?.home)) places.push('Home page');
  _.each(site?.content?.pages || [], (page) => {
    if (has(page)) places.push(`Page “${page.title || page.slug}”`);
  });

  const known = _.pick(branding, 'logo', 'favicon', 'share_image', 'header', 'footer');
  if (has(site?.config) || has(site?.navigation) || has(_.omit(branding, _.keys(known)))) places.push('Other settings');

  return places;
};

const formatSize = (bytes) => {
  if (!bytes) return '';
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
};

const listPlaces = (places) => (places.length > 1 ? `${places.slice(0, -1).join(', ')} and ${_.last(places)}` : places[0]);

/**
 * The atlas's uploaded images: where each is used, and deleting the ones it
 * no longer needs (with their web-sized copies). Usage covers both the saved
 * atlas and unsaved edits, so an image that's about to be used — or still
 * shown on the live atlas — isn't counted as unused.
 */
const ImageLibrary = ({ assets, onChange, onUpload, savedSite, site }) => {
  const [confirming, setConfirming] = useState(null);
  const [deleting, setDeleting] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [errors, setErrors] = useState([]);
  const input = useRef();

  const usage = useMemo(() => _.object(_.map(assets, (asset) => [
    asset.key,
    _.union(assetUsage(savedSite, asset.key), assetUsage(site, asset.key))
  ])), [assets, savedSite, site]);

  const unused = _.filter(assets, (asset) => _.isEmpty(usage[asset.key]));
  const unusedBytes = _.reduce(unused, (sum, asset) => sum + (asset.byte_size || 0), 0);

  const remove = (keys) => {
    setDeleting(true);
    setErrors([]);

    const deleted = [];

    return keys.reduce((chain, key) => chain.then(() => deleteSiteAsset(site.id, key).then(() => deleted.push(key))), Promise.resolve())
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => {
        onChange(_.reject(assets, (asset) => _.contains(deleted, asset.key)));
        setDeleting(false);
        setConfirming(null);
      });
  };

  const onFile = (e) => {
    const files = Array.from(e.target.files || []);
    e.target.value = '';

    if (_.isEmpty(files)) {
      return;
    }

    setUploading(true);
    setErrors([]);

    files.reduce((chain, file) => chain.then(() => onUpload(file)), Promise.resolve())
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setUploading(false));
  };

  return (
    <div className='image-library'>
      <p className='muted'>
        Images uploaded for this atlas: its logo, banners and page images. Deleting one removes it and its web-sized copies;
        anything still showing it shows no image.
      </p>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }

      <div className='row library-actions'>
        <Button loading={uploading} onClick={() => input.current?.click()}>Upload images…</Button>
        <input accept={ACCEPT} hidden multiple onChange={onFile} ref={input} type='file' />
        <span className='muted'>
          { assets.length === 1 ? '1 image' : `${assets.length} images` }
          { assets.length > 0 && ` · ${unused.length} not used` }
        </span>
        { unused.length > 0 && confirming !== 'unused' && (
          <Button disabled={deleting} onClick={() => setConfirming('unused')} subtle>Delete the unused ones…</Button>
        )}
      </div>

      { confirming === 'unused' && (
        <Message tone='warning'>
          <div className='row'>
            <span>
              Delete { unused.length === 1 ? 'the 1 image' : `the ${unused.length} images` } this atlas doesn’t use ({ formatSize(unusedBytes) })?
              This can’t be undone.
            </span>
            <Button loading={deleting} onClick={() => remove(_.pluck(unused, 'key'))}>Delete them</Button>
            <Button disabled={deleting} onClick={() => setConfirming(null)} subtle>Cancel</Button>
          </div>
        </Message>
      )}

      { _.isEmpty(assets) && <p className='muted'>No images uploaded yet.</p> }

      <ul className='library-list'>
        { _.map(assets, (asset) => {
          const places = usage[asset.key];
          const used = !_.isEmpty(places);

          return (
            <li key={asset.key}>
              <img alt='' loading='lazy' src={asset.thumbnail_path || asset.path} />
              <div className='library-info'>
                <strong title={asset.filename}>{ asset.filename }</strong>
                <span className='muted'>
                  { [asset.width && `${asset.width} × ${asset.height}`, formatSize(asset.byte_size), asset.created_at && new Date(asset.created_at).toLocaleDateString()].filter(Boolean).join(' · ') }
                </span>
                { used ? <span>Used in { listPlaces(places) }</span> : <span className='status-pill status-draft'>Not used</span> }
              </div>
              <div className='library-delete'>
                { confirming !== asset.key && (
                  <Button disabled={deleting} onClick={() => setConfirming(asset.key)} subtle>Delete…</Button>
                )}
                { confirming === asset.key && (
                  <>
                    <span>{ used ? `${listPlaces(places)} will show no image.` : 'Delete this image?' }</span>
                    <Button loading={deleting} onClick={() => remove([asset.key])}>Delete</Button>
                    <Button disabled={deleting} onClick={() => setConfirming(null)} subtle>Cancel</Button>
                  </>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    </div>
  );
};

export default ImageLibrary;
