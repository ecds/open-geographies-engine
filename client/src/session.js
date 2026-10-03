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

/**
 * Signed in means a token that hasn't expired: a stale token would otherwise
 * hide the sign-in form while every API call is refused.
 */
export const isSignedIn = () => {
  const { exp, token } = getSession();

  if (!token) {
    return false;
  }

  const expiresAt = exp ? Date.parse(exp) : NaN;
  return Number.isNaN(expiresAt) || expiresAt > Date.now();
};

/**
 * FairData lets admins and "member" accounts create projects (and so
 * atlases). An account made by inviting someone to a project is a "guest":
 * it works on the projects it was added to but can't start new ones.
 */
export const canCreateAtlases = () => getSession().user?.role !== 'guest';

/**
 * FairData's administrators run the platform: they read the feedback
 * curators send.
 */
export const isAdmin = () => getSession().user?.role === 'admin';

/**
 * Stores a session as the console would (the /auth/login response: token,
 * exp, user), so the two clients share one sign-in.
 */
export const setSession = (session) => {
  localStorage.setItem(SESSION_KEY, JSON.stringify(session));
};
