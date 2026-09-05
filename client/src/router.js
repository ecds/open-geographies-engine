import { useCallback, useEffect, useState } from 'react';

/**
 * A minimal path router for the console's handful of pages. The engine serves
 * the same page for /wizard and /atlases(/*), so the app decides what to show
 * from the path and pushes state for in-app navigation.
 */
const ROUTES = [
  { name: 'wizard', pattern: /^\/wizard\/?$/ },
  { name: 'atlases', pattern: /^\/atlases\/?$/ },
  { name: 'atlas', pattern: /^\/atlases\/(\d+)\/?$/ },
  { name: 'imports', pattern: /^\/atlases\/(\d+)\/imports\/?$/ },
  { name: 'jobs', pattern: /^\/atlases\/(\d+)\/jobs\/?$/ }
];

export const match = (pathname) => {
  for (const route of ROUTES) {
    const m = pathname.match(route.pattern);

    if (m) {
      return { name: route.name, id: m[1] ? Number(m[1]) : null };
    }
  }

  return { name: 'atlases', id: null };
};

const TITLES = {
  wizard: 'Create your atlas',
  atlases: 'Atlases',
  atlas: 'Atlas settings',
  imports: 'Place imports',
  jobs: 'Jobs'
};

export const useRoute = () => {
  const [pathname, setPathname] = useState(window.location.pathname);

  useEffect(() => {
    document.title = `${TITLES[match(pathname).name]} · Open Geographies`;
  }, [pathname]);

  useEffect(() => {
    const onPop = () => setPathname(window.location.pathname);
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  const navigate = useCallback((to) => {
    window.history.pushState({}, '', to);
    setPathname(to);
    window.scrollTo(0, 0);
  }, []);

  return { route: match(pathname), navigate };
};

export const paths = {
  wizard: () => '/wizard',
  atlases: () => '/atlases',
  atlas: (id) => `/atlases/${id}`,
  imports: (id) => `/atlases/${id}/imports`,
  jobs: (id) => `/atlases/${id}/jobs`
};
