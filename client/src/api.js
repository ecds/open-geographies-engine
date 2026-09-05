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

const request = async (method, path, { body, params } = {}) => {
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

  const response = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
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

export const errorMessages = (error) => {
  const errors = error?.errors;

  if (Array.isArray(errors) && errors.length > 0) {
    return errors.flatMap((entry) => {
      if (entry && typeof entry === 'object') {
        return Object.entries(entry).map(([key, value]) => (
          key === 'base' ? String(value) : `${key} ${value}`
        ));
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

export const fetchSiteConfig = (id) => request('GET', `/core_data/sites/${id}/config`);

export const fetchSiteFacets = (id) => request('GET', `/core_data/sites/${id}/facets`);

export const fetchSiteFields = (id) => request('GET', `/core_data/sites/${id}/fields`);

export const buildTiles = (id) => request('POST', `/core_data/sites/${id}/build_tiles`, { body: {} });

export const fetchSearchCollections = (projectId) => request('GET', '/core_data/search_collections', {
  params: { per_page: 0, project_id: projectId }
});

export const reindexSearchCollection = (id) => request('POST', `/core_data/search_collections/${id}/reindex`, { body: {} });

export const fetchJobs = (projectId) => request('GET', '/core_data/jobs', {
  params: { per_page: 0, project_id: projectId, sort_by: 'created_at', sort_direction: 'descending' }
});

export const fetchDescriptors = (projectId) => request('GET', `/core_data/projects/${projectId}/descriptors`);
