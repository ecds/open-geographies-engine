import config from './config';
import { getToken } from './session';

/**
 * A thin client for the engine's admin API. Errors carry the server's
 * `errors` array (Core Data's `{ base: '…' }` / `{ field: '…' }` shape) as
 * `error.errors`, plus `error.status`.
 */
export class ApiError extends Error {
  constructor(message, status, errors) {
    super(message);
    this.status = status;
    this.errors = errors || [];
  }
}

const request = async (method, path, { body, form, params } = {}) => {
  const url = new URL(`${config.apiBaseUrl}${path}`, window.location.origin);

  Object.entries(params || {}).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      url.searchParams.set(key, value);
    }
  });

  const headers = { Accept: 'application/json' };
  const token = getToken();

  if (token) {
    headers.Authorization = token;
  }

  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  // A FormData body (file uploads) sets its own multipart content type.
  const response = await fetch(url, {
    method,
    headers,
    body: form || (body === undefined ? undefined : JSON.stringify(body))
  });

  let data = null;

  try {
    data = await response.json();
  } catch (e) {
    data = null;
  }

  if (!response.ok) {
    const message = response.status === 401 || response.status === 403
      ? 'You are not allowed to do that. Sign in to the console with an account that can create projects.'
      : `${response.status} ${response.statusText}`;

    throw new ApiError(message, response.status, data?.errors);
  }

  return data;
};

/**
 * Flattens an ApiError (or any error) into display strings.
 */
/**
 * Signs in against the host's own endpoint (the same one the FairData console
 * uses) — the engine pages then work before FairData's nav link exists, and
 * on a host whose console bundle isn't built (the demo stack).
 */
export const signIn = (email, password) => request('POST', '/auth/login', { body: { email, password } });

// How each attribute's validation messages are introduced. Page messages
// ("content") already name the page and section.
const ERROR_PREFIXES = {
  base: '',
  content: '',
  branding: 'Branding: ',
  navigation: 'Menu: ',
  config: '',
  screenshot: '',
  what_happened: 'What happened: '
};

export const errorMessages = (error, prefixes = {}) => {
  // Validation failures come as { attribute: [messages] }; other errors as
  // a list of such objects.
  const errors = error?.errors && !Array.isArray(error.errors) && typeof error.errors === 'object'
    ? [error.errors]
    : error?.errors;

  if (Array.isArray(errors) && errors.length > 0) {
    return errors.flatMap((entry) => {
      if (entry && typeof entry === 'object') {
        return Object.entries(entry).flatMap(([key, value]) => {
          const prefix = prefixes[key] ?? ERROR_PREFIXES[key] ?? `${key} `;
          return (Array.isArray(value) ? value : [value]).map((message) => `${prefix}${message}`);
        });
      }

      return [String(entry)];
    });
  }

  return [error?.message || 'Something went wrong.'];
};

export const createAtlas = (atlas) => request('POST', '/core_data/atlases', { body: { atlas } });

export const fetchJob = (id) => request('GET', `/core_data/jobs/${id}`);

/**
 * GeoNames admin hierarchy children. The project is optional: the wizard
 * collects the area before the project exists.
 */
export const fetchAdminChildren = (geonameId, projectId) => request(
  'GET',
  projectId
    ? `/core_data/projects/${projectId}/place_imports/admin_children`
    : '/core_data/place_imports/admin_children',
  { params: { geoname_id: geonameId } }
);

export const previewPlaceImport = (projectId, placeImport, limit = 500) => request(
  'POST',
  `/core_data/projects/${projectId}/place_imports/preview`,
  { body: { place_import: placeImport, limit } }
);

export const createPlaceImport = (projectId, placeImport) => request(
  'POST',
  `/core_data/projects/${projectId}/place_imports`,
  { body: { place_import: placeImport } }
);

// --- Atlas editor -----------------------------------------------------------

export const fetchSites = () => request('GET', '/core_data/sites', { params: { per_page: 0, sort_by: 'name' } });

export const fetchSite = (id) => request('GET', `/core_data/sites/${id}`);

export const updateSite = (id, site) => request('PATCH', `/core_data/sites/${id}`, { body: { site } });

export const regeneratePreviewToken = (id) => request('POST', `/core_data/sites/${id}/preview_token`);

export const deleteSite = (id) => request('DELETE', `/core_data/sites/${id}`);

/**
 * Sets (blank: removes) the atlas's own domain; the server checks its DNS.
 */
