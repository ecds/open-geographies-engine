import { useCallback, useMemo, useState } from 'react';
import _ from 'underscore';
import { createAtlas, errorMessages, signIn } from './api';
import { liveUrl, previewUrl } from './atlasLinks';
import config from './config';
import { JobStatuses } from './jobs';
import useJobPolling from './hooks/useJobPolling';
import { canCreateAtlases, isSignedIn, setSession } from './session';
import { paths, useRoute } from './router';
import AtlasAreaForm from './components/AtlasAreaForm';
import PlaceSources from './components/PlaceSources';
import Shell from './components/Shell';
import { Button, Field, Message } from './components/ui';
import AtlasEditor from './pages/AtlasEditor';
import AtlasImports from './pages/AtlasImports';
import AtlasJobs from './pages/AtlasJobs';
import AtlasPlaces from './pages/AtlasPlaces';
import AtlasList from './pages/AtlasList';

const Steps = {
  basics: 'basics',
  provision: 'provision',
  seed: 'seed',
  done: 'done'
};

const STEP_ORDER = [Steps.basics, Steps.provision, Steps.seed, Steps.done];

const STEP_LABELS = {
  basics: { title: 'Basics', description: 'Name, language, and area' },
  provision: { title: 'Provision', description: 'Set up the atlas' },
  seed: { title: 'Add places', description: 'Your own data, or a gazetteer' },
  done: { title: 'Done', description: 'Ready to build' }
};

const PROVISION_STAGES = [
  { key: 'search_index', label: 'Create the search index' }
];

const LOCALES = [
  { value: 'en', text: 'English' },
  { value: 'es', text: 'Spanish' },
  { value: 'fr', text: 'French' },
  { value: 'de', text: 'German' },
  { value: 'it', text: 'Italian' },
  { value: 'pt', text: 'Portuguese' }
];

const TEMPLATES = [
  { value: 'places', title: 'Places', description: 'Places and a place-type vocabulary — the lightest start' },
  { value: 'atlas', title: 'Atlas', description: 'Places, media, works, people, and organizations' }
];

/**
 * The canonical template's optional modules (og.optional), offered with the
 * Atlas template. Names must match the template exactly — the engine creates
 * them from the same document the indexer promotes from.
 */
const MODULES = [
  { value: 'Map Layers', title: 'Map layers', description: 'Georeferenced historical overlays with a time slider' },
  { value: 'Work Types', title: 'Work types', description: 'A vocabulary for classifying works' },
  { value: 'Tours', title: 'Tours', description: 'Ordered stops through places' }
];

/**
 * The "Create your atlas" wizard: collects the basics and geographic area,
 * provisions the atlas (project, models, search collection, site) while
 * reporting the job's stages, optionally seeds it with places from
 * geographic authorities, and hands off to the new project in the console.
 * The atlas renders on the shared dynamic renderer as soon as it is
 * provisioned — there is no build or deploy — as a draft, seen only through
 * its preview link until the curator publishes it.
 */
