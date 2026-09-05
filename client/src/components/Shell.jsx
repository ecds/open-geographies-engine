import config from '../config';
import { paths } from '../router';

/**
 * The console chrome: a slim header with the two entry points and a way back
 * to FairData. `navigate` keeps in-app links client-side.
 */
const Shell = ({ active, children, navigate }) => {
  const link = (to, label, key) => (
    <a
      aria-current={active === key ? 'page' : undefined}
      className='shell-link'
      href={to}
      onClick={(e) => { e.preventDefault(); navigate(to); }}
    >
      { label }
    </a>
  );

  return (
    <>
      <header className='shell'>
        <span className='shell-brand'>Open Geographies</span>
        <nav className='shell-nav'>
          { link(paths.atlases(), 'Atlases', 'atlases') }
          { link(paths.wizard(), 'Create an atlas', 'wizard') }
        </nav>
        <a className='shell-link shell-console' href={`${config.consoleUrl}/`}>FairData console →</a>
      </header>
      { children }
    </>
  );
};

export default Shell;