export const updateSiteDomain = (id, domain) => request('PUT', `/core_data/sites/${id}/domain`, { body: { domain } });

export const checkSiteDomain = (id) => request('POST', `/core_data/sites/${id}/domain/check`);

export const fetchSiteConfig = (id) => request('GET', `/core_data/sites/${id}/config`);

export const fetchSiteFacets = (id) => request('GET', `/core_data/sites/${id}/facets`);

export const fetchSiteFields = (id) => request('GET', `/core_data/sites/${id}/fields`);

export const fetchSiteSearchFields = (id) => request('GET', `/core_data/sites/${id}/search_fields`);

export const fetchSiteAssets = (id) => request('GET', `/core_data/sites/${id}/assets`);

export const uploadSiteAsset = (id, file) => {
  const form = new FormData();
  form.append('file', file);

  return request('POST', `/core_data/sites/${id}/assets`, { form });
};

export const deleteSiteAsset = (id, key) => request('DELETE', `/core_data/sites/${id}/assets/${encodeURIComponent(key)}`);

export const buildTiles = (id) => request('POST', `/core_data/sites/${id}/build_tiles`, { body: {} });

export const fetchSearchCollections = (projectId) => request('GET', '/core_data/search_collections', {
  params: { per_page: 0, project_id: projectId }
});

export const reindexSearchCollection = (id) => request('POST', `/core_data/search_collections/${id}/reindex`, { body: {} });

export const fetchJobs = (projectId) => request('GET', '/core_data/jobs', {
  params: { per_page: 0, project_id: projectId, sort_by: 'created_at', sort_direction: 'descending' }
});

export const previewDatasetImport = (projectId, file) => {
  const form = new FormData();
  form.append('file', file);

  return request('POST', `/core_data/projects/${projectId}/dataset_imports/preview`, { form });
};

// Looks rows without coordinates up from their address (preview only).
export const geocodeDatasetImport = (projectId, body) => request(
  'POST',
  `/core_data/projects/${projectId}/dataset_imports/geocode`,
  { body }
);

export const createDatasetImport = (projectId, datasetImport) => request(
  'POST',
  `/core_data/projects/${projectId}/dataset_imports`,
  { body: { dataset_import: datasetImport } }
);

// --- Places without a location ----------------------------------------------

export const fetchUnlocatedPlaces = (siteId, page = 1) => request('GET', `/core_data/sites/${siteId}/unlocated_places`, { params: { page } });

export const lookupUnlocatedPlaces = (siteId, body) => request('POST', `/core_data/sites/${siteId}/unlocated_places/lookup`, { body });

export const locateUnlocatedPlaces = (siteId, locations) => request('POST', `/core_data/sites/${siteId}/unlocated_places/locate`, { body: { locations } });

// --- Category values ----------------------------------------------------------

export const fetchCategories = (siteId) => request('GET', `/core_data/sites/${siteId}/categories`);

export const renameCategoryValue = (siteId, termId, name) => request('PATCH', `/core_data/sites/${siteId}/categories/${termId}`, { body: { name } });

// --- Feedback (FeedbackReportsController) ---------------------------------

/**
 * Sends a feedback report: { what_happened, expected, page_url, site_id,
 * context: {...}, screenshot: File }.
 */
export const sendFeedback = ({ context, screenshot, ...fields }) => {
  const form = new FormData();

  Object.entries(fields).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      form.append(key, value);
    }
  });
  Object.entries(context || {}).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') {
      form.append(`context[${key}]`, String(value));
    }
  });
  if (screenshot) {
    form.append('screenshot', screenshot);
  }

  return request('POST', '/core_data/feedback_reports', { form });
};

export const fetchFeedbackReports = (params) => request('GET', '/core_data/feedback_reports', { params });

export const updateFeedbackReport = (id, status) => request('PATCH', `/core_data/feedback_reports/${id}`, { body: { status } });

/**
 * A report's screenshot as an object URL (the image is served only with the
 * session's Authorization header, which an <img src> can't send). The caller
 * revokes it.
 */
export const fetchFeedbackScreenshot = async (id) => {
  const response = await fetch(`${config.apiBaseUrl}/core_data/feedback_reports/${id}/screenshot`, {
    headers: { Authorization: getToken() || '' }
  });

  if (!response.ok) {
    throw new ApiError(`${response.status} ${response.statusText}`, response.status);
  }

  return URL.createObjectURL(await response.blob());
};