const Wizard = ({ navigate }) => {
  const [step, setStep] = useState(Steps.basics);
  const [atlas, setAtlas] = useState({
    name: '',
    description: '',
    locale: 'en',
    template: 'places',
    modules: [],
    area: {}
  });
  const [errors, setErrors] = useState([]);
  const [nameError, setNameError] = useState(null);
  const [saving, setSaving] = useState(false);
  const [provisioned, setProvisioned] = useState(null);
  const [seeded, setSeeded] = useState(false);

  const provisionJob = useJobPolling(provisioned?.job?.id);

  const stepIndex = STEP_ORDER.indexOf(step);

  const update = (changes) => setAtlas((prev) => ({ ...prev, ...changes }));

  const onCreate = useCallback(() => {
    setSaving(true);
    setErrors([]);
    setNameError(null);

    createAtlas(atlas)
      .then((data) => {
        setProvisioned(data.atlas);
        setStep(Steps.provision);
      })
      .catch((error) => {
        // The server words name problems for the curator; they're shown
        // under the name field as well as by the button.
        const entry = _.find(_.flatten([error?.errors || []]), (e) => e && e.name);
        setNameError(entry ? _.flatten([entry.name])[0] : null);
        setErrors(errorMessages(error, { name: '' }));
      })
      .finally(() => setSaving(false));
  }, [atlas]);

  const provisionFailed = provisionJob?.status === JobStatuses.failed;
  const provisionComplete = provisionJob?.status === JobStatuses.completed;

  const currentStageIndex = useMemo(() => {
    const stage = provisionJob?.extra?.stage;

    if (!stage) {
      return 0;
    }

    return Math.max(_.findIndex(PROVISION_STAGES, { key: stage.split(':')[0] }), 0);
  }, [provisionJob]);

  const stageState = (index) => {
    if (provisionComplete || index < currentStageIndex) {
      return 'done';
    }

    if (index === currentStageIndex) {
      return provisionFailed ? 'failed' : 'running';
    }

    return 'pending';
  };

  const projectUrl = provisioned && `${config.consoleUrl}/projects/${provisioned.project_id}`;

  return (
    <main className='wizard'>
      <h1>Create your atlas</h1>

      <ol className='steps'>
        { _.map(STEP_ORDER, (name, index) => (
          <li
            className={['step', step === name && 'is-active', index < stepIndex && 'is-complete'].filter(Boolean).join(' ')}
            key={name}
          >
            <span className='step-number'>{ index < stepIndex ? '✓' : index + 1 }</span>
            <span className='step-text'>
              <span className='step-title'>{ STEP_LABELS[name].title }</span>
              <span className='step-description'>{ STEP_LABELS[name].description }</span>
            </span>
          </li>
        ))}
      </ol>

      { step === Steps.basics && (
        <section className='panel'>
          <Field error={nameError} label='Atlas name' required>
            <input
              aria-invalid={!!nameError}
              autoFocus
              className='input'
              onChange={(e) => {
                update({ name: e.target.value });
                setNameError(null);
              }}
              value={atlas.name}
            />
          </Field>
          <Field label='Description'>
            <textarea
              className='input'
              onChange={(e) => update({ description: e.target.value })}
              rows={3}
              value={atlas.description}
            />
          </Field>
          <Field label='Default language'>
            <select className='input' onChange={(e) => update({ locale: e.target.value })} value={atlas.locale}>
              { _.map(LOCALES, (locale) => <option key={locale.value} value={locale.value}>{ locale.text }</option>) }
            </select>
          </Field>
          <fieldset className='field'>
            <legend className='field-label'>Starter template</legend>
            { _.map(TEMPLATES, (template) => (
              <label className='check' key={template.value}>
                <input
                  checked={atlas.template === template.value}
                  name='template'
                  onChange={() => update({ template: template.value })}
                  type='radio'
                  value={template.value}
                />
                <strong>{ template.title }</strong> — { template.description }
              </label>
            ))}
          </fieldset>
          { atlas.template === 'atlas' && (
            <fieldset className='field'>
              <legend className='field-label'>Optional modules</legend>
              { _.map(MODULES, (module) => (
                <label className='check' key={module.value}>
                  <input
                    checked={_.contains(atlas.modules, module.value)}
                    onChange={(e) => update({
                      modules: e.target.checked
                        ? [...atlas.modules, module.value]
                        : _.without(atlas.modules, module.value)
                    })}
                    type='checkbox'
                  />
                  <strong>{ module.title }</strong> — { module.description }
                </label>
              ))}
            </fieldset>
          )}
          <h3>Geographic area <span className='muted'>(optional)</span></h3>
          <p className='muted'>
            Used to find places in gazetteers such as GeoNames. Skip it if you’re bringing your own
            data; you can choose one later when importing.
          </p>
          <AtlasAreaForm onChange={(area) => update({ area })} value={atlas.area} />
          { /* Beside the button, not at the top of the form: the curator is
               looking here when the create fails. */ }
          { !_.isEmpty(errors) && <Message header='Unable to create the atlas' list={errors} tone='negative' /> }
          <div className='actions'>
            <Button disabled={!atlas.name.trim() || saving} loading={saving} onClick={onCreate} primary>
              Create atlas
            </Button>
            { !atlas.name.trim() && <span className='muted'>Give the atlas a name first.</span> }
          </div>
        </section>
      )}

      { step === Steps.provision && (
        <section className='panel'>
          <h2>Provisioning “{ atlas.name }”</h2>
          <ul className='stages'>
            { _.map(PROVISION_STAGES, (stage, index) => (
              <li className={`stage stage-${stageState(index)}`} key={stage.key}>
                <span className='stage-icon' aria-hidden='true' />
                { stage.label }
              </li>
            ))}
          </ul>
          { provisionFailed && (
            <Message header='The full job record is available on the project’s Jobs page.' tone='negative'>
              Provisioning failed during “{ provisionJob?.extra?.failed_stage }”: { provisionJob?.extra?.error }
            </Message>
          )}
          { provisionComplete && (
            <>
              <Message tone='positive'>
                Your atlas is set up. It’s a draft: private, with a preview link, until you publish it.
              </Message>
              <div className='actions'>
                <Button onClick={() => setStep(Steps.seed)} primary>Continue</Button>
              </div>
            </>
          )}
        </section>
      )}

      { step === Steps.seed && provisioned && (
        <section className='panel'>
          <PlaceSources
            area={atlas.area}
            onImported={() => setSeeded(true)}
            projectId={provisioned.project_id}
          />
          <div className='actions'>
            <Button onClick={() => setStep(Steps.done)} primary={seeded}>
              { seeded ? 'Continue' : 'Skip for now' }
            </Button>
          </div>
        </section>
      )}

      { step === Steps.done && provisioned && (
        <section className='panel panel-centered'>
          <div className='done-icon' aria-hidden='true'>✓</div>
          <h2>“{ atlas.name }” is ready to build</h2>
          <p>It’s a draft: only people with the preview link can see it. Publish it from the atlas’s settings when it’s ready.</p>
          { previewUrl({ slug: provisioned.slug, preview_token: provisioned.preview_token }) && (
            <p>
              Preview:
              {' '}
              <a href={previewUrl({ slug: provisioned.slug, preview_token: provisioned.preview_token })} rel='noreferrer' target='_blank'>
                { liveUrl({ slug: provisioned.slug }) } (preview)
              </a>
            </p>
          )}
          <p>Add your own places from the project’s data entry pages — they appear in your atlas immediately.</p>
          <p>Need more data later? Upload another file or run a gazetteer import any time from the atlas’s Imports page.</p>
          <div className='actions actions-centered'>
            <Button onClick={() => navigate(paths.atlas(provisioned.site_id))} primary>Open atlas settings</Button>
            <a className='button' href={projectUrl}>Go to the project's data</a>
          </div>
        </section>
      )}
    </main>
  );
};

