/**
 * The FairData console's session, as it stores it: localStorage under
 * `core_data_cloud_user`, with the JWT in `token`. The wizard is served from
 * the same origin as the console, so it reads the same entry and sends the
 * same `Authorization` header the console's own API client does.
 */
const SESSION_KEY = 'core_data_cloud_user';

export const getSession = () => {
  try {
    return JSON.parse(localStorage.getItem(SESSION_KEY) || '{}');
  } catch (e) {
    return {};
  }
};

export const getToken = () => getSession().token;

export const isSignedIn = () => !!getToken();

/**
 * Stores a session as the console would (the /auth/login response: token,
 * exp, user), so the two clients share one sign-in.
 */
export const setSession = (session) => {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
};
