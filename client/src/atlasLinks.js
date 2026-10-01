import config from './config';

/**
 * An atlas's public address on the shared renderer (from the host's
 * OG_ATLAS_URL_TEMPLATE), or null when none is configured.
 */
export const liveUrl = (site) => (
  site?.slug && config.atlasUrlTemplate ? config.atlasUrlTemplate.replace('{slug}', site.slug) : null
);

/**
 * A draft's shareable preview link: the renderer keeps the token in a
 * cookie and drops it from the address (see the renderer's middleware).
 */
export const previewUrl = (site) => {
  const url = liveUrl(site);
  return url && site?.preview_token ? `${url.replace(/\/+$/, '')}/?preview=${site.preview_token}` : null;
};