/**
 * Signed-out state: a sign-in form against the host's /auth/login, storing
 * the session where the FairData console keeps its own.
 */
const SignIn = ({ onSignedIn }) => {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [errors, setErrors] = useState([]);
  const [saving, setSaving] = useState(false);

  const onSubmit = (e) => {
    e.preventDefault();
    setSaving(true);
    setErrors([]);

    signIn(email, password)
      .then((session) => { setSession(session); onSignedIn(); })
      .catch((error) => setErrors(error?.status === 401 ? ['Email or password not recognized.'] : errorMessages(error)))
      .finally(() => setSaving(false));
  };

  return (
    <main className='wizard'>
      <h1>Open Geographies</h1>
      <form className='panel' onSubmit={onSubmit}>
        <p className='muted'>Sign in with your FairData account.</p>
        { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
        <Field label='Email' required>
          <input autoFocus className='input' onChange={(e) => setEmail(e.target.value)} type='email' value={email} />
        </Field>
        <Field label='Password' required>
          <input className='input' onChange={(e) => setPassword(e.target.value)} type='password' value={password} />
        </Field>
        <div className='actions'>
          <Button disabled={!email || !password || saving} loading={saving} primary type='submit'>Sign in</Button>
        </div>
      </form>
    </main>
  );
};

/**
 * The engine's console: the wizard plus the atlas pages, chosen by path.
 */
const App = () => {
  const { route, navigate } = useRoute();
  const [, setSignedInAt] = useState(0);

  if (!isSignedIn()) {
    return (
      <Shell active={route.name} navigate={navigate}>
        <SignIn onSignedIn={() => setSignedInAt(Date.now())} />
      </Shell>
    );
  }

  const page = {
    wizard: () => (canCreateAtlases() ? <Wizard navigate={navigate} /> : (
      <main className='wizard'>
        <h1>Create your atlas</h1>
        <p>
          Your account works on the atlases you’ve been added to, but can’t start new ones. Ask a FairData administrator
          if you need to create an atlas.
        </p>
        <a href={paths.atlases()} onClick={(e) => { e.preventDefault(); navigate(paths.atlases()); }}>Your atlases</a>
      </main>
    )),
    atlases: () => <AtlasList navigate={navigate} />,
    atlas: () => <AtlasEditor id={route.id} key={route.id} navigate={navigate} />,
    imports: () => <AtlasImports id={route.id} key={route.id} navigate={navigate} />,
    jobs: () => <AtlasJobs id={route.id} key={route.id} navigate={navigate} />,
    places: () => <AtlasPlaces id={route.id} key={route.id} navigate={navigate} />
  }[route.name];

  return (
    <Shell active={route.name === 'wizard' ? 'wizard' : 'atlases'} navigate={navigate}>
      { page() }
    </Shell>
  );
};

export default App;
