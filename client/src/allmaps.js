/**
 * Historic map overlays come from Allmaps (allmaps.org): a scanned map,
 * served over IIIF, is "georeferenced" there — matched to today's map with
 * a few control points — and Allmaps publishes the result as a Georeference
 * Annotation. The renderer draws an annotation as a warped overlay (an
 * atlas layer with `layer_type: 'georeference'`, `url` = the annotation).
 *
 * Everything here runs in the curator's browser against Allmaps' public,
 * CORS-enabled API, so the server never fetches an address a curator typed.
 */

const ANNOTATIONS_HOST = 'annotations.allmaps.org';
const ANNOTATIONS = `https://${ANNOTATIONS_HOST}`;

/**
 * Allmaps Editor, opened on a scan (a IIIF manifest or image address).
 */
export const editorUrl = (iiifUrl) => `https://editor.allmaps.org/images?url=${encodeURIComponent(iiifUrl)}`;

/**
 * The address in what a curator pasted: an Allmaps Viewer or Editor link
 * carries it as `?url=` (or in the hash); anything else is taken as is.
 * Null when it isn't an http(s) address.
 */
export const extractUrl = (text) => {
  let url;

  try {
    url = new URL(String(text || '').trim());
  } catch (e) {
    return null;
  }

  if (!/^https?:$/.test(url.protocol)) {
    return null;
  }

  if (/(^|\.)allmaps\.org$/.test(url.hostname) && url.hostname !== ANNOTATIONS_HOST) {
    const hashQuery = url.hash.includes('?') ? url.hash.slice(url.hash.indexOf('?') + 1) : '';
    const inner = url.searchParams.get('url') || new URLSearchParams(hashQuery).get('url');

    return inner ? extractUrl(inner) : null;
  }

  return url.toString();
};

const isAnnotationUrl = (url) => {
  const { hostname, pathname } = new URL(url);
  return hostname === ANNOTATIONS_HOST && /^\/(maps|images|manifests)\/[^/]+/.test(pathname);
};

// A IIIF language map ({ en: ['Title'] }) or string, as plain text.
const labelText = (label) => {
  if (!label) return null;
  if (typeof label === 'string') return label;

  const values = Object.values(label).flat();
  return values.length ? String(values[0]) : null;
};

/**
 * What a georeference annotation (one Annotation or an AnnotationPage of
 * them) shows: how many maps, where (the bounding box of their control
 * points), a thumbnail of the first scan and its title when the annotation
 * names its manifest. Null when it isn't one.
 */
export const summarize = (doc) => {
  const items = doc?.type === 'AnnotationPage' ? (doc.items || []) : [doc];
  const maps = items.filter((item) => item?.motivation === 'georeferencing' && Array.isArray(item?.body?.features));

  if (maps.length === 0) {
    return null;
  }

  const points = maps.flatMap((map) => map.body.features.map((feature) => feature?.geometry?.coordinates)).filter((c) => Array.isArray(c) && c.length >= 2);
  if (points.length === 0) {
    return null;
  }

  const xs = points.map((p) => p[0]);
  const ys = points.map((p) => p[1]);
  const bbox = [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)];

  const source = maps[0].target?.source || {};
  const service = (source.id || source['@id'] || '').replace(/\/+$/, '');
  const canvas = Array.isArray(source.partOf) ? source.partOf[0] : null;
  const manifest = canvas && Array.isArray(canvas.partOf) ? canvas.partOf[0] : null;

  return {
    maps: maps.length,
    bbox,
    thumbnail: service ? `${service}/full/320,/0/default.jpg` : null,
    title: labelText(manifest?.label) || labelText(canvas?.label),
    scanUrl: manifest?.id || service || null
  };
};

const getJson = async (url) => {
  const response = await fetch(url, { headers: { Accept: 'application/json' } });
  const body = response.ok ? await response.json().catch(() => null) : null;

  return { response, body };
};

/**
 * Finds the georeference for what a curator pasted. Answers one of:
 * - { status: 'found', url, maps, bbox, thumbnail, title } — `url` is the
 *   annotation's own address, what the layer stores;
 * - { status: 'not_georeferenced', editorUrl } — a scan Allmaps doesn't
 *   know yet;
 * - { status: 'unavailable', editorUrl } — Allmaps couldn't answer;
 * - { status: 'invalid' } — not an address, or not a map annotation.
 */
export const findGeoreference = async (text) => {
  const url = extractUrl(text);
  if (!url) {
    return { status: 'invalid' };
  }

  try {
    if (isAnnotationUrl(url)) {
      const { body, response } = await getJson(url);
      const summary = summarize(body);

      return summary ? { status: 'found', url: response.url || url, ...summary } : { status: 'invalid' };
    }

    // Allmaps' lookup by scan address redirects to the annotation.
    const lookup = await getJson(`${ANNOTATIONS}/?url=${encodeURIComponent(url)}`);
    const found = summarize(lookup.body);
    if (found) {
      return { status: 'found', url: lookup.response.url, ...found };
    }

    // An annotation hosted somewhere else.
    const direct = await getJson(url).catch(() => ({ body: null }));
    const hosted = summarize(direct.body);
    if (hosted) {
      return { status: 'found', url, ...hosted };
    }

    return lookup.response.status === 404
      ? { status: 'not_georeferenced', editorUrl: editorUrl(url) }
      : { status: 'unavailable', editorUrl: editorUrl(url) };
  } catch (e) {
    return { status: 'unavailable', editorUrl: editorUrl(url) };
  }
};
