import config from './config';

/**
 * An atlas's public address: its connected domain or its platform address,
 * as the server computes it (`public_url`), else from the host's
 * OG_ATLAS_URL_TEMPLATE (an atlas the wizard just made); null when no
 * template is configured.
 */
export const liveUrl = (site) => {
  if (site?.public_url) {
    return site.public_url;
  }

  return site?.slug && config.atlasUrlTemplate ? config.atlasUrlTemplate.replace('{slug}', site.slug) : null;
};

/**
 * A draft's shareable preview link: the renderer keeps the token in a
 * cookie and drops it from the address (see the renderer's middleware).
 */
export const previewUrl = (site) => {
  const url = liveUrl(site);
  return url && site?.preview_token ? `${url.replace(/\/+$/, '')}/?preview=${site.preview_token}` : null;
};
