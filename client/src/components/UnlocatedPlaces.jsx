import { lazy, Suspense, useCallback, useEffect, useMemo, useState } from 'react';
import _ from 'underscore';
import { errorMessages, fetchUnlocatedPlaces, locateUnlocatedPlaces, lookupUnlocatedPlaces } from '../api';
import { Button, Field, Message, Select } from './ui';

const PlacePicker = lazy(() => import('./PlacePicker'));

// What to show under a place's name in the list: where it is, if a field
// says so, else its first field.
const describe = (place) => (
  _.find(place.fields, (field) => /location|address|street|site/i.test(field.label)) || place.fields[0]
)?.value;

const PARTS = [
  { key: 'street', label: 'Street address', typed: false },
  { key: 'city', label: 'City', typed: true },
  { key: 'state', label: 'State', typed: true },
  { key: 'zip', label: 'ZIP code', typed: true }
];

/**
 * The atlas's places without a location: listed and searchable, but not on
 * the map. Two ways to place them: look their addresses up all at once
 * (with a review of what was found before anything is saved), or one by one
 * on a map — by clicking, or by searching for a name the address lookup
 * can't place ("Cockspur Island", "Bay & Bull Streets").
 */
const UnlocatedPlaces = ({ site }) => {
  const [data, setData] = useState(null);
  const [page, setPage] = useState(1);
  const [errors, setErrors] = useState([]);
  const [selectedId, setSelectedId] = useState(null);
  const [point, setPoint] = useState(null);
  const [saving, setSaving] = useState(false);
  const [notice, setNotice] = useState(null);

  const [address, setAddress] = useState(null);
  const [lookup, setLookup] = useState(null);
  const [looking, setLooking] = useState(false);
  const [accepted, setAccepted] = useState({});

  const load = useCallback((nextPage = page) => (
    fetchUnlocatedPlaces(site.id, nextPage)
      .then((response) => {
        setData(response);
        setAddress((prev) => prev || response.address || {});
        return response;
      })
      .catch((error) => setErrors(errorMessages(error)))
  ), [page, site.id]);

  useEffect(() => { load(page); }, [page]); // eslint-disable-line react-hooks/exhaustive-deps

  const places = data?.places || [];
  const selected = _.findWhere(places, { id: selectedId }) || null;

  // Select the first place once the list arrives (and after one is placed).
  useEffect(() => {
    if (places.length > 0 && !_.findWhere(places, { id: selectedId })) {
      setSelectedId(places[0].id);
      setPoint(null);
    }
  }, [places, selectedId]);

  /**
   * What to search for: the place's own address-like text, else its name.
   */
  const searchText = useMemo(() => {
    if (!selected) {
      return '';
    }

    const field = address?.street_field && _.findWhere(selected.fields, { label: address.street_field });
    const city = address?.city_field ? _.findWhere(selected.fields, { label: address.city_field })?.value : address?.city_value;
    const state = address?.state_value;

    return _.compact([field?.value || selected.name, city, state]).join(', ');
  }, [address, selected]);

  const onSave = () => {
    if (!selected || !point) {
      return;
    }

    setSaving(true);
    setErrors([]);

    locateUnlocatedPlaces(site.id, [{ place_id: selected.id, ...point }])
      .then(() => {
        setNotice(`“${selected.name}” is on the map.`);
        setPoint(null);
        const index = _.findIndex(places, { id: selected.id });
        setSelectedId(places[index + 1]?.id || null);
        return load(page);
      })
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSaving(false));
  };

  const onSkip = () => {
    const index = _.findIndex(places, { id: selectedId });
    setSelectedId(places[(index + 1) % places.length]?.id || null);
    setPoint(null);
  };

  // --- Address lookup --------------------------------------------------------

  const fieldOptions = _.map(data?.address_fields || [], (label) => ({ value: label, text: label }));

  const onLookup = () => {
    setLooking(true);
    setErrors([]);
    setLookup(null);

    lookupUnlocatedPlaces(site.id, { address })
      .then((response) => {
        setLookup(response.results || {});
        // Exact matches are taken unless unticked; approximate ones need a look.
        setAccepted(_.mapObject(response.results || {}, (result) => result.status === 'exact'));
      })
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setLooking(false));
  };

  const found = useMemo(() => _.chain(lookup || {})
    .map((result, id) => ({ ...result, id: Number(id) }))
    .filter((result) => result.status === 'exact' || result.status === 'approximate')
    .sortBy((result) => (result.status === 'exact' ? 0 : 1))
    .value(), [lookup]);

  const missed = useMemo(() => _.filter(lookup || {}, (result) => !['exact', 'approximate'].includes(result.status)).length, [lookup]);

  const acceptedCount = _.filter(found, (result) => accepted[result.id]).length;

  const onSaveLookup = () => {
    const locations = _.map(_.filter(found, (result) => accepted[result.id]), (result) => ({
      place_id: result.id,
      latitude: result.latitude,
      longitude: result.longitude
    }));

    setSaving(true);
    setErrors([]);

    locateUnlocatedPlaces(site.id, locations)
      .then((response) => {
        setNotice(`${response.located} ${response.located === 1 ? 'place is' : 'places are'} on the map.`);
        setLookup(null);
        setPage(1);
        return load(1);
      })
      .catch((error) => setErrors(errorMessages(error)))
      .finally(() => setSaving(false));
  };

  if (!data) {
    return <>{ !_.isEmpty(errors) ? <Message list={errors} tone='negative' /> : <p className='muted'>Loading…</p> }</>;
  }

  if (data.total === 0) {
    return (
      <>
        { notice && <Message tone='positive'>{ notice }</Message> }
        <Message tone='positive'>Every place has a location: they’re all on the map.</Message>
      </>
    );
  }

  const pages = Math.ceil(data.total / 50);

  return (
    <div className='unlocated'>
      { !_.isEmpty(errors) && <Message list={errors} tone='negative' /> }
      { notice && <Message tone='positive'>{ notice }</Message> }
      <p>
        <strong>{ data.total } of { data.total + data.located }</strong> places have no location: they’re listed and
        searchable on the atlas, but not on its map. Placed ones appear on the atlas’s map within a minute or so
        (a few minutes when you save many at once).
      </p>

      { data.geocoder && (
        <details className='details' open={!!lookup}>
          <summary>Look up their addresses all at once</summary>
          <p className='muted'>
            Uses { data.geocoder } (U.S. street addresses). Nothing is saved until you review what was found.
          </p>
          <div className='grid-2'>
            { _.map(PARTS, (part) => (
              <Field key={part.key} label={part.label}>
                <div className='address-part'>
                  <Select
                    onChange={(value) => setAddress({ ...address, [`${part.key}_field`]: value || undefined })}
                    options={fieldOptions}
                    placeholder={part.typed ? 'Type it instead →' : 'Choose a field'}
                    value={address?.[`${part.key}_field`] || ''}
                  />
                  { part.typed && !address?.[`${part.key}_field`] && (
                    <input
                      aria-label={`${part.label} for every place`}
                      className='input'
                      onChange={(e) => setAddress({ ...address, [`${part.key}_value`]: e.target.value })}
                      placeholder={part.key === 'city' ? 'e.g. Savannah' : part.key === 'state' ? 'e.g. GA' : ''}
                      value={address?.[`${part.key}_value`] || ''}
                    />
                  )}
                </div>
              </Field>
            ))}
          </div>
          <Button disabled={!address?.street_field || looking} loading={looking} onClick={onLookup}>
            Look up { Math.min(data.total, 1000) } { data.total === 1 ? 'place' : 'places' }
          </Button>

          { lookup && (
            <div className='lookup-results'>
              <p>
                Found { found.length }: { _.filter(found, { status: 'exact' }).length } exactly, { _.filter(found, { status: 'approximate' }).length } near
                the address (check these: an old street name can match the wrong street). { missed } not found; place those on the map below.
              </p>
              { found.length > 0 && (
                <>
                  <div className='table-scroll'>
                    <table className='table'>
                      <thead>
                        <tr><th>Save</th><th>Place</th><th>Address</th><th>Matched</th></tr>
                      </thead>
                      <tbody>
                        { _.map(found, (result) => (
                          <tr key={result.id}>
                            <td>
                              <input
                                aria-label='Save this location'
                                checked={!!accepted[result.id]}
                                onChange={(e) => setAccepted({ ...accepted, [result.id]: e.target.checked })}
                                type='checkbox'
                              />
                            </td>
                            <td>{ result.name || `#${result.id}` }</td>
                            <td>{ result.address }</td>
                            <td>
                              { result.matched }
                              { result.status === 'approximate' && <span className='muted'> (near)</span> }
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                  <Button disabled={acceptedCount === 0 || saving} loading={saving} onClick={onSaveLookup} primary>
                    Save { acceptedCount } { acceptedCount === 1 ? 'location' : 'locations' }
                  </Button>
                </>
              )}
            </div>
          )}
        </details>
      )}

      <h2 className='h-section'>Place them on the map</h2>
      <div className='unlocated-layout'>
        <div className='unlocated-list'>
          <ul>
            { _.map(places, (place) => (
              <li key={place.id}>
                <button
                  aria-current={place.id === selectedId}
                  className={place.id === selectedId ? 'is-selected' : undefined}
                  onClick={() => { setSelectedId(place.id); setPoint(null); }}
                  type='button'
                >
                  <strong>{ place.name || `Place ${place.id}` }</strong>
                  { describe(place) && <span className='muted'>{ describe(place) }</span> }
                </button>
              </li>
            ))}
          </ul>
          { pages > 1 && (
            <div className='row'>
              <Button disabled={page <= 1} onClick={() => setPage(page - 1)} subtle>← Previous</Button>
              <span className='muted'>Page { page } of { pages }</span>
              <Button disabled={page >= pages} onClick={() => setPage(page + 1)} subtle>Next →</Button>
            </div>
          )}
        </div>
        <div className='unlocated-detail'>
          { selected && (
            <>
              <h3 className='h-sub'>{ selected.name }</h3>
              { selected.fields.length > 0 && (
                <dl className='place-fields'>
                  { _.map(selected.fields.slice(0, 6), (field) => (
                    <div key={field.label}>
                      <dt>{ field.label }</dt>
                      <dd>{ field.value }</dd>
                    </div>
                  ))}
                </dl>
              )}
              <Suspense fallback={<div className='preview-map muted' style={{ height: 440 }}>Loading map…</div>}>
                <PlacePicker bbox={data.bbox} initialQuery={searchText} onChange={setPoint} value={point} />
              </Suspense>
              <div className='row'>
                <Button disabled={!point || saving} loading={saving} onClick={onSave} primary>Save location</Button>
                <Button disabled={saving} onClick={onSkip} subtle>Skip for now</Button>
                { point && <span className='muted'>{ point.latitude.toFixed(5) }, { point.longitude.toFixed(5) }</span> }
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
};

export default UnlocatedPlaces;
